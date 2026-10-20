-- ============================================================
-- CRM Bulhões — Fase 1, etapa 1: base nova
-- 20/10/2026
--
-- O que este script faz (e o que NÃO faz):
--   1. Cópia de segurança completa da tabela crm_sessions (schema backup).
--   2. Tabela equipe com os papéis de cada pessoa.
--   3. Tabelas novas do CRM, vazias, todas com RLS ligado.
--   NÃO altera nem apaga nada do CRM atual. A equipe não percebe nada.
--
-- Pode ser rodado de novo sem estragar nada (usa "if not exists").
-- Rodar no Supabase: SQL Editor → New query → colar tudo → Run.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Cópia de segurança (fica fora do alcance do site: só o
--    painel da Supabase e a chave de serviço enxergam)
-- ------------------------------------------------------------
create schema if not exists backup;
revoke all on schema backup from anon, authenticated;

create table if not exists backup.crm_sessions_20261020 as
  table public.crm_sessions;
alter table backup.crm_sessions_20261020 enable row level security;
revoke all on backup.crm_sessions_20261020 from anon, authenticated;

-- ------------------------------------------------------------
-- 2. Equipe e papéis
-- ------------------------------------------------------------
do $$ begin
  create type public.papel_equipe as enum ('gestao', 'avaliacao', 'comercial', 'clinica');
exception when duplicate_object then null; end $$;

create table if not exists public.equipe (
  email      text primary key check (email = lower(email)),
  nome       text not null,
  papel      public.papel_equipe not null,
  ativo      boolean not null default true,
  criado_em  timestamptz not null default now()
);

insert into public.equipe (email, nome, papel) values
  ('lucasbulhoes1000@gmail.com',          'Lucas',     'gestao'),
  ('larissa@bulhoesodontologia.com.br',   'Larissa',   'gestao'),
  ('victoria@bulhoesodontologia.com.br',  'Victoria',  'avaliacao'),
  ('raffaella@bulhoesodontologia.com.br', 'Raffaella', 'comercial'),
  ('livia@bulhoesodontologia.com.br',     'Lívia',     'comercial'),
  ('gabi@bulhoesodontologia.com.br',      'Gabi',      'clinica')
on conflict (email) do nothing;

-- Papel de quem está logado (null = não é da equipe ou está inativo)
create or replace function public.papel_atual()
returns public.papel_equipe
language sql stable security definer set search_path = ''
as $$
  select e.papel from public.equipe e
  where e.email = lower(coalesce(auth.jwt() ->> 'email', '')) and e.ativo;
$$;

create or replace function public.email_atual()
returns text
language sql stable
as $$ select lower(coalesce(auth.jwt() ->> 'email', '')); $$;

-- A política que já protege o crm_sessions passa a ler a tabela equipe.
-- Dar ou tirar acesso = mudar uma linha da equipe, sem SQL novo.
create or replace function public.is_equipe_crm()
returns boolean
language sql stable security definer set search_path = ''
as $$ select public.papel_atual() is not null; $$;

create or replace function public.tem_papel(variadic papeis public.papel_equipe[])
returns boolean
language sql stable security definer set search_path = ''
as $$ select public.papel_atual() = any (papeis); $$;

-- Atualiza a coluna atualizado_em sozinha
create or replace function public.tocar_atualizado_em()
returns trigger language plpgsql as $$
begin new.atualizado_em := now(); return new; end $$;

-- ------------------------------------------------------------
-- 3. Tabelas do CRM
--    "legado" guarda campos do CRM antigo que não ganharam coluna,
--    para nada se perder na migração.
-- ------------------------------------------------------------
create table if not exists public.pacientes (
  id                     uuid primary key default gen_random_uuid(),
  telefone               text not null unique check (telefone ~ '^[0-9]{10,13}$'),
  nome                   text,
  origem                 text,
  etapa                  text,
  etapa_alterada_em      timestamptz,
  paciente_antigo        boolean not null default false,
  lead_importado         boolean not null default false,
  editado_manualmente    boolean not null default false,
  clinicorp_paciente_id  text,
  ad_id_manual           text,
  criado_em              timestamptz not null default now(),
  atualizado_em          timestamptz not null default now(),
  legado                 jsonb
);

