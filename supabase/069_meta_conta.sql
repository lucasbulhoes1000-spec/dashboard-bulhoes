-- 069 (01/11/2026) conta de anúncios de cada anúncio (para separar a clínica do Instituto)
alter table public.meta_estrutura add column if not exists conta text;
create index if not exists meta_estrutura_conta on public.meta_estrutura (conta);
select 'ok' as status;
