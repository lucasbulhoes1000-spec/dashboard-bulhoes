-- ============================================================
-- CRM Bulhões — Kanban por etapa do processo comercial (24/10/2026)
-- Uma consulta só de leitura para o Kanban de Leads:
--   para cada telefone, a PRIMEIRA mensagem que o paciente mandou depois de
--   um horário (a entrada como lead). Com isso o Kanban sabe se o lead já
--   respondeu (sai das cadências) e mede a taxa de resposta de cada cadência.
-- Também devolve desde quando o CRM grava mensagens (antes disso não há
-- como saber se respondeu, então essas pessoas ficam fora da taxa).
-- Rodar no Supabase: SQL Editor → New query → colar tudo → Run.
-- ============================================================

create or replace function public.kanban_primeiras_respostas(p_itens jsonb)
returns table (telefone text, primeira_resposta timestamptz)
language sql stable security definer set search_path = public, pg_temp as $$
  with itens as (
    select distinct on (x->>'t') x->>'t' as tel, (x->>'d')::timestamptz as desde
      from jsonb_array_elements(coalesce(p_itens, '[]'::jsonb)) x
     where coalesce(x->>'t', '') ~ '^[0-9]{10,11}$' and x->>'d' is not null
  )
  select i.tel, (
    select min(m.enviada_em)
      from public.conversas c
      join public.mensagens m on m.conversa_id = c.id
     where c.telefone = i.tel and m.direcao = 'recebida' and m.enviada_em >= i.desde
  )
  from itens i
  where public.tem_papel('gestao', 'avaliacao', 'comercial');
$$;

create or replace function public.kanban_mensagens_desde()
returns timestamptz
language sql stable security definer set search_path = public, pg_temp as $$
  -- início do espelho ao vivo (primeiro evento do webhook); ignora mensagens
  -- antigas soltas que vieram junto com algum histórico
  select coalesce(
    (select min(m.enviada_em) from public.mensagens m
      where m.enviada_em >= (select min(recebido) - interval '1 day' from public.whatsapp_eventos_brutos)),
    (select min(enviada_em) from public.mensagens))
  where public.tem_papel('gestao', 'avaliacao', 'comercial');
$$;

revoke all on function public.kanban_primeiras_respostas(jsonb) from public, anon;
revoke all on function public.kanban_mensagens_desde() from public, anon;
grant execute on function public.kanban_primeiras_respostas(jsonb) to authenticated;
grant execute on function public.kanban_mensagens_desde() to authenticated;

select 'kanban pronto' as status;
