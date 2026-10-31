-- 056: respostas rápidas da Raffa no script novo (31/10/2026)
-- Pedido do Lucas: refazer as barras para o processo novo e tirar as que sobram.
-- Ficam intactas (pedido da Raffa): avaliacaoporfoto, casoretrabalho, clareamentoconjugado, combinado,
-- comparacaovalorlentes, consultapaga, endereco, desmarcacao, manutencaovalor, manutoutroprofissional,
-- outracidade, pedevalores2, pix, porcelanaouresina, tabelavalores.
-- Sem mudança até confirmar: riodejaneiro, paciente-modelo-porcelana(2), valor-paciente-modelo-porcelan,
-- explicacaohofcurso, pixinstitutobulhoes.
-- Cópia de antes: backup.respostas_rapidas_20261031

create table if not exists backup.respostas_rapidas_20261031 as select * from public.respostas_rapidas;

delete from public.respostas_rapidas where atalho in ('cadencia1', 'cadencia2', 'cadencia3', 'cadencia4', 'cadencia4-2', 'cadencia5', 'cadencia5-2', 'cadencia6', 'cadencia6-2', 'cadencia7', 'cadenciacampanhamarco', 'faltantes1', 'faltantes2', 'faltantes3', 'faltantes4', 'faltantes5', 'faltantes6', 'posfalta', 'confirmaramanha', 'confirmaramanha2', 'confirmaramanha3', 'confirmanodia', 'agendamento', 'marcaavaliacao', 'fundamental', 'orcamentoavaliacao', 'sondagem1', 'sondagem2', 'retrabalho-2', 'pedevalores', 'larissaceo', 'pedelenteslari', 'equipe', 'empatia', 'lentesoutroprofissional', 'tiposdelentes', 'black-video');

