-- ============================================================
-- CRM Bulhões — Kanban de Leads: "Em atendimento" só quando a SDR manda
-- mensagem (25/10/2026)
-- Para cada telefone, a PRIMEIRA mensagem enviada por uma pessoa da equipe
-- (autor com e-mail; não conta sequência, disparo nem lembrete) depois de um
-- horário (a entrada como lead).
-- Rodar no Supabase: SQL Editor → New query → colar tudo → Run.
-- ============================================================

create or replace function public.kanban_primeiros_envios(p_itens jsonb)
returns table (telefone text, primeiro_envio timestamptz)
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
     where (c.telefone = i.tel or c.telefone = '55' || i.tel)
       and m.direcao = 'enviada' and m.enviada_em >= i.desde
       and m.status <> 'falhou'
       and coalesce(m.autor_email, '') like '%@%'
  )
  from itens i
  where public.tem_papel('gestao', 'avaliacao', 'comercial');
$$;
revoke all on function public.kanban_primeiros_envios(jsonb) from public, anon;
grant execute on function public.kanban_primeiros_envios(jsonb) to authenticated;

select 'kanban: envio da SDR pronto' as status;