create table if not exists public.eventos_funil (
  id                   bigint generated always as identity primary key,
  paciente_id          uuid references public.pacientes(id) on delete cascade,
  telefone             text not null,
  tipo                 text not null,           -- CUSTOMER_CREATED, CUSTOMER_STAGE_UPDATED, ...
  etapa                text,
  origem               text,
  ad_id                text,
  ad_name              text,
  adset_name           text,
  campaign_name        text,
  cloudia_customer_id  text,
  valor                numeric(12,2),
  ocorrido_em          timestamptz not null,
  fonte                text not null default 'cloudia',
  recebido_em          timestamptz not null default now(),
  bruto                jsonb
);
create unique index if not exists eventos_funil_sem_duplicata
  on public.eventos_funil (telefone, tipo, coalesce(etapa, ''), ocorrido_em);
create index if not exists eventos_funil_por_paciente on public.eventos_funil (paciente_id, ocorrido_em desc);
create index if not exists eventos_funil_por_data on public.eventos_funil (ocorrido_em desc);

create table if not exists public.agendamentos (
  id             uuid primary key default gen_random_uuid(),
  paciente_id    uuid references public.pacientes(id) on delete cascade,
  clinicorp_id   text unique,
  inicio         timestamptz not null,
  tipo           text,                          -- avaliação, consulta, procedimento
  avaliador      text,
  status         text not null default 'agendado'
                 check (status in ('agendado','confirmado','compareceu','faltou','desmarcou','cancelado')),
  criado_em      timestamptz not null default now(),
  atualizado_em  timestamptz not null default now(),
  bruto          jsonb
);
create index if not exists agendamentos_por_paciente on public.agendamentos (paciente_id, inicio desc);
create index if not exists agendamentos_por_data on public.agendamentos (inicio);

create table if not exists public.orcamentos (
  id                       uuid primary key default gen_random_uuid(),
  paciente_id              uuid not null references public.pacientes(id) on delete cascade,
  data                     date,
  tratamento               text,
  valor                    numeric(12,2),
  entrada                  numeric(12,2),
  entrada_data             date,
  entrada_forma            text,
  pagamento                text,
  parcelas                 integer,
  avaliador                text,
  crc_participou           boolean,
  crc_nome                 text,
  status                   text,
  fechamento_data          date,
  fechamento_valor         numeric(12,2),
  tem_entrada              boolean,
  paciente_antigo          boolean,
  clinicorp_id             text unique,
  clinicorp_tratamento_id  text,
  origem_clinicorp         boolean,
  obs                      text,
  criado_em                timestamptz not null default now(),
  atualizado_em            timestamptz not null default now(),
  legado                   jsonb
);
create index if not exists orcamentos_por_paciente on public.orcamentos (paciente_id);
create index if not exists orcamentos_por_data on public.orcamentos (data desc);

create table if not exists public.atividades (
  id             uuid primary key default gen_random_uuid(),
  paciente_id    uuid not null references public.pacientes(id) on delete cascade,
  fase           text,
  quando         timestamptz,
  probabilidade  text,
  proximo_passo  text,
  obs            text,
  autor_email    text not null default public.email_atual(),
  criado_em      timestamptz not null default now()
);
create index if not exists atividades_por_paciente on public.atividades (paciente_id, quando desc);

create table if not exists public.anotacoes (
  id           uuid primary key default gen_random_uuid(),
  paciente_id  uuid not null references public.pacientes(id) on delete cascade,
  texto        text not null,
  autor_email  text not null default public.email_atual(),
  legado_id    text unique,
  criado_em    timestamptz not null default now()
);
create index if not exists anotacoes_por_paciente on public.anotacoes (paciente_id, criado_em desc);

create table if not exists public.comissoes (
  id                  uuid primary key default gen_random_uuid(),
  data                date,
  paciente_nome       text,
  telefone            text,
  avaliador           text,
  crc                 text,
  valor_tratamento    numeric(12,2),
  entrada             numeric(12,2),
  pagamento           text,
  comissao_avaliador  numeric(12,2),
  comissao_crc        numeric(12,2),
  status              text,
  obs                 text,
  origem              text,
  criado_em           timestamptz not null default now()
);

create table if not exists public.anuncios_dia (
  data           date not null,
  ad_id          text not null,
  ad_name        text,
  adset_name     text,
  campaign_name  text,
  gasto          numeric(12,2),
  impressoes     integer,
  alcance        integer,
  cliques        integer,
  atualizado_em  timestamptz not null default now(),
  primary key (data, ad_id)
);

create table if not exists public.listas (
  tipo   text not null,   -- origens, status, tratamentos, fases, avaliadores
  valor  text not null,
  ordem  integer not null default 0,
  ativo  boolean not null default true,
  primary key (tipo, valor)
);

