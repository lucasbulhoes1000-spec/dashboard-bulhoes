-- ============================================================
-- CRM Bulhões — Métricas do Agente de IA (28/10/2026)
-- metricas_ia(p_dias): conversas atendidas pela IA (desde 27/10 17h30, quando ligou para todos),
-- quanto os leads respondem, quantos agendam (pela IA e no total), passagens para a equipe,
-- perdidos (fora da Baixada), respostas automáticas ignoradas, tempo da 1ª resposta e consumo.
-- ============================================================
create or replace function public.metricas_ia(p_dias integer default 7)
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare r jsonb; v_desde timestamptz;
begin
  if not public.tem_papel('gestao', 'avaliacao', 'comercial') then raise exception 'sem permissão'; end if;
  v_desde := greatest(now() - make_interval(days => greatest(1, least(p_dias, 365))), timestamptz '2026-10-27 20:30+00');
  with ini as (   -- primeira mensagem da IA em cada conversa (no período)
    select m.conversa_id, min(m.enviada_em) as ini, count(*) as msgs_ia
      from public.mensagens m
     where m.autor_email ilike 'IA:%' and m.enviada_em >= v_desde and m.conversa_id is not null
     group by 1
  ), reg as (
    select r.conversa_id,
           bool_or(r.tipo = 'agendamento') as agendou_ia,
           bool_or(r.tipo = 'agendamento' and r.detalhe ilike '%ONLINE%') as online,
           bool_or(r.tipo = 'perdido') as perdido,
           bool_or(r.tipo = 'transferencia' and r.detalhe ilike 'Resposta automática%') as robo,
           bool_or(r.tipo = 'transferencia' and r.detalhe not ilike 'Resposta automática%') as transferiu,
           bool_or(r.tipo = 'erro') as erro,
           sum(coalesce(r.tokens_entrada, 0)) as tok_in, sum(coalesce(r.tokens_saida, 0)) as tok_out
      from public.agente_registros r where r.criado_em >= v_desde group by 1
  ), base as (
    select i.*, c.telefone,
           coalesce(g.agendou_ia, false) as agendou_ia, coalesce(g.online, false) as online, coalesce(g.perdido, false) as perdido,
           coalesce(g.robo, false) as robo, coalesce(g.transferiu, false) as transferiu, coalesce(g.erro, false) as erro,
           coalesce(g.tok_in, 0) as tok_in, coalesce(g.tok_out, 0) as tok_out,
           exists (select 1 from public.eventos_proprios e where e.conversa_id = i.conversa_id and e.tipo = 'CUSTOMER_CREATED'
                    and e.ocorrido_em between i.ini - interval '1 day' and i.ini + interval '1 hour') as lead_novo,
           exists (select 1 from public.mensagens m where m.conversa_id = i.conversa_id and m.direcao = 'recebida'
                    and coalesce(m.tipo, '') <> 'reaction' and m.enviada_em > i.ini) as respondeu,
           (select count(*) from public.mensagens m where m.conversa_id = i.conversa_id and m.direcao = 'recebida'
                    and coalesce(m.tipo, '') <> 'reaction' and m.enviada_em > i.ini) as msgs_lead,
           exists (select 1 from public.pacientes p where p.telefone = c.telefone
                    and lower(coalesce(p.etapa, '')) in ('agendou', 'compareceu', 'ganho', 'faltou/desmarcou', 'paciente')) as agendou_total,
           exists (select 1 from public.pacientes p where p.telefone = c.telefone
                    and lower(coalesce(p.etapa, '')) in ('compareceu', 'ganho', 'paciente')) as compareceu,
           exists (select 1 from public.mensagens m where m.conversa_id = i.conversa_id and m.direcao = 'enviada'
                    and m.autor_email like '%@%' and m.enviada_em > i.ini) as equipe_entrou,
           (select extract(epoch from (i.ini - max(m.enviada_em))) / 60.0 from public.mensagens m
             where m.conversa_id = i.conversa_id and m.direcao = 'recebida' and m.enviada_em <= i.ini
               and m.enviada_em > i.ini - interval '1 day') as min_1a,
           (i.ini at time zone 'America/Sao_Paulo')::date as dia,
           extract(hour from (i.ini at time zone 'America/Sao_Paulo')) as hora
      from ini i
      join public.conversas c on c.id = i.conversa_id
      left join reg g on g.conversa_id = i.conversa_id
  ), b as (select * from base where not robo)   -- tira as respostas automáticas de outras empresas
  select jsonb_build_object(
    'desde', v_desde,
    'conversas', (select count(*) from b),
    'leads_novos', (select count(*) from b where lead_novo),
    'robos_ignorados', (select count(*) from base where robo),
    'responderam', (select count(*) from b where respondeu),
    'agendou_ia', (select count(*) from b where agendou_ia),
    'agendou_online', (select count(*) from b where online),
    'agendou_total', (select count(*) from b where agendou_total),
    'compareceu', (select count(*) from b where compareceu),
    'transferiu', (select count(*) from b where transferiu),
    'perdido', (select count(*) from b where perdido),
    'erros', (select count(*) from b where erro),
    'equipe_entrou', (select count(*) from b where equipe_entrou),
    'mediana_1a_min', (select round(percentile_cont(0.5) within group (order by min_1a)::numeric, 1) from b where min_1a is not null),
    'msgs_ia_media', (select round(avg(msgs_ia)::numeric, 1) from b),
    'msgs_ate_agendar', (select round(avg(msgs_ia + msgs_lead)::numeric, 1) from b where agendou_ia),
    'tokens_entrada', (select sum(tok_in) from base), 'tokens_saida', (select sum(tok_out) from base),
    'fora_do_horario', (select count(*) from b where extract(isodow from dia) = 7 or hora < 9 or hora >= 18),
    'fora_do_horario_agendou', (select count(*) from b where (extract(isodow from dia) = 7 or hora < 9 or hora >= 18) and agendou_total),
    'por_dia', (select coalesce(jsonb_agg(d order by d->>'dia' desc), '[]') from (
        select jsonb_build_object('dia', dia, 'conversas', count(*), 'leads_novos', count(*) filter (where lead_novo),
          'responderam', count(*) filter (where respondeu), 'agendou_ia', count(*) filter (where agendou_ia),
          'agendou_total', count(*) filter (where agendou_total), 'transferiu', count(*) filter (where transferiu)) d
        from b group by dia) x),
    'motivos', (select coalesce(jsonb_agg(left(r.detalhe, 160) order by r.criado_em desc), '[]') from (
        select * from public.agente_registros r where r.tipo = 'transferencia' and r.criado_em >= v_desde
           and r.detalhe not ilike 'Resposta automática%' order by r.criado_em desc limit 15) r)
  ) into r;
  return r;
end $$;
revoke all on function public.metricas_ia(integer) from public, anon;
grant execute on function public.metricas_ia(integer) to authenticated;
select to_regprocedure('public.metricas_ia(integer)') is not null as ok;
