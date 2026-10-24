-- ============================================================
-- CRM Bulhões — Dashboard rápido (24/10/2026)
-- O Dashboard esperava o Apps Script toda vez que abria (funil por anúncio
-- ~12 s, Meta ~5 s, agenda e vendas do Clinicorp ~6 s cada). Agora a última
-- resposta de cada período fica guardada aqui: o Dashboard abre na hora com
-- ela e busca a versão nova em segundo plano. Quem abrir depois (em qualquer
-- aparelho) já encontra o retrato mais recente.
-- Guarda o texto exato que o Apps Script devolveu (não jsonb, para não mudar
-- a ordem dos campos).
-- Rodar no Supabase: SQL Editor → New query → colar tudo → Run.
-- ============================================================

create table if not exists public.cache_painel (
  chave          text primary key,          -- ação|de|até (ex.: funilMetaFinal|2026-10-01|2026-10-24)
  texto          text not null,
  atualizado_em  timestamptz not null default now(),
  atualizado_por text default (auth.jwt() ->> 'email')
);

alter table public.cache_painel enable row level security;

drop policy if exists cache_painel_ver on public.cache_painel;
drop policy if exists cache_painel_gravar on public.cache_painel;
drop policy if exists cache_painel_atualizar on public.cache_painel;
create policy cache_painel_ver on public.cache_painel for select to authenticated
  using ((select public.is_equipe_crm()));
create policy cache_painel_gravar on public.cache_painel for insert to authenticated
  with check ((select public.is_equipe_crm()));
create policy cache_painel_atualizar on public.cache_painel for update to authenticated
  using ((select public.is_equipe_crm())) with check ((select public.is_equipe_crm()));

revoke all on public.cache_painel from anon;
grant select, insert, update on public.cache_painel to authenticated;

-- limpeza: períodos que ninguém abre há mais de 60 dias
create or replace function public.cache_painel_limpar()
returns void language sql security definer set search_path = public as $$
  delete from public.cache_painel where atualizado_em < now() - interval '60 days';
$$;
revoke all on function public.cache_painel_limpar() from public, anon, authenticated;
do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'cache_painel_limpar';
    perform cron.schedule('cache_painel_limpar', '17 4 * * *', 'select public.cache_painel_limpar()');
  end if;
end $$;

-- cópia da planilha: a permissão passa a ser checada uma vez por consulta,
-- não uma vez por linha (mesma regra, leitura mais rápida)
drop policy if exists importacao_ver on public.importacao_cloudia;
create policy importacao_ver on public.importacao_cloudia for select to authenticated
  using ((select public.is_equipe_crm()));

select 'dashboard rápido pronto' as status;
