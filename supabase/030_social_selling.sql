-- ============================================================
-- CRM Bulhões — Social Selling dentro do CRM (24/10/2026)
-- Substitui a planilha externa do social selling. Uma linha por pessoa
-- abordada no Instagram. A Lívia registra a abordagem, se respondeu e, quando
-- agenda pelo direct, o telefone e a data da avaliação. Comparecimento e venda
-- o CRM busca sozinho no Clinicorp pelo telefone.
-- Rodar no Supabase: SQL Editor → New query → colar tudo → Run.
-- ============================================================

create table if not exists public.social_selling (
  id             bigint generated always as identity primary key,
  instagram      text not null unique check (length(btrim(instagram)) between 1 and 60), -- usuário, sem @, minúsculo
  perfil         text,                -- de qual Instagram abordou: Dra. Larissa ou Clínica
  tipo           text,                -- Seguidor, Curtida, Comentário, Enquete/Reação, Stories, Reativação
  abordado_em    date not null default ((now() at time zone 'America/Sao_Paulo')::date),
  tentativas     integer not null default 1 check (tentativas between 0 and 50),
  respondeu      boolean not null default false,
  respondeu_em   date,
  status         text not null default 'em_andamento'
                 check (status in ('em_andamento', 'agendou', 'desqualificado')),
  nome           text,
  telefone       text,                -- só números, com DDD
  agendado_para  date,                -- data da avaliação marcada pelo direct
  obs            text,
  criado_em      timestamptz not null default now(),
  criado_por     text default public.email_atual(),
  atualizado_em  timestamptz not null default now(),
  atualizado_por text default public.email_atual()
);
create index if not exists social_selling_data on public.social_selling (abordado_em);
create index if not exists social_selling_tel on public.social_selling (telefone);

create or replace function public.social_selling_tocar()
returns trigger language plpgsql as $$
begin
  new.atualizado_em := now();
  new.atualizado_por := coalesce(public.email_atual(), new.atualizado_por);
  new.instagram := lower(btrim(new.instagram));
  new.telefone := nullif(regexp_replace(coalesce(new.telefone, ''), '\D', '', 'g'), '');
  if new.respondeu and new.respondeu_em is null then new.respondeu_em := (now() at time zone 'America/Sao_Paulo')::date; end if;
  if not new.respondeu then new.respondeu_em := null; end if;
  return new;
end $$;
drop trigger if exists t_social_selling_tocar on public.social_selling;
create trigger t_social_selling_tocar before insert or update on public.social_selling
  for each row execute function public.social_selling_tocar();

alter table public.social_selling enable row level security;
drop policy if exists social_selling_ver on public.social_selling;
drop policy if exists social_selling_criar on public.social_selling;
drop policy if exists social_selling_editar on public.social_selling;
drop policy if exists social_selling_apagar on public.social_selling;
create policy social_selling_ver on public.social_selling for select to authenticated
  using ((select public.is_equipe_crm()));
create policy social_selling_criar on public.social_selling for insert to authenticated
  with check ((select public.is_equipe_crm()));
create policy social_selling_editar on public.social_selling for update to authenticated
  using ((select public.is_equipe_crm())) with check ((select public.is_equipe_crm()));
create policy social_selling_apagar on public.social_selling for delete to authenticated
  using ((select public.is_equipe_crm()));

revoke all on public.social_selling from anon;
grant select, insert, update, delete on public.social_selling to authenticated;

select 'social selling pronto' as status;
