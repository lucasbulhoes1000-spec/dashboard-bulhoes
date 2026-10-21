-- ============================================================
-- CRM Bulhões — WhatsApp: vários números + coexistência (21/10/2026)
--
-- 1. Tabela whatsapp_numeros: cada número da clínica ligado ao CRM, com
--    apelido, conta (WABA) e, para números conectados pelo celular
--    (coexistência), a chave própria e o andamento da importação.
-- 2. wa_processar passa a entender os avisos da coexistência:
--    • smb_message_echoes → o que a equipe envia pelo app do celular
--    • history            → histórico de conversas importado do celular
--    • smb_app_state_sync → contatos salvos no celular (nome do paciente)
-- 3. mensagens.canal: de onde saiu a mensagem enviada (crm, celular, historico)
--
-- Rodar no Supabase: SQL Editor → New query → colar tudo → Run.
-- Pode rodar mais de uma vez sem problema.
-- ============================================================

-- ------------------------------------------------------------
-- Números da clínica
-- ------------------------------------------------------------
create table if not exists public.whatsapp_numeros (
  phone_number_id        text primary key,
  waba_id                text not null,
  numero_exibicao        text,                 -- +55 13 99630-0176
  apelido                text,                 -- Clínica, Comercial, Dra. Larissa...
  coexistencia           boolean not null default false,
  token                  text,                 -- chave própria (só números conectados pelo celular)
  conectado_em           timestamptz not null default now(),
  conectado_por          text,
  sync_contatos_pedido   text,                 -- request_id da Meta (suporte)
  sync_historico_pedido  text,
  historico_progresso    integer,              -- 0 a 100
  historico_erro         text,
  ativo                  boolean not null default true
);

alter table public.whatsapp_numeros enable row level security;
revoke all on public.whatsapp_numeros from anon, authenticated;
-- a equipe vê os números (nunca a chave)
grant select (phone_number_id, waba_id, numero_exibicao, apelido, coexistencia, conectado_em,
              historico_progresso, historico_erro, ativo) on public.whatsapp_numeros to authenticated;
drop policy if exists whatsapp_numeros_ver on public.whatsapp_numeros;
create policy whatsapp_numeros_ver on public.whatsapp_numeros for select to authenticated
  using (public.tem_papel('gestao', 'avaliacao', 'comercial'));
-- a gestão pode renomear
grant update (apelido) on public.whatsapp_numeros to authenticated;
drop policy if exists whatsapp_numeros_apelido on public.whatsapp_numeros;
create policy whatsapp_numeros_apelido on public.whatsapp_numeros for update to authenticated
  using (public.tem_papel('gestao')) with check (public.tem_papel('gestao'));

-- número principal (API oficial, já ligado)
insert into public.whatsapp_numeros (phone_number_id, waba_id, numero_exibicao, apelido, coexistencia)
values ('1079601871893196', '787483481087007', '+55 13 99630-0176', 'Clínica', false)
on conflict (phone_number_id) do nothing;

do $$ begin
  alter publication supabase_realtime add table public.whatsapp_numeros;
exception when duplicate_object then null; when undefined_object then null; end $$;

-- ------------------------------------------------------------
-- Contatos salvos no celular (coexistência)
-- ------------------------------------------------------------
create table if not exists public.whatsapp_contatos (
  numero_clinica_id  text not null,
  telefone           text not null,
  nome               text,
  atualizado_em      timestamptz not null default now(),
  primary key (numero_clinica_id, telefone)
);
alter table public.whatsapp_contatos enable row level security;
revoke all on public.whatsapp_contatos from anon, authenticated;
grant select on public.whatsapp_contatos to authenticated;
drop policy if exists whatsapp_contatos_ver on public.whatsapp_contatos;
create policy whatsapp_contatos_ver on public.whatsapp_contatos for select to authenticated
  using (public.tem_papel('gestao', 'avaliacao', 'comercial'));

-- ------------------------------------------------------------
-- Colunas novas
-- ------------------------------------------------------------
alter table public.mensagens add column if not exists canal text not null default 'crm'
  check (canal in ('crm', 'celular', 'historico', 'paciente'));
alter table public.conversas add column if not exists nome_contato text;  -- nome salvo no celular
update public.mensagens set canal = 'paciente' where direcao = 'recebida' and canal = 'crm';