create table if not exists public.configuracoes (
  chave           text primary key,  -- fluxo_tratamento, calendario_sazonal, ajustes_dashboard, ...
  valor           jsonb not null,
  atualizado_em   timestamptz not null default now(),
  atualizado_por  text default public.email_atual()
);

create table if not exists public.auditoria (
  id           bigint generated always as identity primary key,
  quando       timestamptz not null default now(),
  quem_email   text not null default public.email_atual(),
  acao         text not null,
  detalhe      text,
  tabela       text,
  registro_id  text
);
create index if not exists auditoria_por_data on public.auditoria (quando desc);

-- atualizado_em automático
drop trigger if exists t_pacientes_atualizado on public.pacientes;
create trigger t_pacientes_atualizado before update on public.pacientes
  for each row execute function public.tocar_atualizado_em();
drop trigger if exists t_agendamentos_atualizado on public.agendamentos;
create trigger t_agendamentos_atualizado before update on public.agendamentos
  for each row execute function public.tocar_atualizado_em();
drop trigger if exists t_orcamentos_atualizado on public.orcamentos;
create trigger t_orcamentos_atualizado before update on public.orcamentos
  for each row execute function public.tocar_atualizado_em();
drop trigger if exists t_configuracoes_atualizado on public.configuracoes;
create trigger t_configuracoes_atualizado before update on public.configuracoes
  for each row execute function public.tocar_atualizado_em();

-- ------------------------------------------------------------
-- 4. Segurança: RLS em tudo, permissões por papel
--    Webhooks e rotinas usam a chave de serviço, que não passa
--    por estas regras.
-- ------------------------------------------------------------
alter table public.equipe        enable row level security;
alter table public.pacientes     enable row level security;
alter table public.eventos_funil enable row level security;
alter table public.agendamentos  enable row level security;
alter table public.orcamentos    enable row level security;
alter table public.atividades    enable row level security;
alter table public.anotacoes     enable row level security;
alter table public.comissoes     enable row level security;
alter table public.anuncios_dia  enable row level security;
alter table public.listas        enable row level security;
alter table public.configuracoes enable row level security;
alter table public.auditoria     enable row level security;

revoke all on public.equipe, public.pacientes, public.eventos_funil, public.agendamentos,
  public.orcamentos, public.atividades, public.anotacoes, public.comissoes,
  public.anuncios_dia, public.listas, public.configuracoes, public.auditoria from anon;

-- Remove políticas antigas destas tabelas (para o script poder rodar de novo)
do $$
declare r record;
begin
  for r in
    select policyname, tablename from pg_policies
    where schemaname = 'public' and tablename in
      ('equipe','pacientes','eventos_funil','agendamentos','orcamentos','atividades',
       'anotacoes','comissoes','anuncios_dia','listas','configuracoes','auditoria')
  loop
    execute format('drop policy %I on public.%I', r.policyname, r.tablename);
  end loop;
end $$;

-- equipe: cada um vê a própria linha; gestão vê e altera todas
create policy equipe_ver on public.equipe for select to authenticated
  using (email = public.email_atual() or public.tem_papel('gestao'));
create policy equipe_gestao on public.equipe for all to authenticated
  using (public.tem_papel('gestao')) with check (public.tem_papel('gestao'));

-- pacientes: todos da equipe veem; gestão, avaliação e comercial alteram; só gestão apaga
create policy pacientes_ver on public.pacientes for select to authenticated
  using (public.is_equipe_crm());
create policy pacientes_criar on public.pacientes for insert to authenticated
  with check (public.tem_papel('gestao','avaliacao','comercial'));
create policy pacientes_alterar on public.pacientes for update to authenticated
  using (public.tem_papel('gestao','avaliacao','comercial'))
  with check (public.tem_papel('gestao','avaliacao','comercial'));
create policy pacientes_apagar on public.pacientes for delete to authenticated
  using (public.tem_papel('gestao'));

-- eventos do funil: todos veem; mudança manual de etapa por gestão, avaliação e comercial
create policy eventos_ver on public.eventos_funil for select to authenticated
  using (public.is_equipe_crm());
create policy eventos_criar on public.eventos_funil for insert to authenticated
  with check (public.tem_papel('gestao','avaliacao','comercial'));
create policy eventos_gestao on public.eventos_funil for all to authenticated
  using (public.tem_papel('gestao')) with check (public.tem_papel('gestao'));

-- agendamentos: todos veem; gestão, avaliação e comercial alteram
create policy agendamentos_ver on public.agendamentos for select to authenticated
  using (public.is_equipe_crm());
create policy agendamentos_alterar on public.agendamentos for all to authenticated
  using (public.tem_papel('gestao','avaliacao','comercial'))
  with check (public.tem_papel('gestao','avaliacao','comercial'));

