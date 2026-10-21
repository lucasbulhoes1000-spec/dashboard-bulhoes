-- ============================================================
-- CRM Bulhões — correção: migrar as listas (origens, status, tratamentos,
-- fases, avaliadores). Só mexe na tabela nova "listas". 21/10/2026
-- Rodar no Supabase: SQL Editor → New query → colar tudo → Run.
-- ============================================================
alter table public.listas add column if not exists fixo boolean not null default false;
delete from public.listas;
insert into public.listas (tipo, valor, ordem, ativo, fixo)
select distinct on (l.tipo, l.valor) l.tipo, l.valor, l.ordem, l.ativo, l.fixo
from (
  select e.key as tipo, btrim(it.value #>> '{}') as valor, it.ordinality::int as ordem,
         g.grupo <> 'desativos' as ativo, g.grupo = 'padroes' as fixo, g.prio
  from public.crm_sessions s,
       lateral jsonb_each(case when jsonb_typeof(s.listas_json::jsonb) = 'object' then s.listas_json::jsonb else '{}'::jsonb end) e,
       lateral (values ('padroes', 1), ('ativos', 2), ('desativos', 3)) g(grupo, prio),
       lateral jsonb_array_elements(case when jsonb_typeof(e.value -> g.grupo) = 'array' then e.value -> g.grupo else '[]'::jsonb end)
               with ordinality it(value, ordinality)
  where s.email_clinica = 'bulhoes-clinica-crm'
) l
where l.valor is not null and l.valor <> ''
order by l.tipo, l.valor, l.prio;


select tipo,
       count(*) filter (where fixo)               as fixos,
       count(*) filter (where ativo and not fixo) as ativos,
       count(*) filter (where not ativo)          as desativados
from public.listas group by tipo order by tipo;