-- ------------------------------------------------------------
-- Texto legível: mídia do histórico
-- ------------------------------------------------------------
create or replace function public.wa_texto(m jsonb)
returns text language sql immutable as $$
  select case m->>'type'
    when 'text'        then m->'text'->>'body'
    when 'image'       then coalesce(nullif(m->'image'->>'caption', ''), '📷 Foto')
    when 'video'       then coalesce(nullif(m->'video'->>'caption', ''), '🎥 Vídeo')
    when 'audio'       then '🎤 Áudio'
    when 'voice'       then '🎤 Áudio'
    when 'sticker'     then 'Figurinha'
    when 'document'    then '📄 ' || coalesce(nullif(m->'document'->>'caption', ''), m->'document'->>'filename', 'Documento')
    when 'location'    then '📍 ' || coalesce(m->'location'->>'name', '') || ' ' || coalesce(m->'location'->>'latitude', '') || ',' || coalesce(m->'location'->>'longitude', '')
    when 'contacts'    then '👤 ' || coalesce(m->'contacts'->0->'name'->>'formatted_name', 'Contato')
    when 'button'      then m->'button'->>'text'
    when 'interactive' then coalesce(m->'interactive'->'button_reply'->>'title', m->'interactive'->'list_reply'->>'title', 'Resposta')
    when 'reaction'    then 'Reagiu ' || coalesce(m->'reaction'->>'emoji', '')
    when 'template'    then '📋 Modelo'
    when 'media_placeholder' then '📎 Mídia (do histórico)'
    else '(' || coalesce(m->>'type', 'mensagem') || ')'
  end;
$$;

-- ------------------------------------------------------------
-- Guarda uma mensagem (de qualquer origem). Devolve o id novo, ou null se já existia.
-- ------------------------------------------------------------
create or replace function public.wa_guardar(
  p_numero text, p_contraparte text, m jsonb, p_direcao text, p_canal text,
  p_status text, p_conta_nao_lida boolean, p_abre_janela boolean, p_nome_perfil text)
returns jsonb
language plpgsql security definer set search_path = public, migracao, pg_temp as $$
declare
  v_conversa uuid; v_msg uuid; v_tipo text := m->>'type'; v_midia jsonb; v_ts timestamptz;
  v_texto text := public.wa_texto(m);
begin
  v_ts := to_timestamp(coalesce(nullif(m->>'timestamp', '')::bigint, extract(epoch from now())::bigint));
  v_conversa := public.wa_conversa(p_numero, p_contraparte);
  v_midia := case when v_tipo in ('image', 'audio', 'voice', 'video', 'document', 'sticker') then m->v_tipo end;

  insert into public.mensagens
    (conversa_id, wa_message_id, direcao, tipo, texto, midia_id, midia_tipo, midia_nome,
     status, responde_a, origem_anuncio, enviada_em, canal, bruto)
  values
    (v_conversa, m->>'id', p_direcao, v_tipo, v_texto,
     v_midia->>'id', v_midia->>'mime_type', v_midia->>'filename',
     p_status, m->'context'->>'id', m->'referral', v_ts, p_canal, m)
  on conflict (wa_message_id) do nothing
  returning id into v_msg;

  if v_msg is null then
    -- já existia: se agora veio a mídia (histórico manda depois), completa
    if v_midia ? 'id' then
      update public.mensagens set midia_id = v_midia->>'id', midia_tipo = v_midia->>'mime_type',
             midia_nome = coalesce(midia_nome, v_midia->>'filename'), tipo = v_tipo,
             texto = case when tipo = 'media_placeholder' then v_texto else texto end,
             atualizada_em = now()
       where wa_message_id = m->>'id' and midia_caminho is null
       returning id, conversa_id into v_msg, v_conversa;
      if v_msg is not null then
        return jsonb_build_object('nova', false, 'midia', jsonb_build_object(
          'mensagem_id', v_msg, 'conversa_id', v_conversa, 'midia_id', v_midia->>'id',
          'mime', v_midia->>'mime_type', 'nome', v_midia->>'filename'));
      end if;
    end if;
    return null;
  end if;

  update public.conversas c set
    nome_perfil = coalesce(p_nome_perfil, c.nome_perfil),
    ultima_mensagem_em = greatest(coalesce(c.ultima_mensagem_em, v_ts), v_ts),
    ultima_mensagem_texto = case when c.ultima_mensagem_em is null or v_ts >= c.ultima_mensagem_em
                                 then v_texto else c.ultima_mensagem_texto end,
    ultima_recebida_em = case when p_abre_janela then greatest(coalesce(c.ultima_recebida_em, v_ts), v_ts)
                              else c.ultima_recebida_em end,
    janela_gratis_ate = case when p_abre_janela and m ? 'referral'
                             then greatest(coalesce(c.janela_gratis_ate, v_ts), v_ts + interval '72 hours')
                             else c.janela_gratis_ate end,
    nao_lidas = case when p_conta_nao_lida then c.nao_lidas + 1
                     when p_direcao = 'enviada' and p_canal = 'celular' then 0
                     else c.nao_lidas end,
    status = case when p_conta_nao_lida then 'aberta'
                  when p_direcao = 'enviada' and p_canal = 'celular' then 'aguardando'
                  -- conversa antiga que só existe pelo histórico não entra na lista de abertas
                  when p_canal = 'historico' and c.ultima_recebida_em is null and c.nao_lidas = 0 then 'encerrada'
                  else c.status end
  where c.id = v_conversa;

  return jsonb_build_object('nova', true, 'midia', case when v_midia ? 'id' then jsonb_build_object(
    'mensagem_id', v_msg, 'conversa_id', v_conversa, 'midia_id', v_midia->>'id',
    'mime', v_midia->>'mime_type', 'nome', v_midia->>'filename') end);
