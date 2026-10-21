-- ============================================================
-- CRM Bulhões — conferir_espelho() mais rápida (21/10/2026)
-- A versão anterior repetia a contagem de orçamentos para cada paciente e
-- passava do limite de 8 s do site. Esta agrupa tudo de uma vez.
-- Rodar no Supabase: SQL Editor → New query → colar tudo → Run.
-- ============================================================
create or replace function public.conferir_espelho()
returns jsonb
language plpgsql stable security definer set search_path = public, migracao, pg_temp
-- o banco estima 1 linha para o bloco do CRM e escolheria comparar todos com todos
set enable_nestloop = off as $$
declare r jsonb;
begin
  if not (public.tem_papel('gestao') or session_user = 'postgres') then
    raise exception 'Só a gestão pode conferir o espelho.';
  end if;

  with src as (
    select k, v, migracao.tel(k) as tel, (k = migracao.tel(k)) as canonica
    from public.crm_sessions s0, jsonb_each(s0.crm_json::jsonb) e(k, v)
    where s0.email_clinica = 'bulhoes-clinica-crm' and k ~ '^\d+$' and jsonb_typeof(v) = 'object'
  ), ord as (
    select *, row_number() over (partition by tel order by canonica desc, k) as prio
    from src where tel ~ '^[0-9]{10,13}$'
  ), campos as (
    select tel,
           (array_remove(array_agg(nullif(v->>'statusAtual', '') order by prio), null))[1] as etapa,
           (array_remove(array_agg(nullif(v->>'nomeAtual', '') order by prio), null))[1] as nome
    from ord group by tel
  ), orc_esperado as (
    select ord.tel, count(distinct coalesce('c' || nullif(o->>'_clinicorpId', ''), md5(o::text))) as n
    from ord, jsonb_array_elements(case when jsonb_typeof(ord.v->'orcamentos') = 'array' then ord.v->'orcamentos' else '[]'::jsonb end) o
    where jsonb_typeof(o) = 'object'
    group by ord.tel
  ), orc_novo as (
    select p.telefone as tel, count(o.id) as n
    from public.pacientes p join public.orcamentos o on o.paciente_id = p.id
    group by p.telefone
  ), comparado as (
    select c.tel, c.etapa, c.nome, p.id as pid, p.etapa as p_etapa, p.nome as p_nome,
           coalesce(oe.n, 0) as orc_e, coalesce(onv.n, 0) as orc_n
    from campos c
    left join public.pacientes p on p.telefone = c.tel
    left join orc_esperado oe on oe.tel = c.tel
    left join orc_novo onv on onv.tel = c.tel
  )
  select jsonb_build_object(
    'conferido_em', now(),
    'crm_gravado_em', (select atualizado_em from public.crm_sessions where email_clinica = 'bulhoes-clinica-crm'),
    'paciente_atualizado_em', (select max(atualizado_em) from public.pacientes),
    'telefones_no_crm', (select count(*) from comparado),
    'faltando_na_base_nova', (select count(*) from comparado where pid is null),
    'etapa_diferente', (select count(*) from comparado where pid is not null and etapa is distinct from p_etapa),
    'nome_diferente', (select count(*) from comparado where pid is not null and nome is distinct from p_nome),
    'orcamentos_diferentes', (select count(*) from comparado where pid is not null and orc_e <> orc_n),
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
