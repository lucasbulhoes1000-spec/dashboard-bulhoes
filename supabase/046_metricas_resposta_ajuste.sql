-- 27/10/2026: métrica conta só leads desde 27/10 (CRM completo) e só respostas da equipe, IA, celular e 1ª mensagem automática.
create or replace function public.metricas_primeira_resposta(p_dias integer default 30)
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare r jsonb;
begin
  if not public.tem_papel('gestao', 'avaliacao', 'comercial') then raise exception 'sem permissão'; end if;
  with leads as (
    select e.telefone, e.conversa_id, e.ocorrido_em
      from public.eventos_proprios e
     where e.tipo = 'CUSTOMER_CREATED' and e.conversa_id is not null
       and e.ocorrido_em >= greatest(now() - make_interval(days => greatest(1, least(p_dias, 365))), timestamptz '2026-10-27 03:00+00')
  ), base as (
    select l.*, (l.ocorrido_em at time zone 'America/Sao_Paulo')::date as dia,
           (select m.enviada_em from public.mensagens m where m.conversa_id = l.conversa_id and m.direcao = 'recebida'
             and m.enviada_em >= l.ocorrido_em - interval '5 minutes' order by m.enviada_em limit 1) as chegou,
           r1.enviada_em as respondeu_em, r1.autor_email as quem
      from leads l
      left join lateral (
        select m.enviada_em, m.autor_email from public.mensagens m
         where m.conversa_id = l.conversa_id and m.direcao = 'enviada' and m.status <> 'falhou'
           and m.enviada_em >= l.ocorrido_em - interval '1 minute'
           -- conta como resposta: equipe, IA, celular e a 1ª mensagem automática (não lembretes nem follow-ups)
           and (m.autor_email like '%@%' or m.autor_email ilike 'IA:%' or m.canal = 'celular'
                or m.autor_email ilike 'automação: Primeira mensagem%')
         order by m.enviada_em limit 1) r1 on true
  ), calc as (
    select b.*, extract(epoch from (b.respondeu_em - coalesce(b.chegou, b.ocorrido_em))) / 60.0 as minutos,
           case when b.quem is null then 'sem resposta' when b.quem like '%@%' then 'equipe'
                when b.quem ilike 'IA:%' then 'IA' else '1ª mensagem automática' end as tipo_resp,
           exists (select 1 from public.pacientes p where p.telefone = b.telefone
                    and lower(coalesce(p.etapa, '')) in ('agendou', 'compareceu', 'ganho', 'faltou/desmarcou', 'paciente')) as agendou
      from base b
  )
  select jsonb_build_object(
    'periodo_dias', p_dias,
    'total', (select count(*) from calc),
    'mediana_min', (select round(percentile_cont(0.5) within group (order by minutos)::numeric, 1) from calc where minutos is not null),
    'ate_5_min', (select count(*) from calc where minutos <= 5),
    'por_dia', (select coalesce(jsonb_agg(d order by d->>'dia' desc), '[]') from (
        select jsonb_build_object('dia', dia, 'leads', count(*), 'ate_5_min', count(*) filter (where minutos <= 5),
          'mediana_min', round(percentile_cont(0.5) within group (order by minutos)::numeric, 1),
          'sem_resposta', count(*) filter (where respondeu_em is null), 'agendaram', count(*) filter (where agendou)) d
        from calc group by dia) x),
    'por_quem', (select coalesce(jsonb_agg(q), '[]') from (
        select jsonb_build_object('quem', quem2, 'leads', count(*),
          'mediana_min', round(percentile_cont(0.5) within group (order by minutos)::numeric, 1),
          'ate_5_min', count(*) filter (where minutos <= 5)) q
        from (select *, case when tipo_resp = 'equipe' then quem else tipo_resp end as quem2 from calc) c2 group by quem2) y),
    'agendamento_por_demora', (select coalesce(jsonb_agg(f order by f->>'ordem'), '[]') from (
        select jsonb_build_object('ordem', o, 'faixa', faixa, 'leads', count(*), 'agendaram', count(*) filter (where agendou)) f
        from (select *, case when minutos is null then 'Sem resposta' when minutos <= 5 then 'Até 5 min' when minutos <= 30 then '5 a 30 min'
                             when minutos <= 120 then '30 min a 2 h' else 'Mais de 2 h' end as faixa,
                        case when minutos is null then 5 when minutos <= 5 then 1 when minutos <= 30 then 2 when minutos <= 120 then 3 else 4 end as o
                from calc) z group by o, faixa) w)
  ) into r;
  return r;
end $$;
revoke all on function public.metricas_primeira_resposta(integer) from public, anon;
grant execute on function public.metricas_primeira_resposta(integer) to authenticated;
