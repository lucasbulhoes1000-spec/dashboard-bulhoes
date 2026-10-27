-- ============================================================
-- CRM Bulhões — Direct do Instagram na Central (27/10/2026)
--
--   • instagram_contas: as contas conectadas (Clínica e Dra. Larissa), com a
--     Página do Facebook ligada a cada uma e quem atende por padrão (Lívia).
--   • conversas.canal = 'instagram'. A conversa do Instagram usa
--       numero_clinica_id = id da conta do Instagram da clínica
--       telefone          = 'ig:' || id da pessoa no Instagram (IGSID)
--       wa_id             = IGSID
--     O "telefone" com 'ig:' nunca bate com paciente, lead, sequência,
--     lembrete nem funil (todos exigem telefone só com dígitos), então o
--     Instagram não dispara nada do WhatsApp. O Agente de IA também fica fora.
--   • ig_processar(corpo): grava o aviso da Meta (object = instagram):
--     mensagem recebida, eco do que a equipe mandou pelo app do Instagram,
--     leitura e reação. Devolve as mídias para o webhook baixar.
-- Rodar no Supabase: SQL Editor → New query → colar tudo → Run.
-- ============================================================

create table if not exists public.instagram_contas (
  ig_id         text primary key,             -- id da conta profissional do Instagram
  page_id       text,                         -- Página do Facebook ligada à conta
  usuario       text,                         -- @ sem arroba
  apelido       text,                         -- Clínica, Dra. Larissa
  atribuir_a    text references public.equipe(email) on delete set null,  -- quem atende por padrão
  ativo         boolean not null default true,
  conectado_em  timestamptz not null default now()
);
alter table public.instagram_contas enable row level security;
revoke all on public.instagram_contas from anon, authenticated;
grant select on public.instagram_contas to authenticated;
drop policy if exists instagram_contas_ver on public.instagram_contas;
create policy instagram_contas_ver on public.instagram_contas for select to authenticated
  using (public.tem_papel('gestao', 'avaliacao', 'comercial'));

alter table public.conversas add column if not exists canal text not null default 'whatsapp';
do $$ begin
  alter table public.conversas add constraint conversas_canal_ck check (canal in ('whatsapp', 'instagram'));
exception when duplicate_object then null; end $$;
alter table public.conversas add column if not exists ig_usuario text;     -- @ da pessoa
create index if not exists conversas_canal on public.conversas (canal);

-- mídia do Instagram chega como link (não como id): guardamos o link para baixar
alter table public.mensagens add column if not exists midia_url text;

-- ------------------------------------------------------------
-- Texto legível de uma mensagem do Instagram
-- ------------------------------------------------------------
create or replace function public.ig_texto(msg jsonb)
returns text language sql immutable as $$
  select coalesce(
    nullif(msg->>'text', ''),
    case msg->'attachments'->0->>'type'
      when 'image' then '📷 Foto'
      when 'video' then '🎥 Vídeo'
      when 'audio' then '🎤 Áudio'
      when 'file' then '📄 Arquivo'
      when 'share' then '🔗 Publicação compartilhada'
      when 'ig_reel' then '🎬 Reel compartilhado'
      when 'reel' then '🎬 Reel compartilhado'
      when 'story_mention' then '📣 Mencionou a clínica no story'
      when 'ig_post' then '🔗 Publicação compartilhada'
      else null end,
    case when msg ? 'reply_to' and msg->'reply_to' ? 'story' then '💬 Respondeu ao story' end,
    '(mensagem)');
$$;

create or replace function public.ig_tipo(msg jsonb)
returns text language sql immutable as $$
  select case
    when msg->'attachments'->0->>'type' in ('image', 'video', 'audio') then msg->'attachments'->0->>'type'
    when msg->'attachments'->0->>'type' = 'file' then 'document'
    when msg->'attachments' is not null then 'ig_' || coalesce(msg->'attachments'->0->>'type', 'anexo')
    else 'text' end;
$$;

-- Conversa de uma pessoa numa conta do Instagram (cria se não existir)
create or replace function public.ig_conversa(p_conta text, p_igsid text)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid; v_dono text;
begin
  if coalesce(p_conta, '') = '' or coalesce(p_igsid, '') = '' then raise exception 'conta ou pessoa vazia'; end if;
  select id into v_id from public.conversas where numero_clinica_id = p_conta and telefone = 'ig:' || p_igsid;
  if v_id is not null then return v_id; end if;
  select atribuir_a into v_dono from public.instagram_contas where ig_id = p_conta;
  insert into public.conversas (numero_clinica_id, telefone, wa_id, canal, atribuida_a)
  values (p_conta, 'ig:' || p_igsid, p_igsid, 'instagram', v_dono)
  on conflict (numero_clinica_id, telefone) do update set wa_id = excluded.wa_id
  returning id into v_id;
  return v_id;
end $$;
revoke all on function public.ig_conversa(text, text) from public, anon, authenticated;

