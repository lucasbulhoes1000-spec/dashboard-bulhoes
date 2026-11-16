-- ============================================================
-- 200 (16/11/2026) INSTITUTO: espaço separado dentro da Lume
--   Pedido do Lucas: seletor Clínica | Instituto, Central do Instituto
--   e o funil (kanban) do processo comercial do Instituto.
--
--   1. equipe.espacos: em quais espaços cada pessoa entra.
--      Padrão = só a clínica. Lucas e Dra. Larissa = os dois.
--   2. whatsapp_numeros.espaco: de qual espaço é cada número.
--      O (13) 4042-7082 (431996333326052) é do Instituto.
--   3. Trava no banco (políticas RESTRICTIVE, que só somam restrição):
--      quem não tem o espaço do número não vê a conversa, as mensagens
--      nem o número. As políticas que já existem NÃO mudam: para a equipe
--      da clínica, a única diferença é não ver mais o número do Instituto.
--   4. Funil do Instituto: instituto_leads (cards) e instituto_eventos
--      (histórico de etapa, para medir conversão por canal).
--
-- Não mexe em: webhook, edge functions, Ale, IA, automações, pacientes,
-- leads da clínica, métricas da clínica.
-- Rodar no Supabase: SQL Editor → New query → colar tudo → Run.
-- Pode rodar mais de uma vez sem problema.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Espaços de cada pessoa
-- ------------------------------------------------------------
alter table public.equipe add column if not exists espacos text[] not null default '{clinica}';
do $$ begin
  alter table public.equipe add constraint equipe_espacos_ck
    check (espacos <@ array['clinica', 'instituto'] and cardinality(espacos) > 0);
exception when duplicate_object then null; end $$;

update public.equipe set espacos = array['clinica', 'instituto']
 where email in ('lucasbulhoes1000@gmail.com', 'larissa@bulhoesodontologia.com.br')
   and not ('instituto' = any (espacos));

-- espaços de quem está logado (vazio = não é da equipe ou está inativo)
create or replace function public.meus_espacos()
returns text[]
language sql stable security definer set search_path = ''
as $$
  select coalesce((select e.espacos from public.equipe e
                    where e.email = lower(coalesce(auth.jwt() ->> 'email', '')) and e.ativo), '{}'::text[]);
$$;

create or replace function public.tem_espaco(p_espaco text)
returns boolean
language sql stable security definer set search_path = ''
as $$ select p_espaco = any (public.meus_espacos()); $$;

-- ------------------------------------------------------------
-- 2. Espaço de cada número
-- ------------------------------------------------------------
alter table public.whatsapp_numeros add column if not exists espaco text not null default 'clinica';
do $$ begin
  alter table public.whatsapp_numeros add constraint whatsapp_numeros_espaco_ck check (espaco in ('clinica', 'instituto'));
exception when duplicate_object then null; end $$;
grant select (espaco) on public.whatsapp_numeros to authenticated;

update public.whatsapp_numeros set espaco = 'instituto'
 where phone_number_id = '431996333326052' and espaco <> 'instituto';

-- números que a pessoa logada NÃO pode ver (de espaços que não são dela)
create or replace function public.numeros_fora_do_meu_espaco()
returns text[]
language sql stable security definer set search_path = ''
as $$
  select coalesce(array_agg(n.phone_number_id), '{}'::text[])
    from public.whatsapp_numeros n
   where not (n.espaco = any (public.meus_espacos()));
$$;

-- conversas desses números (para travar as mensagens sem consultar conversa por conversa)
create or replace function public.conversas_fora_do_meu_espaco()
returns uuid[]
language sql stable security definer set search_path = ''
as $$
  select coalesce(array_agg(c.id), '{}'::uuid[])
    from public.conversas c
   where c.numero_clinica_id = any (public.numeros_fora_do_meu_espaco());
$$;

-- ------------------------------------------------------------
-- 3. Trava por espaço (RESTRICTIVE: soma com as políticas atuais)
-- ------------------------------------------------------------
drop policy if exists espaco_conversas on public.conversas;
create policy espaco_conversas on public.conversas as restrictive for all to authenticated
  using (numero_clinica_id <> all ((select public.numeros_fora_do_meu_espaco())::text[]))
  with check (numero_clinica_id <> all ((select public.numeros_fora_do_meu_espaco())::text[]));

drop policy if exists espaco_mensagens on public.mensagens;
create policy espaco_mensagens on public.mensagens as restrictive for all to authenticated
  using (conversa_id <> all ((select public.conversas_fora_do_meu_espaco())::uuid[]))
  with check (conversa_id <> all ((select public.conversas_fora_do_meu_espaco())::uuid[]));

drop policy if exists espaco_whatsapp_numeros on public.whatsapp_numeros;
create policy espaco_whatsapp_numeros on public.whatsapp_numeros as restrictive for all to authenticated
  using (espaco = any ((select public.meus_espacos())::text[]))
  with check (espaco = any ((select public.meus_espacos())::text[]));

