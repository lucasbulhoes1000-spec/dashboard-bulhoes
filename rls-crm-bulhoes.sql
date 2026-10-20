-- ============================================================
-- Proteção do CRM Bulhões (RLS) — 20/10/2026
-- Rodar no Supabase: SQL Editor → New query → colar tudo → Run.
-- Só rodar DEPOIS que a equipe já estiver entrando com o login novo.
--
-- Efeito: as tabelas crm_sessions e auditoria_log passam a responder
-- apenas para quem está logado com uma das contas da lista abaixo.
-- A chave pública do site sozinha não lê nem grava mais nada.
-- O Apps Script usa a chave de serviço e continua funcionando normalmente.
-- ============================================================

-- 1) Quem é da equipe (para dar ou tirar acesso, edite esta lista e rode de novo só este bloco)
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

-- 2) Remove políticas antigas dessas tabelas (se houver alguma liberando acesso público)
do $$
declare r record;
begin
  for r in
    select policyname, tablename from pg_policies
    where schemaname = 'public' and tablename in ('crm_sessions', 'auditoria_log')
  loop
    execute format('drop policy %I on public.%I', r.policyname, r.tablename);
  end loop;
end $$;

-- 3) Liga o RLS
alter table public.crm_sessions  enable row level security;
alter table public.auditoria_log enable row level security;

-- 4) Libera só para a equipe logada
create policy equipe_crm_acesso on public.crm_sessions
  for all to authenticated
  using (public.is_equipe_crm())
  with check (public.is_equipe_crm());

create policy equipe_auditoria_ler on public.auditoria_log
  for select to authenticated
  using (public.is_equipe_crm());

create policy equipe_auditoria_registrar on public.auditoria_log
  for insert to authenticated
  with check (public.is_equipe_crm());

-- 5) Conferência: deve listar as 3 políticas acima e rls_ligado = true nas duas tabelas
select c.relname as tabela, c.relrowsecurity as rls_ligado, p.policyname
from pg_class c
left join pg_policies p on p.tablename = c.relname and p.schemaname = 'public'
where c.relname in ('crm_sessions', 'auditoria_log');
