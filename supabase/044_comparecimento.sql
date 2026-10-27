-- ============================================================
-- CRM Bulhões — Comparecimento (27/10/2026)
--   • Lembrete novo "aquecimento": vídeo de desejo 2 dias antes da avaliação.
--   • 1ª confirmação com vídeo (vespera.modelo_video) para quem não recebeu o
--     aquecimento: escolhida na tela de lembretes. Fica sem modelo até o vídeo.
--   • Sequência "Boas-vindas ao agendar" (DESLIGADA): ao virar Agendou, manda o
--     texto do presente e o vídeo da Dra. Larissa. Falta subir o vídeo e ligar.
-- Rodar no Supabase: SQL Editor → New query → colar tudo → Run.
-- ============================================================
do $$
declare r record;
begin
  for r in select conrelid::regclass as t, conname from pg_constraint
            where conrelid in ('public.lembretes_consulta'::regclass, 'public.lembretes_rodadas'::regclass)
              and contype = 'c' and pg_get_constraintdef(oid) ilike '%tipo%' loop
    execute format('alter table %s drop constraint %I', r.t, r.conname);
  end loop;
end $$;
alter table public.lembretes_consulta add constraint lembretes_consulta_tipo_check
  check (tipo in ('vespera', 'vespera2', 'vespera3', 'dia', 'aquecimento'));
alter table public.lembretes_rodadas add constraint lembretes_rodadas_tipo_check
  check (tipo in ('vespera', 'vespera2', 'vespera3', 'dia', 'aquecimento'));

-- horário do aquecimento (sem modelo = desligado)
update public.configuracoes
   set valor = valor || jsonb_build_object('aquecimento', coalesce(valor->'aquecimento', '{}'::jsonb) || '{"hora":"11:30"}'::jsonb)
 where chave = 'lembretes_consulta';

insert into public.automacoes (nome, descricao, ligada, modo_teste, telefones_teste, gatilho, regras, passos)
select 'Boas-vindas ao agendar',
       'Ao virar Agendou: texto do presente e vídeo da Dra. Larissa (comparecimento). Falta subir o vídeo no passo 2.',
       false, true, '{}',
       '{"tipo":"etapa","lista":[{"tipo":"etapa","etapa":"Agendou"}]}'::jsonb,
       '{"espaco_min":0,"saida":{"tipo":"nenhuma"}}'::jsonb,
       jsonb_build_array(
         jsonb_build_object('tipo', 'texto', 'ignorar_horario', true, 'sem_janela', 'parar',
           'texto', '{primeiro_nome}, sua avaliação está reservada com carinho para você 💙 A Dra. Larissa gravou esse vídeo contando como vai ser. Esse presente vale só com a sua presença. Posso contar com o seu comparecimento?'),
         jsonb_build_object('tipo', 'midia', 'formato', 'video', 'ignorar_horario', true, 'sem_janela', 'parar', 'link', '', 'legenda', ''),
         jsonb_build_object('tipo', 'fim'))
where not exists (select 1 from public.automacoes where nome = 'Boas-vindas ao agendar');

select (select id from public.automacoes where nome = 'Boas-vindas ao agendar') as sequencia,
       (select valor->'aquecimento' from public.configuracoes where chave = 'lembretes_consulta') as aquecimento;
