-- ============================================================
-- CRM Bulhões — Fase 2: WhatsApp dentro do CRM (21/10/2026)
--
-- Tabelas:
--   conversas  → uma por telefone de paciente e número da clínica
--   mensagens  → cada mensagem recebida ou enviada, com status (enviada,
--                entregue, lida, falhou) e mídia (foto, áudio, documento)
-- Mídia: pasta privada "whatsapp-midia" no Storage da Supabase.
-- Quem grava: as funções whatsapp-webhook (recebe da Meta) e whatsapp-enviar
-- (envia pelo CRM). A equipe logada só lê e marca como lida/atribui.
-- Tempo real: a tela de conversas atualiza sozinha quando chega mensagem.
-- Rodar no Supabase: SQL Editor → New query → colar tudo → Run.
-- ============================================================

create table if not exists public.conversas (
  id                    uuid primary key default gen_random_uuid(),
  numero_clinica_id     text not null,                 -- phone_number_id da Meta (número da clínica)
  telefone              text not null,                 -- telefone do paciente, 11 dígitos sem 55
  wa_id                 text not null,                 -- como a Meta identifica o paciente (com 55)
  paciente_id           uuid references public.pacientes(id) on delete set null,
  nome_perfil           text,                          -- nome do perfil do WhatsApp do paciente
  ultima_mensagem_em    timestamptz,
  ultima_mensagem_texto text,
  ultima_recebida_em    timestamptz,                   -- para a janela de 24 h
  janela_gratis_ate     timestamptz,                   -- anúncio de clique para WhatsApp (até 72 h/7 dias)
  nao_lidas             integer not null default 0,
  atribuida_a           text references public.equipe(email) on delete set null,
  status                text not null default 'aberta' check (status in ('aberta', 'aguardando', 'encerrada')),
  criada_em             timestamptz not null default now(),
  unique (numero_clinica_id, telefone)
);
create index if not exists conversas_recentes on public.conversas (ultima_mensagem_em desc);
create index if not exists conversas_paciente on public.conversas (paciente_id);

create table if not exists public.mensagens (
  id               uuid primary key default gen_random_uuid(),
  conversa_id      uuid not null references public.conversas(id) on delete cascade,
  wa_message_id    text unique,                        -- id da Meta (wamid...)
  direcao          text not null check (direcao in ('recebida', 'enviada')),
  tipo             text not null,                      -- text, image, audio, video, document, sticker, location, template, ...
  texto            text,
  midia_id         text,                               -- id da mídia na Meta
  midia_tipo       text,                               -- mime type
  midia_caminho    text,                               -- caminho no Storage (whatsapp-midia/...)
  midia_nome       text,
  status           text not null default 'recebida'
                   check (status in ('recebida', 'enviando', 'enviada', 'entregue', 'lida', 'falhou')),
  erro             text,
  responde_a       text,                               -- wamid da mensagem citada
  autor_email      text,                               -- quem enviou pelo CRM
  origem_anuncio   jsonb,                              -- referral (anúncio de clique para WhatsApp)
  enviada_em       timestamptz not null default now(), -- horário da mensagem (da Meta, quando recebida)
  atualizada_em    timestamptz not null default now(),
  bruto            jsonb
);
create index if not exists mensagens_conversa on public.mensagens (conversa_id, enviada_em);

create table if not exists public.whatsapp_eventos_brutos (
  id         bigint generated always as identity primary key,
  recebido   timestamptz not null default now(),
  corpo      jsonb not null,
  erro       text
);
create index if not exists whatsapp_eventos_brutos_data on public.whatsapp_eventos_brutos (recebido desc);

-- ------------------------------------------------------------
-- Segurança
-- ------------------------------------------------------------
alter table public.conversas enable row level security;
alter table public.mensagens enable row level security;
alter table public.whatsapp_eventos_brutos enable row level security;
revoke all on public.conversas, public.mensagens, public.whatsapp_eventos_brutos from anon;
revoke all on public.whatsapp_eventos_brutos from authenticated;

do $$
declare r record;
begin
  for r in select policyname, tablename from pg_policies
           where schemaname = 'public' and tablename in ('conversas', 'mensagens')
  loop execute format('drop policy %I on public.%I', r.policyname, r.tablename); end loop;
end $$;