insert into public.respostas_rapidas (atalho, texto, partes)
values
  ('oiraffa', 'Oiii, {nome}, tudo bem? 😊 Me chamo Raffaela, sou responsável pelo atendimento na Bulhões Odontologia 💙 A maioria dos nossos pacientes que buscam lentes tem receio de um resultado artificial. Me conta, o que você gostaria de mudar no seu sorriso? Espacinho entre os dentes, formato, tamanho, cor...?', '[{"tipo": "texto", "texto": "Oiii, {nome}, tudo bem? 😊 Me chamo Raffaela, sou responsável pelo atendimento na Bulhões Odontologia 💙"}, {"tipo": "texto", "texto": "A maioria dos nossos pacientes que buscam lentes tem receio de um resultado artificial. Me conta, o que você gostaria de mudar no seu sorriso? Espacinho entre os dentes, formato, tamanho, cor...?"}]'::jsonb),
  ('seriapara', 'Perfeito, {nome}! Seria a avaliação para qual tratamento? Para transformar o seu sorriso com as lentes de contato dental?', null::jsonb),
  ('ddd', '{nome}, vi que o seu DDD é um pouquinho diferente, né? Você é de onde?', null::jsonb),
  ('retrabalho', 'Sério, {nome}? Infelizmente cada vez mais recebemos casos assim como o seu. Hoje 60% dos nossos casos são de retrabalho, inclusive de pacientes que fizeram as lentes há 2 ou 3 meses. Você realizou suas lentes há quanto tempo? E o que te incomoda nelas?', '[{"tipo": "texto", "texto": "Sério, {nome}? Infelizmente cada vez mais recebemos casos assim como o seu. Hoje 60% dos nossos casos são de retrabalho, inclusive de pacientes que fizeram as lentes há 2 ou 3 meses."}, {"tipo": "texto", "texto": "Você realizou suas lentes há quanto tempo? E o que te incomoda nelas?"}]'::jsonb),
  ('metodo', 'Olha esse caso. Aqui trabalhamos com o Método Bulhões, um protocolo próprio, com uma técnica premiada e altíssima naturalidade. São mais de 3.000 casos de lentes em mais de 7 anos, com uma equipe de especialistas dedicada a esse método. Cada sorriso é planejado exclusivamente para o rosto de cada paciente. É algo assim que você imagina para o seu sorriso?', '[{"tipo": "texto", "texto": "Olha esse caso. Aqui trabalhamos com o Método Bulhões, um protocolo próprio, com uma técnica premiada e altíssima naturalidade. São mais de 3.000 casos de lentes em mais de 7 anos, com uma equipe de especialistas dedicada a esse método. Cada sorriso é planejado exclusivamente para o rosto de cada paciente."}, {"tipo": "texto", "texto": "É algo assim que você imagina para o seu sorriso?"}]'::jsonb),
  ('aparelho', 'Entendii! Recebemos muitos pacientes com essa queixa: dentes que voltaram a se movimentar depois do aparelho, ou quem não quer mais usar aparelho. Em alguns casos dá para melhorar com lentes, sem aparelho, e a Dra. te explica as possibilidades na avaliação.', null::jsonb),
  ('gengiva', 'Sobre a gengiva, existe a gengivoplastia, que ajusta o contorno da gengiva e muitas vezes é planejada junto com as lentes. Se ela faz sentido no seu caso, a Dra. avalia na consulta 💙', null::jsonb),
  ('tons', 'Nas lentes em resina trabalhamos com alguns tons. O BL2 é o mais pedido: um branco natural, que permite a estratificação, a técnica que dá à lente o aspecto de dente de verdade. O BL1 é um branco mais intenso e não permite estratificação. O BW é o tom mais próximo da cor natural dos dentes. Qual combina com você a Dra. define na avaliação, olhando o seu rosto e o que você deseja.', null::jsonb),
  ('avaliacao', 'No seu caso, o primeiro passo é a avaliação personalizada com a Dra. Nela a gente entende seu caso com calma, faz o visagismo, vê o material e a técnica indicados para você e monta seu planejamento e orçamento personalizado, com facilidade no pagamento. A avaliação completa normalmente custa R$ 250, e estamos te presenteando com ela como cortesia 💙 Para você fica melhor de manhã ou à tarde?', '[{"tipo": "texto", "texto": "No seu caso, o primeiro passo é a avaliação personalizada com a Dra. Nela a gente entende seu caso com calma, faz o visagismo, vê o material e a técnica indicados para você e monta seu planejamento e orçamento personalizado, com facilidade no pagamento."}, {"tipo": "texto", "texto": "A avaliação completa normalmente custa R$ 250, e estamos te presenteando com ela como cortesia 💙 Para você fica melhor de manhã ou à tarde?"}]'::jsonb),
  ('manhatarde', 'Para você vir fazer a sua avaliação, fica melhor de manhã ou à tarde?', null::jsonb),
  ('forasantos', 'Você teria disponibilidade de vir até Santos para realizar as suas lentes de contato dental?', null::jsonb),
  ('avaliacaoonline', 'Como você é de fora, o primeiro passo é uma avaliação online com a Dra., pelo Google Meet. Nela ela entende o seu caso, ouve suas expectativas e te explica o planejamento. Ela dura cerca de 1 hora e também é cortesia 💙 Para você fica melhor de manhã ou à tarde?', null::jsonb),
  ('outrosprocedimentos', 'Perfeito, {nome}! Somos uma clínica integrada: cada área da odontologia tem um especialista aqui, de implante a canal, ortodontia e harmonização. Assim conseguimos resolver tudo em um lugar só. Para você vir fazer a sua avaliação, fica melhor de manhã ou à tarde?', null::jsonb),
  ('dralarissa', 'A Dra. Larissa desenvolveu o Método Bulhões e treinou a equipe por anos. As avaliações são feitas pela Dra. Victória, responsável pelos planejamentos do método, com o mesmo protocolo dela 💙', null::jsonb),
  ('nomecompleto', 'Perfeito! Para concluir e reservar na agenda, pode me passar seu nome completo, por favor?', null::jsonb),
  ('agendado', '{nome}, sua avaliação está confirmada com exclusividade aqui na Bulhões Odontologia 💙

📆 Data: 
⏰ Horário: 
📍 Av. Senador Feijó, 686, sala 923, Vila Mathias, Santos (Edifício The Blue Officemall)

A consulta dura de 50 minutos a 1 hora.

Posso contar com o seu comparecimento?', null::jsonb),
  ('agendadoonline', '{nome}, sua avaliação online está confirmada com exclusividade aqui na Bulhões Odontologia 💙

📆 Data: 
⏰ Horário: 
💻 Online, pelo Google Meet. No dia da avaliação você recebe o link por aqui.

A consulta dura cerca de 1 hora.

Posso contar com a sua presença?', null::jsonb),
  ('antecipacao', '{nome}, abriu um horário na agenda para [dia e horário], que costuma ser bem disputado por aqui. Pensei em você, porque daria para antecipar a sua avaliação. Só se for confortável para você: quer aproveitar?', null::jsonb),
  ('remarca', 'Entendi, {nome}! Como você avisou com antecedência, consigo manter a sua avaliação de cortesia nessa remarcação. Numa próxima remarcação, a avaliação passa a ser cobrada no valor normal, tudo bem?', null::jsonb),
  ('media', 'Entendo, {nome}! O valor depende do planejamento de cada caso: quantidade de dentes, material e técnica. Por isso a Dra. monta o seu orçamento personalizado na avaliação.', null::jsonb),
  ('media2', 'Para você ter uma ideia, nas lentes em resina a média costuma ficar entre R$ 450 e R$ 550 por dente, e nas de porcelana entre R$ 1.500 e R$ 1.800 por dente. O orçamento certo é feito durante a avaliação.', null::jsonb),
  ('quantosdentes', 'Depende do seu sorriso. Muitas vezes são 10 dentes em cima, mas tem casos em que 8 já bastam, ou só alguns dentes específicos. Por isso a avaliação vem antes.', null::jsonb),
  ('pagamento', 'Trabalhamos com todas as formas de pagamento, inclusive parcelamento em até 12x sem juros! As condições do seu caso a Dra. apresenta na consulta.', null::jsonb),
  ('boleto', 'No boleto, você dá um valor de entrada e já pode começar o tratamento. As parcelas seguintes são pagas como no cartão, mas sem usar o limite.', null::jsonb),
  ('convenio', 'Hoje nossos atendimentos são particulares, não atendemos convênio. Trabalhamos com os melhores materiais para fazer o tratamento uma única vez e com qualidade. Venha nos conhecer, temos facilidades exclusivas para você!', null::jsonb),
  ('conveniomanutencao', 'Não, o convênio cobre a limpeza básica. A manutenção das lentes em resina é diferente: além da limpeza detalhada de dentes e lentes, fazemos o polimento e o cuidado do material, que pede quem trabalha com esse procedimento.', null::jsonb),
  ('artificial', 'Esse receio é o mais comum por aqui! O sorriso é planejado de acordo com o seu rosto: cor, formato, tamanho e proporção, para ficar harmônico e natural. O que mais te preocupa: dentes muito brancos, muito grandes ou com formato artificial?', null::jsonb),
  ('desgaste', 'Fica tranquila! O nosso Método Bulhões, além de ser referência em lentes com altíssima naturalidade, não desgasta os seus dentes naturais. Os detalhes do seu caso a Dra. explica na avaliação.', null::jsonb),
  ('riscoslentes', 'A segurança vem do planejamento. Antes das lentes fazemos uma limpeza completa e avaliamos a saúde da sua boca; se precisar, os tratamentos de saúde vêm primeiro. Depois, a manutenção é indicada a cada 6 meses, para manter o brilho e cuidar das lentes.', null::jsonb),
  ('financeiro', 'Oie, eu vou te ajudar ☺️ Esse número é para as avaliações. Vou te passar o contato do nosso financeiro, exclusivo para os pacientes, e a Paula continua o seu atendimento por lá 💙', null::jsonb),
  ('recepcao', 'Oie, eu vou te ajudar ☺️ Esse número é para as avaliações. Vou te passar o contato da nossa recepção, exclusiva para os pacientes, e a Luiza continua o seu atendimento por lá 💙', null::jsonb),
  ('avaliacaohof', 'Na harmonização, cada rosto é único, então o primeiro passo é a avaliação: a Dra. entende o que você quer realçar, tira suas dúvidas e monta um planejamento só seu. Para você fica melhor de manhã ou à tarde?', null::jsonb),
  ('hofsondagem', 'Antes de tudo, me conta: o que te incomoda no rosto que a gente pode ajudar a realçar?', null::jsonb),
  ('botox', 'A toxina botulínica age na musculatura e suaviza as rugas de expressão, aquelas que aparecem quando a gente fala, sorri ou franze a testa. Também pode ajudar a arquear as sobrancelhas, suavizar o sorriso gengival e aliviar o bruxismo. O efeito dura em média até 6 meses e vai saindo aos poucos. Qual região você gostaria de avaliar?', null::jsonb),
  ('preenchimentolabial', 'O preenchimento labial é feito com ácido hialurônico. Começamos com 1 ml, que hidrata e dá um leve volume; depois de 20 dias, se você quiser, dá para complementar. O efeito dura em média 12 meses e vai saindo aos poucos. A região é anestesiada para o seu conforto.', null::jsonb),
  ('profilaxia', 'A profilaxia é uma limpeza completa e profunda dos dentes e da gengiva. Ela deixa a boca saudável e pronta antes das lentes.', null::jsonb),
  ('avaliacaoimplantesraiox', 'Para o caso de implante, a Dra. precisa de uma radiografia panorâmica para planejar com segurança. Aqui no prédio tem a clínica Radios, que indicamos aos nossos pacientes pela praticidade. Você consegue fazer antes da avaliação?', null::jsonb)
on conflict (atalho) do update set texto = excluded.texto, partes = excluded.partes, atualizada_em = now();

select count(*) as total, (select count(*) from backup.respostas_rapidas_20261031) as antes from public.respostas_rapidas;
