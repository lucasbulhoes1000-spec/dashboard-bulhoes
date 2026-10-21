-- ============================================================
-- CRM Bulhões — etapa 3: recuperação única + conferência do espelho
-- 21/10/2026
-- 1. Recupera o que mudou no CRM entre a migração e a instalação do espelho.
-- 2. Cria conferir_espelho(): compara CRM atual × base nova e mostra os
--    erros do espelho. Só a gestão (Lucas, Larissa) pode chamar.
-- Rodar no Supabase: SQL Editor → New query → colar tudo → Run.
-- ============================================================

-- 1. Recuperação: ressincroniza todos os pacientes do CRM
select public.espelhar_pacientes_do_crm(
  (select array_agg(distinct migracao.tel(k))
     from public.crm_sessions s, jsonb_object_keys(s.crm_json::jsonb) k
    where s.email_clinica = 'bulhoes-clinica-crm' and k ~ '^\d+$' and migracao.tel(k) is not null),
  (select crm_json::jsonb from public.crm_sessions where email_clinica = 'bulhoes-clinica-crm')
) as pacientes_ressincronizados;

-- 2. Conferência
create or replace function public.conferir_espelho()
returns jsonb
language plpgsql stable security definer set search_path = public, migracao, pg_temp as $$
declare crm jsonb; r jsonb;
begin
  -- gestão logada no site, ou o próprio SQL Editor da Supabase
  if not (public.tem_papel('gestao') or session_user = 'postgres') then
    raise exception 'Só a gestão pode conferir o espelho.';
  end if;
  select crm_json::jsonb into crm from public.crm_sessions where email_clinica = 'bulhoes-clinica-crm';

  with src as (
    select k, v, migracao.tel(k) as tel, (k = migracao.tel(k)) as canonica
    from jsonb_each(crm) e(k, v) where k ~ '^\d+$' and jsonb_typeof(v) = 'object'
  ), ord as (
    select *, row_number() over (partition by tel order by canonica desc, k) as prio from src
    where tel ~ '^[0-9]{10,13}$'
  ), esperado as (
    select tel,
           (array_remove(array_agg(nullif(v->>'statusAtual', '') order by prio), null))[1] as etapa,
           (array_remove(array_agg(nullif(v->>'nomeAtual', '') order by prio), null))[1] as nome,
           (select count(distinct coalesce('c' || nullif(o->>'_clinicorpId', ''), md5(o::text)))
              from ord o2, jsonb_array_elements(case when jsonb_typeof(o2.v->'orcamentos') = 'array' then o2.v->'orcamentos' else '[]'::jsonb end) o
             where o2.tel = ord.tel and jsonb_typeof(o) = 'object') as orcamentos
    from ord group by tel
  )
  select jsonb_build_object(
    'conferido_em', now(),
    'crm_gravado_em', (select atualizado_em from public.crm_sessions where email_clinica = 'bulhoes-clinica-crm'),
    'telefones_no_crm', (select count(*) from esperado),
    'faltando_na_base_nova', (select count(*) from esperado e where not exists (select 1 from public.pacientes p where p.telefone = e.tel)),
    'etapa_diferente', (select count(*) from esperado e join public.pacientes p on p.telefone = e.tel where e.etapa is distinct from p.etapa),
    'nome_diferente', (select count(*) from esperado e join public.pacientes p on p.telefone = e.tel where e.nome is distinct from p.nome),
    'orcamentos_diferentes', (select count(*) from esperado e join public.pacientes p on p.telefone = e.tel
                               where e.orcamentos <> (select count(*) from public.orcamentos o where o.paciente_id = p.id)),
    'linhas_planilha', (select count(*) from public.importacao_cloudia),
    'eventos', (select count(*) from public.eventos_funil),
    'ultimo_espelho_planilha', (select max(recebido_em) from public.importacao_cloudia),
    'erros_24h', (select count(*) from public.espelho_erros where quando > now() - interval '24 hours'),
    'ultimos_erros', (select coalesce(jsonb_agg(jsonb_build_object('quando', quando, 'origem', origem, 'erro', left(erro, 200)) order by quando desc), '[]'::jsonb)
                        from (select * from public.espelho_erros order by quando desc limit 5) z)
  ) into r;
  return r;
end $$;
revoke all on function public.conferir_espelho() from public, anon;
grant execute on function public.conferir_espelho() to authenticated;

select public.conferir_espelho() as conferencia;