-- ------------------------------------------------------------
-- Um aviso (webhook) do Instagram inteiro
-- ------------------------------------------------------------
create or replace function public.ig_processar(corpo jsonb)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  e jsonb; ev jsonb; msg jsonb; v_conta text; v_pessoa text; v_eco boolean; v_conv uuid; v_msg uuid;
  v_ts timestamptz; v_texto text; v_tipo text; v_url text;
  midias jsonb := '[]'::jsonb; n_msg integer := 0; n_eco integer := 0; n_lida integer := 0; n_erro integer := 0;
begin
  if coalesce(corpo->>'object', '') <> 'instagram' then return jsonb_build_object('ignorado', true); end if;
  for e in select x from jsonb_array_elements(coalesce(corpo->'entry', '[]'::jsonb)) x loop
    v_conta := e->>'id';
    for ev in select x from jsonb_array_elements(coalesce(e->'messaging', '[]'::jsonb)) x loop
      begin
        msg := ev->'message';
        v_eco := coalesce((msg->>'is_echo')::boolean, false);
        v_pessoa := case when v_eco then ev->'recipient'->>'id' else ev->'sender'->>'id' end;
        if v_pessoa is null or v_pessoa = v_conta then continue; end if;
        v_ts := to_timestamp(coalesce(nullif(ev->>'timestamp', '')::numeric / 1000, extract(epoch from now())));

        -- leitura: a pessoa leu o que a clínica mandou
        if ev ? 'read' then
          v_conv := (select id from public.conversas where numero_clinica_id = v_conta and telefone = 'ig:' || v_pessoa);
          if v_conv is not null then
            update public.mensagens set status = 'lida', atualizada_em = now()
             where conversa_id = v_conv and direcao = 'enviada' and status in ('enviada', 'entregue') and enviada_em <= v_ts;
            n_lida := n_lida + 1;
          end if;
          continue;
        end if;

        if msg is null then continue; end if;
        if coalesce((msg->>'is_deleted')::boolean, false) then
          update public.mensagens set texto = '(mensagem apagada)', atualizada_em = now() where wa_message_id = msg->>'mid';
          continue;
        end if;

        v_conv := public.ig_conversa(v_conta, v_pessoa);
        v_texto := public.ig_texto(msg);
        v_tipo := public.ig_tipo(msg);
        v_url := msg->'attachments'->0->'payload'->>'url';

        insert into public.mensagens (conversa_id, wa_message_id, direcao, tipo, texto, midia_url, status, responde_a, enviada_em, canal, bruto)
        values (v_conv, msg->>'mid', case when v_eco then 'enviada' else 'recebida' end, v_tipo, v_texto, v_url,
                case when v_eco then 'enviada' else 'recebida' end, msg->'reply_to'->>'mid', v_ts,
                case when v_eco then 'celular' else 'paciente' end, ev)
        on conflict (wa_message_id) do nothing
        returning id into v_msg;
        if v_msg is null then continue; end if;   -- eco do que o próprio CRM mandou (já gravado) ou repetido

        update public.conversas c set
          ultima_mensagem_em = greatest(coalesce(c.ultima_mensagem_em, v_ts), v_ts),
          ultima_mensagem_texto = case when c.ultima_mensagem_em is null or v_ts >= c.ultima_mensagem_em then v_texto else c.ultima_mensagem_texto end,
          ultima_recebida_em = case when v_eco then c.ultima_recebida_em else greatest(coalesce(c.ultima_recebida_em, v_ts), v_ts) end,
          nao_lidas = case when v_eco then 0 else c.nao_lidas + 1 end,
          status = case when v_eco then 'aguardando' else 'aberta' end
        where c.id = v_conv;

        if v_eco then n_eco := n_eco + 1; else n_msg := n_msg + 1; end if;
        if v_url is not null and v_tipo in ('image', 'video', 'audio', 'document') then
          midias := midias || jsonb_build_array(jsonb_build_object('mensagem_id', v_msg, 'conversa_id', v_conv, 'url', v_url, 'tipo', v_tipo));
        end if;
      exception when others then
        n_erro := n_erro + 1;
        insert into public.whatsapp_eventos_brutos (corpo, erro) values (ev, 'instagram: ' || sqlerrm);
      end;
    end loop;
  end loop;
  return jsonb_build_object('mensagens', n_msg, 'ecos', n_eco, 'lidas', n_lida, 'erros', n_erro, 'midias', midias);
end $$;
revoke all on function public.ig_processar(jsonb) from public, anon, authenticated;
grant execute on function public.ig_processar(jsonb) to service_role;

-- ------------------------------------------------------------
-- Agente de IA fica fora do Instagram (por enquanto)
-- ------------------------------------------------------------
do $$
declare d text;
begin
  d := pg_get_functiondef('public.agente_t_mensagem()'::regprocedure);
  if position('canal = ''instagram''' in d) = 0 then
    d := replace(d, '  if c.id is null then return null; end if;',
                    '  if c.id is null or c.canal = ''instagram'' then return null; end if;');
    execute d;
  end if;
end $$;

select (select count(*) from public.conversas where canal = 'instagram') as conversas_instagram,
       position('canal = ''instagram''' in pg_get_functiondef('public.agente_t_mensagem()'::regprocedure)) > 0 as agente_fora_do_instagram;