-- orçamentos: todos veem; gestão e avaliação alteram; só gestão apaga
create policy orcamentos_ver on public.orcamentos for select to authenticated
  using (public.is_equipe_crm());
create policy orcamentos_criar on public.orcamentos for insert to authenticated
  with check (public.tem_papel('gestao','avaliacao'));
create policy orcamentos_alterar on public.orcamentos for update to authenticated
  using (public.tem_papel('gestao','avaliacao'))
  with check (public.tem_papel('gestao','avaliacao'));
create policy orcamentos_apagar on public.orcamentos for delete to authenticated
  using (public.tem_papel('gestao'));

-- atividades e anotações: todos veem e criam em nome próprio;
-- cada um altera/apaga as suas, gestão altera/apaga qualquer uma
create policy atividades_ver on public.atividades for select to authenticated
  using (public.is_equipe_crm());
create policy atividades_criar on public.atividades for insert to authenticated
  with check (public.is_equipe_crm() and autor_email = public.email_atual());
create policy atividades_alterar on public.atividades for update to authenticated
  using (autor_email = public.email_atual() or public.tem_papel('gestao'))
  with check (public.is_equipe_crm());
create policy atividades_apagar on public.atividades for delete to authenticated
  using (autor_email = public.email_atual() or public.tem_papel('gestao'));

create policy anotacoes_ver on public.anotacoes for select to authenticated
  using (public.is_equipe_crm());
create policy anotacoes_criar on public.anotacoes for insert to authenticated
  with check (public.is_equipe_crm() and autor_email = public.email_atual());
create policy anotacoes_alterar on public.anotacoes for update to authenticated
  using (autor_email = public.email_atual() or public.tem_papel('gestao'))
  with check (public.is_equipe_crm());
create policy anotacoes_apagar on public.anotacoes for delete to authenticated
  using (autor_email = public.email_atual() or public.tem_papel('gestao'));

-- comissões: só gestão
create policy comissoes_gestao on public.comissoes for all to authenticated
  using (public.tem_papel('gestao')) with check (public.tem_papel('gestao'));

-- anúncios: gestão, avaliação e comercial veem; quem grava é a rotina da Meta
create policy anuncios_ver on public.anuncios_dia for select to authenticated
  using (public.tem_papel('gestao','avaliacao','comercial'));

-- listas: todos veem; gestão altera
create policy listas_ver on public.listas for select to authenticated
  using (public.is_equipe_crm());
create policy listas_gestao on public.listas for all to authenticated
  using (public.tem_papel('gestao')) with check (public.tem_papel('gestao'));

-- configurações: todos veem; gestão altera tudo; clínica altera o fluxo de tratamento
create policy config_ver on public.configuracoes for select to authenticated
  using (public.is_equipe_crm());
create policy config_gestao on public.configuracoes for all to authenticated
  using (public.tem_papel('gestao')) with check (public.tem_papel('gestao'));
create policy config_fluxo_clinica on public.configuracoes for update to authenticated
  using (chave = 'fluxo_tratamento' and public.tem_papel('clinica'))
  with check (chave = 'fluxo_tratamento' and public.tem_papel('clinica'));

-- auditoria: todos registram em nome próprio; só gestão lê
create policy auditoria_registrar on public.auditoria for insert to authenticated
  with check (public.is_equipe_crm() and quem_email = public.email_atual());
create policy auditoria_ver on public.auditoria for select to authenticated
  using (public.tem_papel('gestao'));

-- ------------------------------------------------------------
-- 5. Conferência (resultado aparece embaixo do editor)
-- ------------------------------------------------------------
select 'backup: linhas copiadas' as item,
       (select count(*) from backup.crm_sessions_20261020)::text as valor
union all
select 'backup: linhas no original', (select count(*) from public.crm_sessions)::text
union all
select 'equipe cadastrada', (select count(*) from public.equipe)::text
union all
select 'tabelas novas com RLS ligado',
       (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public' and c.relrowsecurity
          and c.relname in ('equipe','pacientes','eventos_funil','agendamentos','orcamentos',
                            'atividades','anotacoes','comissoes','anuncios_dia','listas',
                            'configuracoes','auditoria'))::text || ' de 12'
union all
select 'políticas criadas',
       (select count(*) from pg_policies where schemaname = 'public' and tablename in
         ('equipe','pacientes','eventos_funil','agendamentos','orcamentos','atividades',
          'anotacoes','comissoes','anuncios_dia','listas','configuracoes','auditoria'))::text;
