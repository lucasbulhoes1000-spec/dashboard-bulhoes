-- 058: senhas das áreas restritas saem do código e passam a ser conferidas no servidor (31/10/2026)
-- Antes: Gerenciar, Orçamentos Fechados e as edições manuais usavam uma senha escrita no código,
-- e Comissões outra, visíveis para quem abrisse o código do site.
-- Agora: a senha fica só no banco, cifrada (bcrypt). A gestão define a senha nova na primeira vez
-- que abrir a área (as antigas deixam de valer). Depois de 8 erros em 15 minutos, a pessoa espera.
--   'restrita'  → Gerenciar, Orçamentos Fechados e edições manuais do Dashboard
--   'comissoes' → Comissões

create extension if not exists pgcrypto with schema extensions;

create table if not exists public.areas_senha (
  area           text primary key check (area in ('restrita', 'comissoes')),
  hash           text not null,
  atualizado_em  timestamptz not null default now(),
  atualizado_por text default public.email_atual()
);
alter table public.areas_senha enable row level security;
revoke all on public.areas_senha from anon, authenticated;

create table if not exists public.areas_tentativas (
  id     bigint generated always as identity primary key,
  email  text,
  area   text,
  ok     boolean not null,
  quando timestamptz not null default now()
);
create index if not exists areas_tentativas_email on public.areas_tentativas (email, quando);
alter table public.areas_tentativas enable row level security;
revoke all on public.areas_tentativas from anon, authenticated;

-- a área já tem senha?
create or replace function public.area_tem_senha(p_area text) returns boolean
language sql stable security definer set search_path = public, extensions, pg_temp as $$
  select public.is_equipe_crm() and exists (select 1 from public.areas_senha where area = p_area);
$$;

-- confere a senha: 'ok' | 'errada' | 'sem_senha' | 'bloqueado'
create or replace function public.area_conferir(p_area text, p_senha text) returns text
language plpgsql volatile security definer set search_path = public, extensions, pg_temp as $$
declare v_hash text; v_email text := coalesce(public.email_atual(), '?'); v_ok boolean;
begin
  if not public.is_equipe_crm() then return 'errada'; end if;
  if (select count(*) from public.areas_tentativas
       where email = v_email and not ok and quando > now() - interval '15 minutes') >= 8 then
    return 'bloqueado';
  end if;
  select hash into v_hash from public.areas_senha where area = p_area;
  if v_hash is null then return 'sem_senha'; end if;
  v_ok := v_hash = extensions.crypt(coalesce(p_senha, ''), v_hash);
  insert into public.areas_tentativas (email, area, ok) values (v_email, p_area, v_ok);
  return case when v_ok then 'ok' else 'errada' end;
end $$;

-- a gestão define ou troca a senha de uma área
create or replace function public.area_definir_senha(p_area text, p_nova text) returns void
language plpgsql volatile security definer set search_path = public, extensions, pg_temp as $$
begin
  if not public.tem_papel('gestao') then raise exception 'só a gestão define a senha das áreas'; end if;
  if p_area not in ('restrita', 'comissoes') then raise exception 'área desconhecida'; end if;
  if length(coalesce(p_nova, '')) < 4 then raise exception 'a senha precisa ter pelo menos 4 caracteres'; end if;
  insert into public.areas_senha (area, hash) values (p_area, extensions.crypt(p_nova, extensions.gen_salt('bf', 10)))
  on conflict (area) do update set hash = excluded.hash, atualizado_em = now(), atualizado_por = public.email_atual();
end $$;

revoke all on function public.area_tem_senha(text) from public, anon;
revoke all on function public.area_conferir(text, text) from public, anon;
revoke all on function public.area_definir_senha(text, text) from public, anon;
grant execute on function public.area_tem_senha(text) to authenticated;
grant execute on function public.area_conferir(text, text) to authenticated;
grant execute on function public.area_definir_senha(text, text) to authenticated;

select 'senhas das áreas no servidor' as status;