end $$;

-- ------------------------------------------------------------
-- Um aviso (webhook) inteiro da Meta. Devolve as mídias a baixar.
-- ------------------------------------------------------------
create or replace function public.wa_processar(corpo jsonb)
returns jsonb
language plpgsql security definer set search_path = public, migracao, pg_temp as $$
declare
  ch jsonb; v jsonb; m jsonb; st jsonb; ct jsonb; h jsonb; th jsonb; ss jsonb; r jsonb;
  v_campo text; v_numero text; v_exibicao text; v_tel text; v_dir text; v_status text;
  ordem constant text[] := array['enviando','enviada','entregue','lida'];
  midias jsonb := '[]'::jsonb; n_msg integer := 0; n_status integer := 0; n_hist integer := 0;
  n_eco integer := 0; n_cont integer := 0; n_erro integer := 0;
begin
  for ch in
    select c from jsonb_array_elements(coalesce(corpo->'entry', '[]'::jsonb)) e,
                  jsonb_array_elements(coalesce(e->'changes', '[]'::jsonb)) c
    where c->>'field' in ('messages', 'smb_message_echoes', 'history', 'smb_app_state_sync')
  loop
    v_campo := ch->>'field';
    v := ch->'value';
    v_numero := v->'metadata'->>'phone_number_id';
    v_exibicao := regexp_replace(coalesce(v->'metadata'->>'display_phone_number', ''), '\D', '', 'g');
    if v_numero is null then continue; end if;

    -- 1) mensagens recebidas dos pacientes
    for m in select x from jsonb_array_elements(coalesce(v->'messages', '[]'::jsonb)) x loop
      begin
        select x into ct from jsonb_array_elements(coalesce(v->'contacts', '[]'::jsonb)) x
         where x->>'wa_id' = m->>'from' limit 1;
        r := public.wa_guardar(v_numero, m->>'from', m, 'recebida', 'paciente', 'recebida',
                               true, true, ct->'profile'->>'name');
        if r is not null then
          if (r->>'nova')::boolean then n_msg := n_msg + 1; end if;
          if r->'midia' is not null and jsonb_typeof(r->'midia') = 'object' then midias := midias || jsonb_build_array(r->'midia'); end if;
        end if;
      exception when others then n_erro := n_erro + 1;
        insert into public.whatsapp_eventos_brutos (corpo, erro) values (m, 'mensagem: ' || sqlerrm);
      end;
    end loop;

    -- 2) o que a equipe enviou pelo app do celular (coexistência)
    for m in select x from jsonb_array_elements(coalesce(v->'message_echoes', '[]'::jsonb)) x loop
      begin
        r := public.wa_guardar(v_numero, m->>'to', m, 'enviada', 'celular', 'enviada', false, false, null);
        if r is not null then
          if (r->>'nova')::boolean then n_eco := n_eco + 1; end if;
          if r->'midia' is not null and jsonb_typeof(r->'midia') = 'object' then midias := midias || jsonb_build_array(r->'midia'); end if;
        end if;
      exception when others then n_erro := n_erro + 1;
        insert into public.whatsapp_eventos_brutos (corpo, erro) values (m, 'eco: ' || sqlerrm);
      end;
    end loop;

    -- 3) histórico importado do celular
    for h in select x from jsonb_array_elements(coalesce(v->'history', '[]'::jsonb)) x loop
      if h ? 'errors' then
        update public.whatsapp_numeros set historico_erro = coalesce(h->'errors'->0->>'message', h->'errors'->0->>'title', 'erro')
         where phone_number_id = v_numero;
        continue;
      end if;
      update public.whatsapp_numeros
         set historico_progresso = greatest(coalesce(historico_progresso, 0), coalesce((h->'metadata'->>'progress')::int, 0))
       where phone_number_id = v_numero;
      for th in select x from jsonb_array_elements(coalesce(h->'threads', '[]'::jsonb)) x loop
        for m in select x from jsonb_array_elements(coalesce(th->'messages', '[]'::jsonb)) x loop
          begin
            v_tel := th->>'id';
            v_dir := case when regexp_replace(coalesce(m->>'from', ''), '\D', '', 'g') = v_exibicao
                            or (m ? 'to' and regexp_replace(m->>'from', '\D', '', 'g') <> regexp_replace(v_tel, '\D', '', 'g'))
                          then 'enviada' else 'recebida' end;
            v_status := case upper(coalesce(m->'history_context'->>'status', ''))
                          when 'READ' then 'lida' when 'PLAYED' then 'lida' when 'DELIVERED' then 'entregue'
                          when 'SENT' then 'enviada' when 'PENDING' then 'enviando' when 'ERROR' then 'falhou'
                          else 'enviada' end;
            if v_dir = 'recebida' then v_status := 'recebida'; end if;
            r := public.wa_guardar(v_numero, v_tel, m, v_dir, 'historico', v_status, false, false, null);
            if r is not null then
              if (r->>'nova')::boolean then n_hist := n_hist + 1; end if;
              if r->'midia' is not null and jsonb_typeof(r->'midia') = 'object' then midias := midias || jsonb_build_array(r->'midia'); end if;
            end if;
          exception when others then n_erro := n_erro + 1;
            insert into public.whatsapp_eventos_brutos (corpo, erro) values (m, 'historico: ' || sqlerrm);
          end;
        end loop;
      end loop;
    end loop;

    -- 4) contatos salvos no celular
    for ss in select x from jsonb_array_elements(coalesce(v->'state_sync', '[]'::jsonb)) x loop
      if ss->>'type' <> 'contact' then continue; end if;
      v_tel := migracao.tel(ss->'contact'->>'phone_number');
      if v_tel is null then continue; end if;
      if ss->>'action' = 'remove' then
        delete from public.whatsapp_contatos where numero_clinica_id = v_numero and telefone = v_tel;
        update public.conversas set nome_contato = null where numero_clinica_id = v_numero and telefone = v_tel;
      else
        insert into public.whatsapp_contatos (numero_clinica_id, telefone, nome)
        values (v_numero, v_tel, coalesce(ss->'contact'->>'full_name', ss->'contact'->>'first_name'))
        on conflict (numero_clinica_id, telefone) do update set nome = excluded.nome, atualizado_em = now();
        update public.conversas set nome_contato = coalesce(ss->'contact'->>'full_name', ss->'contact'->>'first_name')
         where numero_clinica_id = v_numero and telefone = v_tel;
      end if;
      n_cont := n_cont + 1;
    end loop;

    -- 5) status das mensagens enviadas pelo CRM
    for st in select x from jsonb_array_elements(coalesce(v->'statuses', '[]'::jsonb)) x loop
      v_status := case st->>'status' when 'sent' then 'enviada' when 'delivered' then 'entregue'
                                     when 'read' then 'lida' when 'failed' then 'falhou' end;
      if v_status is null then continue; end if;
      update public.mensagens set
        status = v_status,
        erro = case when v_status = 'falhou'
                    then coalesce(st->'errors'->0->>'title', '') || ' ' || coalesce(st->'errors'->0->'error_data'->>'details', st->'errors'->0->>'message', '')
                    else erro end,
        atualizada_em = now()
      where wa_message_id = st->>'id'
        and direcao = 'enviada'
        and (v_status = 'falhou' or array_position(ordem, v_status) > coalesce(array_position(ordem, status), 0));
      if found then n_status := n_status + 1; end if;
    end loop;
  end loop;

  return jsonb_build_object('mensagens', n_msg, 'ecos', n_eco, 'historico', n_hist, 'contatos', n_cont,
                            'status', n_status, 'erros', n_erro, 'midias', midias);
