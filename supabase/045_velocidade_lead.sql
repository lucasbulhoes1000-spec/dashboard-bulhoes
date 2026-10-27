-- ============================================================
-- CRM Bulhões — Velocidade no lead novo (27/10/2026)
--   • Sequência "Primeira mensagem (5 min sem resposta)": lead novo que ficou 5 min
--     sem nenhuma resposta (equipe, IA ou celular) recebe a abertura do script.
--   • FUP 2 horas e FUP 4 horas: a mensagem passa a ser escrita pela IA (passo "ia"),
--     retomando de onde o lead parou; se a IA falhar, sai o texto de antes.
--   • metricas_primeira_resposta(dias): tempo da 1ª resposta por dia e por atendente,
--     e o agendamento conforme a demora.
-- Rodar no Supabase: SQL Editor → New query → colar tudo → Run.
-- ============================================================
insert into public.automacoes (nome, descricao, ligada, modo_teste, telefones_teste, gatilho, regras, passos)
select 'Primeira mensagem (5 min sem resposta)',
       'Lead novo sem nenhuma resposta em 5 minutos recebe a abertura do script. Se a Raffa (ou a IA) já respondeu, não sai nada.',
       true, false, '{}',
       '{"tipo":"lead_criado","lista":[{"tipo":"lead_criado"}]}'::jsonb,
       '{"espaco_min":0,"saida":{"tipo":"nenhuma"}}'::jsonb,
       jsonb_build_array(
         jsonb_build_object('tipo', 'esperar', 'minutos', 5),
         jsonb_build_object('tipo', 'se', 'senao', 'fim', 'condicao', jsonb_build_object('tipo', 'ninguem_respondeu')),
         jsonb_build_object('tipo', 'texto', 'ignorar_horario', true, 'sem_janela', 'parar',
           'texto', 'Oiii, tudo bem? 😊 Me chamo Raffaela, sou responsável pelo atendimento na Bulhões Odontologia 💙' || chr(10) || chr(10) ||
                    'A maioria dos nossos pacientes que buscam lentes tem receio de um resultado artificial.' || chr(10) || chr(10) ||
                    'Me conta, o que você gostaria de mudar no seu sorriso? Espacinho entre os dentes, formato, tamanho, cor...?'),
         jsonb_build_object('tipo', 'fim'))
where not exists (select 1 from public.automacoes where nome = 'Primeira mensagem (5 min sem resposta)');

-- FUP 2 h e 4 h: texto vira "ia" (o texto fica de reserva)
update public.automacoes a
   set passos = (select jsonb_agg(case when e->>'tipo' = 'texto' then e || '{"tipo":"ia"}'::jsonb else e end order by o)
                   from jsonb_array_elements(a.passos) with ordinality t(e, o))
 where a.nome in ('FUP 2 horas', 'FUP 4 horas');

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

select (select id from public.automacoes where nome = 'Primeira mensagem (5 min sem resposta)') as primeira_msg,
       (select string_agg(nome || ': ' || (select string_agg(e->>'tipo', ',') from jsonb_array_elements(passos) e), ' | ') from public.automacoes where nome in ('FUP 2 horas','FUP 4 horas')) as fups;