-- Ver: gestão, avaliação e comercial (quem atende); clínica não vê conversas
create policy conversas_ver on public.conversas for select to authenticated
  using (public.tem_papel('gestao', 'avaliacao', 'comercial'));
create policy mensagens_ver on public.mensagens for select to authenticated
  using (public.tem_papel('gestao', 'avaliacao', 'comercial'));

-- A equipe só pode mexer em atribuição, status e não lidas (o resto é das funções)
create policy conversas_atender on public.conversas for update to authenticated
  using (public.tem_papel('gestao', 'avaliacao', 'comercial'))
  with check (public.tem_papel('gestao', 'avaliacao', 'comercial'));
revoke update on public.conversas from authenticated;
grant update (atribuida_a, status, nao_lidas) on public.conversas to authenticated;
grant select on public.conversas, public.mensagens to authenticated;

-- ------------------------------------------------------------
-- Ligação automática com o paciente pelo telefone
-- ------------------------------------------------------------
create or replace function public.t_conversa_paciente()
returns trigger language plpgsql security definer set search_path = public, migracao, pg_temp as $$
begin
  if new.paciente_id is null then
    select id into new.paciente_id from public.pacientes where telefone = new.telefone;
  end if;
  return new;
end $$;
drop trigger if exists t_conversa_paciente on public.conversas;
create trigger t_conversa_paciente before insert or update of telefone on public.conversas
  for each row execute function public.t_conversa_paciente();


-- ------------------------------------------------------------
-- Processamento (chamado só pelas funções da Supabase)
-- ------------------------------------------------------------
-- Conversa de um telefone num número da clínica (cria se não existir)
create or replace function public.wa_conversa(p_numero text, p_wa_id text)
returns uuid
language plpgsql security definer set search_path = public, migracao, pg_temp as $$
declare v_id uuid; v_tel text := migracao.tel(p_wa_id);
begin
  if v_tel is null then raise exception 'telefone inválido: %', p_wa_id; end if;
  insert into public.conversas (numero_clinica_id, telefone, wa_id)
  values (p_numero, v_tel, regexp_replace(p_wa_id, '\D', '', 'g'))
  on conflict (numero_clinica_id, telefone) do update set wa_id = excluded.wa_id
  returning id into v_id;
  return v_id;
end $$;

-- Texto legível de uma mensagem da Meta, para lista e notificação
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
    else '(' || coalesce(m->>'type', 'mensagem') || ')'
  end;
$$;

-- Um aviso (webhook) inteiro da Meta. Devolve as mídias a baixar.
create or replace function public.wa_processar(corpo jsonb)
returns jsonb
language plpgsql security definer set search_path = public, migracao, pg_temp as $$
declare
  ch jsonb; v jsonb; m jsonb; st jsonb; ct jsonb;
  v_numero text; v_conversa uuid; v_msg uuid; v_ts timestamptz; v_tipo text; v_midia jsonb;
  v_status text; ordem constant text[] := array['enviando','enviada','entregue','lida'];
  midias jsonb := '[]'::jsonb; n_msg integer := 0; n_status integer := 0;
