-- ============================================================
-- CRM Bulhões — Mensagens agendadas (22/10/2026)
-- Como no Cloudia: na conversa, a equipe agenda um texto ou um modelo
-- aprovado para sair numa data e hora. O motor (whatsapp-automacoes, a cada
-- minuto) envia na hora certa. Texto livre só sai se a janela de 24 h estiver
-- aberta na hora do envio; modelo sai a qualquer hora.
-- Não depende da chave geral das automações (é decisão da equipe).
-- Rodar no Supabase: SQL Editor → New query → colar tudo → Run.
-- ============================================================
create table if not exists public.mensagens_agendadas (
  id             bigint generated always as identity primary key,
  conversa_id    uuid not null references public.conversas(id) on delete cascade,
  tipo           text not null check (tipo in ('texto', 'modelo')),
  texto          text check (texto is null or length(texto) between 1 and 4096),
  modelo         jsonb,
  enviar_em      timestamptz not null,
  status         text not null default 'agendada' check (status in ('agendada', 'enviando', 'enviada', 'falhou', 'cancelada')),
  erro           text,
  wa_message_id  text,
  criada_em      timestamptz not null default now(),
  criada_por     text default public.email_atual(),
  enviada_em     timestamptz,
  check (tipo <> 'texto' or texto is not null),
  check (tipo <> 'modelo' or coalesce(length(modelo->>'nome') > 0, false))
);
create index if not exists mensagens_agendadas_fila on public.mensagens_agendadas (enviar_em) where status = 'agendada';
create index if not exists mensagens_agendadas_conversa on public.mensagens_agendadas (conversa_id, enviar_em);

alter table public.mensagens_agendadas enable row level security;
revoke all on public.mensagens_agendadas from anon, authenticated;
grant select, insert on public.mensagens_agendadas to authenticated;
grant update (status) on public.mensagens_agendadas to authenticated;

drop policy if exists agendadas_ver on public.mensagens_agendadas;
create policy agendadas_ver on public.mensagens_agendadas for select to authenticated
  using (public.tem_papel('gestao', 'avaliacao', 'comercial'));
drop policy if exists agendadas_criar on public.mensagens_agendadas;
create policy agendadas_criar on public.mensagens_agendadas for insert to authenticated
  with check (public.tem_papel('gestao', 'avaliacao', 'comercial') and status = 'agendada'
              and enviar_em > now() - interval '2 minutes' and criada_por = public.email_atual());
-- a equipe só cancela o que ainda não saiu
drop policy if exists agendadas_cancelar on public.mensagens_agendadas;
create policy agendadas_cancelar on public.mensagens_agendadas for update to authenticated
  using (public.tem_papel('gestao', 'avaliacao', 'comercial') and status = 'agendada')
  with check (status = 'cancelada');

-- motor: pega as vencidas (no máximo 40 por minuto) e marca "enviando"
create or replace function public.agendadas_pegar()
returns setof public.mensagens_agendadas
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  -- se o motor caiu no meio do envio, não tenta de novo (poderia duplicar): marca como falha para a equipe ver
  update public.mensagens_agendadas set status = 'falhou', erro = 'envio interrompido: confira na conversa se chegou'
   where status = 'enviando' and enviar_em < now() - interval '10 minutes';
  return query
  update public.mensagens_agendadas x set status = 'enviando'
   where x.id in (select y.id from public.mensagens_agendadas y
                   where y.status = 'agendada' and y.enviar_em <= now()
                   order by y.enviar_em limit 40 for update skip locked)
  returning x.*;
end $$;

create or replace function public.agendadas_marcar(p_id bigint, p_status text, p_erro text, p_wa text)
returns void
language sql security definer set search_path = public, pg_temp as $$
  update public.mensagens_agendadas
     set status = p_status, erro = p_erro, wa_message_id = p_wa,
         enviada_em = case when p_status = 'enviada' then now() else enviada_em end
   where id = p_id and status = 'enviando';
$$;

revoke all on function public.agendadas_pegar() from public, anon, authenticated;
revoke all on function public.agendadas_marcar(bigint, text, text, text) from public, anon, authenticated;
grant execute on function public.agendadas_pegar() to service_role;
grant execute on function public.agendadas_marcar(bigint, text, text, text) to service_role;

do $$ begin
  alter publication supabase_realtime add table public.mensagens_agendadas;
exception when duplicate_object then null; when undefined_object then null; end $$;

select 'mensagens agendadas prontas' as status;