end $$;

-- nome do contato salvo no celular vale também para conversas novas
create or replace function public.t_conversa_paciente()
returns trigger language plpgsql security definer set search_path = public, migracao, pg_temp as $$
begin
  if new.paciente_id is null then
    select id into new.paciente_id from public.pacientes where telefone = new.telefone;
  end if;
  if new.nome_contato is null then
    select nome into new.nome_contato from public.whatsapp_contatos
     where numero_clinica_id = new.numero_clinica_id and telefone = new.telefone;
  end if;
  return new;
end $$;

-- Mensagem enviada pelo CRM (agora com canal)
create or replace function public.wa_registrar_enviada(
  p_conversa uuid, p_wa_message_id text, p_tipo text, p_texto text, p_autor text,
  p_status text, p_erro text, p_bruto jsonb)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid;
begin
  insert into public.mensagens (conversa_id, wa_message_id, direcao, tipo, texto, status, erro, autor_email, canal, bruto)
  values (p_conversa, p_wa_message_id, 'enviada', p_tipo, p_texto, p_status, p_erro, p_autor, 'crm', p_bruto)
  returning id into v_id;
  if p_status <> 'falhou' then
    update public.conversas set ultima_mensagem_em = now(), ultima_mensagem_texto = p_texto,
           nao_lidas = 0, status = 'aguardando'
     where id = p_conversa;
  end if;
  return v_id;
