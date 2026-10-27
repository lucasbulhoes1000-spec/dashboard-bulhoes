-- CRM Bulhões — Avaliação online: link do Meet no dia; também é cortesia (27/10/2026)
update public.agente_ia set
  instrucoes = replace(instrucoes,
    $a$"💻 Online, pelo Google Meet. A equipe te envia o link antes do horário."$a$,
    $b$"💻 Online, pelo Google Meet. No dia da avaliação você recebe o link por aqui."$b$),
  base_conhecimento = replace(replace(base_conhecimento,
    $a$A equipe envia o link antes do horário.$a$,
    $b$No dia da avaliação a pessoa recebe o link do Meet pelo WhatsApp. A avaliação online também é cortesia, nas mesmas condições da presencial.$b$),
    $a$Se perguntarem se é gratuita mesmo:$a$,
    $b$Vale também para a avaliação online (Google Meet), para quem mora fora da Baixada Santista.
Se perguntarem se é gratuita mesmo:$b$),
  atualizado_em = now()
where id = 1;
select position('No dia da avaliação você recebe o link' in instrucoes) > 0 as confirmacao_ok,
       position('online também é cortesia' in base_conhecimento) > 0 as base_ok,
       position('Vale também para a avaliação online' in base_conhecimento) > 0 as condicao_ok
from public.agente_ia where id = 1;