-- ------------------------------------------------------------
-- 4. Funil do Instituto
-- ------------------------------------------------------------
create table if not exists public.instituto_leads (
  id              bigint generated always as identity primary key,
  nome            text check (length(nome) <= 200),
  telefone        text check (telefone ~ '^[0-9]{10,13}$'),
  instagram       text check (length(instagram) <= 100),
  email           text check (length(email) <= 200),
  origem          text check (origem in ('aplicacao', 'social_selling', 'organico', 'outro')),
  etapa           text not null default 'lead' check (etapa in
                    ('lead', 'aplicacao', 'qualificado', 'call_agendada', 'call_realizada', 'proposta', 'venda', 'perdido')),
  etapa_em        timestamptz not null default now(),
  motivo_perda    text check (length(motivo_perda) <= 500),
  sdr_email       text references public.equipe(email) on delete set null,
  closer_email    text references public.equipe(email) on delete set null,
  call_em         timestamptz,
  valor_proposta  numeric(12,2) check (valor_proposta >= 0),
  valor_venda     numeric(12,2) check (valor_venda >= 0),
  plataforma      text check (plataforma in ('eduzz', 'hotmart', 'outra')),
  conversa_id     uuid references public.conversas(id) on delete set null,
  obs             text check (length(obs) <= 16000),
  criado_em       timestamptz not null default now(),
  criado_por      text,
  atualizado_em   timestamptz not null default now(),
  atualizado_por  text
);
create index if not exists instituto_leads_etapa on public.instituto_leads (etapa);
create index if not exists instituto_leads_telefone on public.instituto_leads (telefone);
create unique index if not exists instituto_leads_conversa on public.instituto_leads (conversa_id) where conversa_id is not null;

create table if not exists public.instituto_eventos (
  id        bigint generated always as identity primary key,
  lead_id   bigint not null references public.instituto_leads(id) on delete cascade,
  de        text,
  para      text not null,
  origem    text,
  por       text,
  em        timestamptz not null default now()
);
create index if not exists instituto_eventos_lead on public.instituto_eventos (lead_id, em);
create index if not exists instituto_eventos_em on public.instituto_eventos (em);

-- quem mexeu, quando, e o histórico de etapa
create or replace function public.instituto_leads_tocar()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  new.atualizado_em := now();
  new.atualizado_por := coalesce(nullif(public.email_atual(), ''), new.atualizado_por);
  new.telefone := nullif(regexp_replace(coalesce(new.telefone, ''), '\D', '', 'g'), '');
  new.instagram := nullif(lower(btrim(replace(coalesce(new.instagram, ''), '@', ''))), '');
  if tg_op = 'INSERT' then
    new.criado_por := coalesce(nullif(public.email_atual(), ''), new.criado_por);
    new.etapa_em := now();
  elsif new.etapa is distinct from old.etapa then
    new.etapa_em := now();
  end if;
  return new;
end $$;

create or replace function public.instituto_leads_historico()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if tg_op = 'INSERT' or new.etapa is distinct from old.etapa then
    insert into public.instituto_eventos (lead_id, de, para, origem, por)
    values (new.id, case when tg_op = 'UPDATE' then old.etapa end, new.etapa, new.origem, new.atualizado_por);
  end if;
  return null;
end $$;

drop trigger if exists instituto_leads_tocar on public.instituto_leads;
create trigger instituto_leads_tocar before insert or update on public.instituto_leads
  for each row execute function public.instituto_leads_tocar();
drop trigger if exists instituto_leads_historico on public.instituto_leads;
create trigger instituto_leads_historico after insert or update on public.instituto_leads
  for each row execute function public.instituto_leads_historico();

-- segurança: só quem tem o espaço Instituto; apagar card só a gestão
alter table public.instituto_leads enable row level security;
alter table public.instituto_eventos enable row level security;
revoke all on public.instituto_leads, public.instituto_eventos from anon;
grant select, insert, update, delete on public.instituto_leads to authenticated;
grant select on public.instituto_eventos to authenticated;

drop policy if exists instituto_leads_ver on public.instituto_leads;
create policy instituto_leads_ver on public.instituto_leads for select to authenticated
  using (public.tem_espaco('instituto'));
drop policy if exists instituto_leads_criar on public.instituto_leads;
create policy instituto_leads_criar on public.instituto_leads for insert to authenticated
  with check (public.tem_espaco('instituto'));
drop policy if exists instituto_leads_editar on public.instituto_leads;
create policy instituto_leads_editar on public.instituto_leads for update to authenticated
  using (public.tem_espaco('instituto')) with check (public.tem_espaco('instituto'));
drop policy if exists instituto_leads_apagar on public.instituto_leads;
create policy instituto_leads_apagar on public.instituto_leads for delete to authenticated
  using (public.tem_espaco('instituto') and public.tem_papel('gestao'));
drop policy if exists instituto_eventos_ver on public.instituto_eventos;
create policy instituto_eventos_ver on public.instituto_eventos for select to authenticated
  using (public.tem_espaco('instituto'));

-- quem do Instituto pode ser SDR, closer ou atendente
create or replace function public.equipe_do_espaco(p_espaco text)
returns table (email text, nome text, papel text)
language sql stable security definer set search_path = public, pg_temp as $$
  select e.email, e.nome, e.papel::text from public.equipe e
   where e.ativo and p_espaco = any (e.espacos) and public.tem_espaco(p_espaco)
   order by e.nome;
$$;
revoke all on function public.equipe_do_espaco(text) from anon;
grant execute on function public.equipe_do_espaco(text) to authenticated;
grant execute on function public.meus_espacos() to authenticated;

do $$ begin
  alter publication supabase_realtime add table public.instituto_leads;
exception when duplicate_object then null; when undefined_object then null; end $$;

-- ------------------------------------------------------------
-- Conferência
-- ------------------------------------------------------------
select 'equipe' as o_que, email as item, array_to_string(espacos, ', ') as valor from public.equipe where ativo
union all
select 'número', coalesce(apelido, numero_exibicao), espaco from public.whatsapp_numeros
union all
select 'política', tablename || '.' || policyname, permissive from pg_policies
 where schemaname = 'public' and policyname like 'espaco_%'
order by 1, 2;
