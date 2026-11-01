-- 066 (01/11/2026)
-- 1. Transcrição de áudio: mensagens.transcricao (preenchida pelo webhook quando há OPENAI_API_KEY)
-- 2. FUPs também no fim de semana, dentro do horário da IA: sábado 14h10–18h, domingo 10h–18h.
--    Quando um FUP sai no fim de semana, o robô da conversa é ligado (a equipe não está; a IA responde).
-- 3. FUP 20 minutos: lead quente que parou de responder 20 min depois da última mensagem da equipe
--    ou da IA recebe uma mensagem escrita pela IA, retomando de onde parou (08h–22h15; fora disso não sai).
-- Cópia antes: backup.automacoes_20261101

alter table public.mensagens add column if not exists transcricao text;

create table if not exists backup.automacoes_20261101 as select * from public.automacoes;

update public.automacoes
   set regras = regras || '{"sabado":{"inicio":"14:10","fim":"18:00"},"domingo":{"inicio":"10:00","fim":"18:00"},"robo_fim_de_semana":true}'::jsonb
 where nome ilike 'FUP %' and nome <> 'FUP 20 minutos';

insert into public.automacoes (nome, descricao, ligada, modo_teste, telefones_teste, gatilho, regras, passos, numero_clinica_id)
select 'FUP 20 minutos',
       'Lead quente: parou de responder 20 min depois da última mensagem da equipe ou da IA. A IA escreve retomando de onde a conversa parou. Só das 8h às 22h15 (fora disso não sai).',
       true, false, '{}', a.gatilho,
       (a.regras - 'sabado' - 'domingo' - 'robo_fim_de_semana') || '{"inicio":"08:00","fim":"22:15","fora_do_horario":"pular","pular_fim_de_semana":false}'::jsonb,
       (select jsonb_agg(case when e->>'tipo' = 'esperar' then jsonb_set(e, '{minutos}', '20')
                              when e->>'tipo' = 'se' and e->'condicao'->>'tipo' = 'sem_resposta' then jsonb_set(e, '{condicao,minutos}', '20')
                              else e end order by o)
          from jsonb_array_elements(a.passos) with ordinality t(e, o)),
       a.numero_clinica_id
  from public.automacoes a
 where a.nome = 'FUP 2 horas'
   and not exists (select 1 from public.automacoes where nome = 'FUP 20 minutos');

select id, nome, regras->>'inicio' as ini, regras->>'fim' as fim, regras->'sabado' as sab, regras->'domingo' as dom,
       (select string_agg(e->>'tipo' || coalesce(':' || (e->>'minutos'), '') || coalesce(':' || (e->'condicao'->>'minutos'), ''), ', ') from jsonb_array_elements(passos) e) as passos
  from public.automacoes where nome ilike 'FUP %' order by id;
