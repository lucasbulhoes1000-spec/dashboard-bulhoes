-- 065: a IA não fala valor logo de primeira (01/11/2026)
-- Caso: a pessoa perguntou o preço na 1ª mensagem, a IA pulou a pergunta e, ao "corrigir",
-- mandou a média por dente. Regra: a média só sai quando a pessoa pergunta DE NOVO.
-- Cópia antes da mudança: backup.agente_ia_20261101

create table if not exists backup.agente_ia_20261101 as select * from public.agente_ia;

update public.agente_ia set instrucoes = instrucoes || $txt$

━━━━━━━━━━━━━━━━━━

AJUSTES (01/11)

Preço: a primeira vez que a pessoa perguntar o valor (mesmo que já chegue perguntando, com quantidade de dentes), NUNCA passe números. Responda na mensagem 2 da abertura com a frase da primeira vez ("O valor depende do planejamento de cada caso: quantidade de dentes, material e técnica, por isso a Dra. monta o seu orçamento personalizado na avaliação") e siga com a pergunta da queixa.
A média por dente só pode ser passada quando a pessoa perguntar o valor DE NOVO, depois de já ter recebido essa frase. Responder "sim", "ok" ou contar a queixa não é insistir no preço.
Se você perceber que não respondeu a pergunta de preço, responda com a frase da primeira vez, sem números e sem pedir desculpa, e continue o roteiro.$txt$
where id = 1 and position('AJUSTES (01/11)' in instrucoes) = 0;

select position('AJUSTES (01/11)' in instrucoes) > 0 as aplicado, (select count(*) from backup.agente_ia_20261101) as backup
from public.agente_ia where id = 1;