end $$;

-- Número conectado pelo botão do CRM (chamado só pela função whatsapp-acoes)
create or replace function public.wa_salvar_numero(
  p_phone_number_id text, p_waba_id text, p_exibicao text, p_apelido text, p_token text,
  p_coexistencia boolean, p_por text)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  insert into public.whatsapp_numeros
    (phone_number_id, waba_id, numero_exibicao, apelido, token, coexistencia, conectado_por, conectado_em, ativo)
  values (p_phone_number_id, p_waba_id, p_exibicao, p_apelido, p_token, p_coexistencia, p_por, now(), true)
  on conflict (phone_number_id) do update set
    waba_id = excluded.waba_id, numero_exibicao = excluded.numero_exibicao,
    apelido = coalesce(public.whatsapp_numeros.apelido, excluded.apelido),
    token = coalesce(excluded.token, public.whatsapp_numeros.token),
    coexistencia = excluded.coexistencia, conectado_por = excluded.conectado_por,
    conectado_em = now(), ativo = true;
end $$;

revoke all on function public.wa_guardar(text, text, jsonb, text, text, text, boolean, boolean, text) from public, anon, authenticated;
revoke all on function public.wa_processar(jsonb) from public, anon, authenticated;
revoke all on function public.wa_registrar_enviada(uuid, text, text, text, text, text, text, jsonb) from public, anon, authenticated;
revoke all on function public.wa_salvar_numero(text, text, text, text, text, boolean, text) from public, anon, authenticated;
grant execute on function public.wa_guardar(text, text, jsonb, text, text, text, boolean, boolean, text) to service_role;
grant execute on function public.wa_processar(jsonb) to service_role;
grant execute on function public.wa_registrar_enviada(uuid, text, text, text, text, text, text, jsonb) to service_role;
grant execute on function public.wa_salvar_numero(text, text, text, text, text, boolean, text) to service_role;

select 'numeros e coexistencia prontos' as status,
       (select count(*) from public.whatsapp_numeros) as numeros,
       (select count(*) from information_schema.columns where table_name = 'mensagens' and column_name = 'canal') as coluna_canal;
