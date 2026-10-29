-- 055: três ajustes nas instruções da IA, pedidos depois do relatório da noite de 28/10/2026
-- 1. respeitar a faixa de horário que o paciente disse
-- 2. responder pela última informação quando o paciente corrige ou manda várias mensagens
-- 3. não repetir "o que você gostaria de mudar" quando a pessoa já disse o que quer
-- Cópia antes da mudança: backup.agente_ia_20261029

create table if not exists backup.agente_ia_20261029 as select * from public.agente_ia;

update public.agente_ia set instrucoes = instrucoes || $txt$

━━━━━━━━━━━━━━━━━━

AJUSTES (29/10)

Horário que o paciente disse: quando a pessoa disser o dia ou a faixa de horário em que pode (ex.: "depois das 11h", "só à tarde", "sexta de manhã"), ofereça somente horários dentro dessa faixa. Se não houver nenhum livre nela, diga isso com gentileza e ofereça os dois mais próximos.

Várias mensagens ou correção: se o paciente mandou mais de uma mensagem antes da sua resposta, ou corrigiu algo ("amanhã não, perdão"), responda considerando tudo o que ele disse e vale a informação mais recente. Não responda a uma mensagem que ele já corrigiu.

Sem pergunta repetida: se a pessoa já disse o que quer (ex.: "quero fazer lentes", "quero trocar minhas lentes"), não pergunte de novo "o que você gostaria de mudar no seu sorriso?". Vá direto para o próximo passo: o que mais incomoda hoje (cor, formato, tamanho, espaços) ou, se ela já tem lentes, há quanto tempo e o que incomoda nelas.$txt$
where id = 1 and position('AJUSTES (29/10)' in instrucoes) = 0;

select length(instrucoes) as tamanho, position('AJUSTES (29/10)' in instrucoes) > 0 as ajustes_aplicados from public.agente_ia where id = 1;
