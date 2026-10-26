-- ============================================================
-- CRM Bulhões — cache simples para a função crm-dados (25/10/2026)
-- (substitui o CacheService do Apps Script: ex. telefone por paciente do Clinicorp)
-- ============================================================
create table if not exists public.cache_kv (
  chave   text primary key,
  valor   jsonb not null,
  expira  timestamptz not null
);
alter table public.cache_kv enable row level security;
revoke all on public.cache_kv from anon, authenticated;
select 'cache_kv pronto' as status;
