-- ============================================================
-- CRM Bulhões — Lembretes de consulta pelo Clinicorp (22/10/2026)
--
-- Como no Cloudia: o motor (whatsapp-automacoes, a cada minuto) lê a agenda
-- do Clinicorp e manda um modelo aprovado do WhatsApp:
--   • Véspera, às 10h30: consultas do dia seguinte. Sábado manda as de
--     segunda (e as de domingo, se houver). Domingo não manda véspera.
--   • No dia, às 8h30: consultas do próprio dia que ainda não começaram.
-- Um lembrete por telefone, por dia de consulta e por tipo (nunca repete).
-- Só consultas cuja categoria no Clinicorp contém "avaliação" (editável na tela).
-- Desmarcados e excluídos no Clinicorp ficam de fora.
-- A gestão liga, escolhe os modelos e os telefones de teste na tela
-- Automações. Credenciais do Clinicorp: segredos CLINICORP_USUARIO e
-- CLINICORP_TOKEN (e CLINICORP_SUBSCRIBER_ID, se a conta for de grupo).
-- Rodar no Supabase: SQL Editor → New query → colar tudo → Run.
-- ============================================================

insert into public.configuracoes (chave, valor, atualizado_por)
values ('lembretes_consulta', jsonb_build_object(
  'ligado', false, 'modo_teste', true, 'telefones_teste', '[]'::jsonb, 'categorias', 'avaliação',
  'vespera', jsonb_build_object('hora', '10:30', 'modelo', null),
  'dia', jsonb_build_object('hora', '08:30', 'modelo', null)), 'migracao')
on conflict (chave) do nothing;

create table if not exists public.lembretes_consulta (
  id             bigint generated always as identity primary key,
  data           date not null,                       -- dia da consulta
  tipo           text not null check (tipo in ('vespera', 'dia')),
  telefone       text not null,
  nome           text,
  hora           text,
  clinicorp_id   text,
  status         text not null default 'enviando' check (status in ('enviando', 'enviado', 'falhou')),
  erro           text,
  wa_message_id  text,
  conversa_id    uuid references public.conversas(id) on delete set null,
  criado_em      timestamptz not null default now(),
  enviado_em     timestamptz,
  unique (data, tipo, telefone)
);
create index if not exists lembretes_consulta_recentes on public.lembretes_consulta (criado_em desc);

-- uma linha por rodada (dia × tipo), para a tela mostrar e o motor não repetir
create table if not exists public.lembretes_rodadas (
  dia            date not null,
  tipo           text not null check (tipo in ('vespera', 'dia')),
  status         text not null check (status in ('rodando', 'concluida', 'erro')),
  consultas      integer not null default 0,
  enviados       integer not null default 0,
  falhas         integer not null default 0,
  erro           text,
  atualizada_em  timestamptz not null default now(),
  primary key (dia, tipo)
);

alter table public.lembretes_consulta enable row level security;
alter table public.lembretes_rodadas enable row level security;
revoke all on public.lembretes_consulta, public.lembretes_rodadas from anon, authenticated;
grant select on public.lembretes_consulta, public.lembretes_rodadas to authenticated;
drop policy if exists lembretes_ver on public.lembretes_consulta;
create policy lembretes_ver on public.lembretes_consulta for select to authenticated
  using (public.tem_papel('gestao', 'avaliacao', 'comercial'));
drop policy if exists lembretes_rodadas_ver on public.lembretes_rodadas;
create policy lembretes_rodadas_ver on public.lembretes_rodadas for select to authenticated
  using (public.tem_papel('gestao', 'avaliacao', 'comercial'));

-- reserva o envio (só um por telefone/dia/tipo). Devolve {id, telefone} ou null se já foi.
create or replace function public.lembrete_reservar(p_data date, p_tipo text, p_tel text, p_nome text, p_hora text, p_cid text)
returns jsonb
language plpgsql security definer set search_path = public, migracao, pg_temp as $$
declare v_tel text := migracao.tel(p_tel); v_id bigint;
begin
  if v_tel is null or v_tel !~ '^[0-9]{10,11}$' then return null; end if;
  insert into public.lembretes_consulta (data, tipo, telefone, nome, hora, clinicorp_id)
  values (p_data, p_tipo, v_tel, nullif(btrim(p_nome), ''), p_hora, p_cid)
  on conflict (data, tipo, telefone) do nothing
  returning id into v_id;
  if v_id is null then return null; end if;
  return jsonb_build_object('id', v_id, 'telefone', v_tel);
end $$;

create or replace function public.lembrete_marcar(p_id bigint, p_status text, p_erro text, p_wa text, p_conversa uuid)
returns void
language sql security definer set search_path = public, pg_temp as $$
  update public.lembretes_consulta
     set status = p_status, erro = p_erro, wa_message_id = p_wa, conversa_id = coalesce(p_conversa, conversa_id),
         enviado_em = case when p_status = 'enviado' then now() else enviado_em end
   where id = p_id;
$$;

create or replace function public.lembrete_rodada(p_dia date, p_tipo text, p_status text, p_consultas integer, p_enviados integer, p_falhas integer, p_erro text)
returns void
language sql security definer set search_path = public, pg_temp as $$
  insert into public.lembretes_rodadas (dia, tipo, status, consultas, enviados, falhas, erro, atualizada_em)
  values (p_dia, p_tipo, p_status, coalesce(p_consultas, 0), coalesce(p_enviados, 0), coalesce(p_falhas, 0), p_erro, now())
  on conflict (dia, tipo) do update set status = excluded.status,
    consultas = excluded.consultas, enviados = lembretes_rodadas.enviados + excluded.enviados,
    falhas = lembretes_rodadas.falhas + excluded.falhas, erro = excluded.erro, atualizada_em = now();
$$;

-- se o motor caiu no meio do envio, não reenvia (poderia duplicar): vira falha para a equipe ver
create or replace function public.lembretes_limpar_presos()
returns integer
language sql security definer set search_path = public, pg_temp as $$
  with x as (
    update public.lembretes_consulta set status = 'falhou', erro = 'envio interrompido: confira na conversa se chegou'
     where status = 'enviando' and criado_em < now() - interval '10 minutes' returning 1)
  select count(*)::integer from x;
$$;

revoke all on function public.lembrete_reservar(date, text, text, text, text, text) from public, anon, authenticated;
revoke all on function public.lembrete_marcar(bigint, text, text, text, uuid) from public, anon, authenticated;
revoke all on function public.lembrete_rodada(date, text, text, integer, integer, integer, text) from public, anon, authenticated;
revoke all on function public.lembretes_limpar_presos() from public, anon, authenticated;
grant execute on function public.lembrete_reservar(date, text, text, text, text, text) to service_role;
grant execute on function public.lembrete_marcar(bigint, text, text, text, uuid) to service_role;
grant execute on function public.lembrete_rodada(date, text, text, integer, integer, integer, text) to service_role;
grant execute on function public.lembretes_limpar_presos() to service_role;

select 'lembretes de consulta prontos (desligados até a gestão ligar)' as status;
