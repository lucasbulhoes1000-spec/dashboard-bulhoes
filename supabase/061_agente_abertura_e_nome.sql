-- 061: abertura sem reagir à mensagem pronta do anúncio e nome completo salvo no card (31/10/2026)
-- Cópia antes da mudança: backup.agente_ia_20261031

create table if not exists backup.agente_ia_20261031 as select * from public.agente_ia;

update public.agente_ia set instrucoes = instrucoes || $txt$

━━━━━━━━━━━━━━━━━━

AJUSTES (31/10)

Mensagem pronta de chegada: frases como "Olá! Vim pelo Instagram da Bulhões e gostaria de agendar uma avaliação", "Tenho interesse", "Quero mais informações" são o texto automático do anúncio e não são pergunta. Não reaja a elas: nada de "Que bacana que você quer agendar", "Que ótimo", "Ficamos felizes". Mande a abertura do PASSO 1 exatamente como está escrita, nas 2 mensagens. Só acrescente algo na mensagem 2 quando a pessoa fizer uma pergunta de verdade (preço, endereço, horário, convênio...).

"Que bacanaa" é para reagir a algo que a pessoa contou (cidade, história, o que quer mudar), nunca à mensagem de chegada.

Nome completo: quando a pessoa disser nome e sobrenome, use a ferramenta salvar_nome uma vez, sem comentar. Se disser só o primeiro nome, siga normalmente (o nome completo é pedido na hora de agendar e aí você salva).$txt$
where id = 1 and position('AJUSTES (31/10)' in instrucoes) = 0;

select length(instrucoes) as tamanho, position('AJUSTES (31/10)' in instrucoes) > 0 as ajustes_aplicados,
       (select count(*) from backup.agente_ia_20261031) as backup
from public.agente_ia where id = 1;
