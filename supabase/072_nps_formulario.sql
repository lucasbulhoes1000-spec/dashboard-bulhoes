-- ============================================================
-- CRM Bulhões — Formulário de NPS próprio, com a nota indo direto para o Lume (04/11/2026)
--
--   • nps_convites: um convite por envio (token aleatório no link do WhatsApp).
--   • nps_criar_convite(): a equipe logada gera o link ao clicar em "Enviar NPS".
--   • nps_convite_info(): a página pública /nps.html mostra o primeiro nome do paciente.
--   • nps_responder(): a página pública grava a nota e o comentário no convite e
--     na ficha do paciente (crm_json → <chave>.nps), com registro no crm_patch_log.
--   Sem o token (aleatório, 128 bits) ninguém consegue gravar nada.
-- Rodar no Supabase: SQL Editor → New query → colar tudo → Run.
-- ============================================================

create table if not exists public.nps_convites (
  token         text primary key,
  chave         text not null,
  nome          text,
  criado_por    text,
  criado_em     timestamptz not null default now(),
  respondido_em timestamptz,
  nota          int check (nota between 0 and 10),
  motivo        text
);
create index if not exists nps_convites_chave on public.nps_convites (chave);
alter table public.nps_convites enable row level security;
revoke all on public.nps_convites from anon, authenticated;

create or replace function public.nps_criar_convite(p_chave text, p_nome text default null)
returns text
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_token text;
begin
  if not public.is_equipe_crm() then raise exception 'sem permissão'; end if;
  if coalesce(trim(p_chave), '') = '' then raise exception 'paciente sem telefone'; end if;
  -- reaproveita um convite ainda não respondido do mesmo paciente (mesmo link se reenviar)
  select token into v_token from public.nps_convites
   where chave = p_chave and respondido_em is null and criado_em > now() - interval '60 days'
   order by criado_em desc limit 1;
  if v_token is null then
    v_token := replace(gen_random_uuid()::text, '-', '');
    insert into public.nps_convites (token, chave, nome, criado_por)
    values (v_token, p_chave, nullif(trim(p_nome), ''), coalesce(public.email_atual(), '?'));
  end if;
  return v_token;
end $$;
revoke all on function public.nps_criar_convite(text, text) from public, anon;
grant execute on function public.nps_criar_convite(text, text) to authenticated;

create or replace function public.nps_convite_info(p_token text)
returns jsonb
language sql security definer set search_path = public, pg_temp as $$
  select jsonb_build_object(
           'nome', split_part(coalesce(nome, ''), ' ', 1),
           'respondido', respondido_em is not null)
    from public.nps_convites where token = p_token;
$$;
revoke all on function public.nps_convite_info(text) from public;
grant execute on function public.nps_convite_info(text) to anon, authenticated;

create or replace function public.nps_responder(p_token text, p_nota int, p_motivo text default null)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_chave constant text := 'bulhoes-clinica-crm';
  c public.nps_convites; v_txt text; remoto jsonb; antes jsonb; ficha jsonb; v_nps jsonb;
begin
  if p_nota is null or p_nota < 0 or p_nota > 10 then return jsonb_build_object('status', 'erro', 'mensagem', 'nota inválida'); end if;
  select * into c from public.nps_convites where token = p_token for update;
  if not found then return jsonb_build_object('status', 'erro', 'mensagem', 'link inválido'); end if;
  -- quem já respondeu pode corrigir por até 2 dias; depois o link fica fechado
  if c.respondido_em is not null and c.respondido_em < now() - interval '2 days' then
    return jsonb_build_object('status', 'erro', 'mensagem', 'resposta já registrada');
  end if;

  update public.nps_convites
     set nota = p_nota, motivo = left(nullif(trim(p_motivo), ''), 2000), respondido_em = now()
   where token = p_token;

  select crm_json::text into v_txt from public.crm_sessions where email_clinica = v_chave for update;
  if not found then return jsonb_build_object('status', 'ok', 'crm', false); end if;
  begin remoto := coalesce(nullif(v_txt, ''), '{}')::jsonb;
  exception when others then return jsonb_build_object('status', 'ok', 'crm', false); end;

  antes := remoto->c.chave;
  ficha := case when jsonb_typeof(antes) = 'object' then antes else '{"orcamentos":[],"anotacoes":[]}'::jsonb end;
  v_nps := coalesce(case when jsonb_typeof(ficha->'nps') = 'object' then ficha->'nps' end, '{}'::jsonb)
           || jsonb_build_object('nota', p_nota,
                                 'motivo', coalesce(left(nullif(trim(p_motivo), ''), 2000), ''),
                                 'data', to_char(now() at time zone 'America/Sao_Paulo', 'YYYY-MM-DD'),
                                 'via', 'formulario')
           || case when coalesce(trim(c.nome), '') <> '' then jsonb_build_object('nome', trim(c.nome)) else '{}'::jsonb end;
  ficha := ficha || jsonb_build_object('nps', v_nps);
  remoto := remoto || jsonb_build_object(c.chave, ficha);

  insert into public.crm_patch_log (chave, antes, depois, por) values (c.chave, antes, ficha, 'formulário NPS');
  perform set_config('crm.via_rpc', '1', true);
  update public.crm_sessions set crm_json = remoto::text, atualizado_em = now() where email_clinica = v_chave;
  perform set_config('crm.via_rpc', '', true);
  return jsonb_build_object('status', 'ok', 'crm', true);
end $$;
revoke all on function public.nps_responder(text, int, text) from public;
grant execute on function public.nps_responder(text, int, text) to anon, authenticated;

select to_regclass('public.nps_convites') is not null as tabela_ok;
