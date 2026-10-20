-- ============================================================
-- Proteção do CRM Bulhões (RLS) — 20/10/2026 (v2)
-- Rodar no Supabase: SQL Editor → New query → colar tudo → Run.
-- Só a tabela crm_sessions (auditoria_log não existe neste banco).
-- ============================================================

create or replace function public.is_equipe_crm()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(lower(auth.jwt() ->> 'email'), '') = any (array[
    'lucasbulhoes1000@gmail.com',
    'larissa@bulhoesodontologia.com.br',
    'livia@bulhoesodontologia.com.br',
    'raffaella@bulhoesodontologia.com.br',
    'victoria@bulhoesodontologia.com.br'
  ]);
$$;

do $$
declare r record;
begin
  for r in
    select policyname from pg_policies
    where schemaname = 'public' and tablename = 'crm_sessions'
  loop
    execute format('drop policy %I on public.crm_sessions', r.policyname);
  end loop;
end $$;

alter table public.crm_sessions enable row level security;

create policy equipe_crm_acesso on public.crm_sessions
  for all to authenticated
  using (public.is_equipe_crm())
  with check (public.is_equipe_crm());

select c.relname as tabela, c.relrowsecurity as rls_ligado, p.policyname
from pg_class c
left join pg_policies p on p.tablename = c.relname and p.schemaname = 'public'
where c.relname = 'crm_sessions';
