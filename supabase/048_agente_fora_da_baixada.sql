-- ============================================================
-- CRM Bulhões — Agente de IA: lead de fora da Baixada Santista (27/10/2026)
--   • pergunta se a pessoa pode vir a Santos fazer as lentes;
--   • se pode: avaliação ONLINE (Google Meet, Dra. Victória, 1 h), marcada
--     na mesma agenda com a observação "AVALIAÇÃO ONLINE";
--   • se não pode: agradece, marca Perdido e para de responder
--     (ferramenta nova encerrar_sem_interesse → registro tipo 'perdido');
--   • no máximo 2 mensagens por resposta.
-- Rodar no Supabase: SQL Editor → New query → colar tudo → Run.
-- ============================================================
alter table public.agente_registros drop constraint if exists agente_registros_tipo_check;
alter table public.agente_registros add constraint agente_registros_tipo_check
  check (tipo in ('resposta', 'transferencia', 'sugestao', 'resumo', 'teste', 'erro', 'agendamento', 'perdido'));

-- versão anterior guardada (dá para desfazer)
create schema if not exists backup;
create table if not exists backup.agente_ia_20261027 as select * from public.agente_ia where id = 1;
alter table backup.agente_ia_20261027 enable row level security;

update public.agente_ia set
  instrucoes = replace(replace(replace(replace(replace(instrucoes,
$a$Se for de outra cidade: "Que bacanaa, temos muitos pacientes de [cidade]!"
Se a pessoa já disse onde mora, não pergunte de novo.$a$,
$b$Se for de outra cidade da Baixada Santista: "Que bacanaa, temos muitos pacientes de [cidade]!"
Se morar fora da Baixada Santista, pergunte: "Você teria disponibilidade de vir até Santos para realizar as suas lentes de contato dental?"
  Se puder vir: siga o roteiro normalmente, mas a avaliação é ONLINE, pelo Google Meet, com a Dra. Victória (cerca de 1 hora). Ao marcar, use agendar_avaliacao com online = true.
  Se não puder vir: agradeça com carinho ("Entendo, [nome]! Muito obrigada pelo seu contato, fico à disposição 💙") e use encerrar_sem_interesse. Não insista.
Se a pessoa já disse onde mora, não pergunte de novo.$b$),
$a$Não pergunte manhã ou tarde antes de explicar a avaliação.$a$,
$b$Não pergunte manhã ou tarde antes de explicar a avaliação.
Para quem é de fora da Baixada Santista e pode vir a Santos: "Como você é de fora, o primeiro passo é uma avaliação online com a Dra, pelo Google Meet. Nela ela entende seu caso, ouve suas expectativas e te explica o planejamento." Depois siga com manhã ou tarde.$b$),
$a$A consulta dura de 50 minutos a 1 hora. Um dia antes te mando uma mensagem para confirmar, tá bom?"$a$,
$b$A consulta dura de 50 minutos a 1 hora. Um dia antes te mando uma mensagem para confirmar, tá bom?"
Se for avaliação online, troque a linha do endereço por "💻 Online, pelo Google Meet. A equipe te envia o link antes do horário."$b$),
$a$Nunca ofereça avaliação online.$a$,
$b$Nunca ofereça avaliação online para quem mora na Baixada Santista.$b$),
$a$No máximo 4 mensagens por vez antes de esperar a resposta.$a$,
$b$No máximo 2 mensagens por vez antes de esperar a resposta.$b$),
  base_conhecimento = replace(replace(base_conhecimento,
$a$AVALIAÇÃO ONLINE OU ORÇAMENTO PELO WHATSAPP
Não fazemos. "Pra montar um planejamento com responsabilidade, a Dra precisa ver seu sorriso pessoalmente."$a$,
$b$ORÇAMENTO PELO WHATSAPP
Não fazemos. "Pra montar um planejamento com responsabilidade, a Dra precisa avaliar seu sorriso."

AVALIAÇÃO ONLINE
Só para quem mora fora da Baixada Santista e tem disponibilidade de vir a Santos fazer o tratamento. É pelo Google Meet, com a Dra. Victória, e dura cerca de 1 hora. A equipe envia o link antes do horário. Quem mora na Baixada Santista faz a avaliação presencial.$b$),
$a$MORA LONGE OU EM OUTRA CIDADE
"Que bacanaa, temos muitos pacientes de [cidade]! Pela qualidade, pelos resultados naturais e pelas facilidades no pagamento, vale muito a pena." Se a pessoa tem poucos dias livres, ofereça o dia que ela puder (inclusive sábado de manhã).$a$,
$b$MORA LONGE OU EM OUTRA CIDADE
Fora da Baixada Santista: pergunte se a pessoa tem disponibilidade de vir até Santos para realizar as lentes. Se tiver: "Que bacanaa, temos muitos pacientes de [cidade]! Pela qualidade, pelos resultados naturais e pelas facilidades no pagamento, vale muito a pena." e marque a avaliação online. Se não tiver, agradeça e encerre.
Se a pessoa tem poucos dias livres, ofereça o dia que ela puder (inclusive sábado de manhã).$b$),
  atualizado_em = now()
where id = 1;

select position('encerrar_sem_interesse' in instrucoes) > 0 as cidade_ok,
       position('Google Meet. A equipe' in instrucoes) > 0 as confirmacao_ok,
       position('para quem mora na Baixada Santista.' in instrucoes) > 0 as nunca_ok,
       position('No máximo 2 mensagens' in instrucoes) > 0 as duas_ok,
       position(E'AVALIAÇÃO ONLINE\nSó para' in base_conhecimento) > 0 as base_online_ok,
       position('Fora da Baixada Santista: pergunte' in base_conhecimento) > 0 as base_longe_ok
from public.agente_ia where id = 1;