begin
  for ch in
    select c from jsonb_array_elements(coalesce(corpo->'entry', '[]'::jsonb)) e,
                  jsonb_array_elements(coalesce(e->'changes', '[]'::jsonb)) c
    where c->>'field' = 'messages'
  loop
    v := ch->'value';
    v_numero := v->'metadata'->>'phone_number_id';
    if v_numero is null then continue; end if;

    -- mensagens recebidas
    for m in select x from jsonb_array_elements(coalesce(v->'messages', '[]'::jsonb)) x loop
      v_tipo := m->>'type';
      v_ts := to_timestamp(coalesce(nullif(m->>'timestamp', '')::bigint, extract(epoch from now())::bigint));
      v_conversa := public.wa_conversa(v_numero, m->>'from');
      v_midia := case when v_tipo in ('image', 'audio', 'voice', 'video', 'document', 'sticker') then m->v_tipo end;

      insert into public.mensagens
        (conversa_id, wa_message_id, direcao, tipo, texto, midia_id, midia_tipo, midia_nome,
         status, responde_a, origem_anuncio, enviada_em, bruto)
      values
        (v_conversa, m->>'id', 'recebida', v_tipo, public.wa_texto(m),
         v_midia->>'id', v_midia->>'mime_type', v_midia->>'filename',
         'recebida', m->'context'->>'id', m->'referral', v_ts, m)
      on conflict (wa_message_id) do nothing
      returning id into v_msg;

      if v_msg is null then continue; end if;   -- repetida (a Meta reenvia às vezes)
      n_msg := n_msg + 1;

      select x into ct from jsonb_array_elements(coalesce(v->'contacts', '[]'::jsonb)) x
       where x->>'wa_id' = m->>'from' limit 1;

      update public.conversas c set
        nome_perfil = coalesce(ct->'profile'->>'name', c.nome_perfil),
        ultima_mensagem_em = greatest(coalesce(c.ultima_mensagem_em, v_ts), v_ts),
        ultima_mensagem_texto = case when c.ultima_mensagem_em is null or v_ts >= c.ultima_mensagem_em
                                     then public.wa_texto(m) else c.ultima_mensagem_texto end,
        ultima_recebida_em = greatest(coalesce(c.ultima_recebida_em, v_ts), v_ts),
        janela_gratis_ate = case when m ? 'referral' then greatest(coalesce(c.janela_gratis_ate, v_ts), v_ts + interval '72 hours')
                                 else c.janela_gratis_ate end,
        nao_lidas = c.nao_lidas + 1,
        status = 'aberta'
      where c.id = v_conversa;

      if v_midia ? 'id' then
        midias := midias || jsonb_build_array(jsonb_build_object(
          'mensagem_id', v_msg, 'conversa_id', v_conversa, 'midia_id', v_midia->>'id',
          'mime', v_midia->>'mime_type', 'nome', v_midia->>'filename'));
      end if;
    end loop;

    -- status das mensagens enviadas pelo CRM (as da Cloudia não estão aqui e são ignoradas)
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

  return jsonb_build_object('mensagens', n_msg, 'status', n_status, 'midias', midias);
end $$;

-- Mensagem enviada pelo CRM (depois da resposta da Meta)
create or replace function public.wa_registrar_enviada(
  p_conversa uuid, p_wa_message_id text, p_tipo text, p_texto text, p_autor text,
  p_status text, p_erro text, p_bruto jsonb)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid;
begin
  insert into public.mensagens (conversa_id, wa_message_id, direcao, tipo, texto, status, erro, autor_email, bruto)
  values (p_conversa, p_wa_message_id, 'enviada', p_tipo, p_texto, p_status, p_erro, p_autor, p_bruto)
  returning id into v_id;
  if p_status <> 'falhou' then
    update public.conversas set ultima_mensagem_em = now(), ultima_mensagem_texto = p_texto,
           nao_lidas = 0, status = 'aguardando'
     where id = p_conversa;
  end if;
  return v_id;
end $$;

revoke all on function public.wa_conversa(text, text) from public, anon, authenticated;
revoke all on function public.wa_processar(jsonb) from public, anon, authenticated;
revoke all on function public.wa_registrar_enviada(uuid, text, text, text, text, text, text, jsonb) from public, anon, authenticated;
grant execute on function public.wa_conversa(text, text) to service_role;
grant execute on function public.wa_processar(jsonb) to service_role;
grant execute on function public.wa_registrar_enviada(uuid, text, text, text, text, text, text, jsonb) to service_role;

-- ------------------------------------------------------------
-- Pasta privada para fotos, áudios e documentos
-- ------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('whatsapp-midia', 'whatsapp-midia', false)
on conflict (id) do nothing;

drop policy if exists whatsapp_midia_ver on storage.objects;
create policy whatsapp_midia_ver on storage.objects for select to authenticated
  using (bucket_id = 'whatsapp-midia' and public.tem_papel('gestao', 'avaliacao', 'comercial'));

-- ------------------------------------------------------------
-- Tempo real
-- ------------------------------------------------------------
do $$ begin
  alter publication supabase_realtime add table public.conversas;
exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.mensagens;
exception when duplicate_object then null; when undefined_object then null; end $$;

select 'whatsapp pronto' as status,
       (select count(*) from pg_policies where schemaname = 'public' and tablename in ('conversas', 'mensagens')) as politicas,
       (select count(*) from storage.buckets where id = 'whatsapp-midia') as pasta_midia;
