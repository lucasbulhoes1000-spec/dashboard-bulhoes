-- ============================================================
-- 083 (14/11/2026): Ale, a triagem da recepção
--   Quem manda mensagem para a recepção e não falou com ninguém da equipe nas últimas
--   12 horas recebe o menu da Ale (texto aprovado pelo Lucas em 14/11). A resposta
--   (1 a 6) põe a tag do assunto e manda para a fila da recepção; a opção 5 (agendar
--   avaliação) manda um link para o WhatsApp do comercial com o código invisível,
--   e o lead aparece com origem "Recepção".
--   A Ale NÃO usa robo_ligado (isso acordaria a IA do comercial): o estado fica em
--   conversas.ale_estado. Quem envia é o motor (whatsapp-automacoes), a cada minuto.
--   Entra LIGADA em MODO TESTE, só com o celular do Lucas.
-- ============================================================

alter table public.conversas add column if not exists ale_estado text;   -- menu | menu2 | encaminhado
alter table public.conversas add column if not exists ale_em timestamptz;

create table if not exists public.ale_fila (
  id           bigserial primary key,
  mensagem_id  uuid not null unique,
  conversa_id  uuid not null,
  texto        text,
  tipo         text,
  criado_em    timestamptz not null default now(),
  status       text not null default 'pendente' check (status in ('pendente', 'processando', 'feito', 'ignorado', 'erro')),
  motivo       text,
  feito_em     timestamptz
);
create index if not exists ale_fila_pendentes on public.ale_fila (id) where status = 'pendente';
alter table public.ale_fila enable row level security;
revoke all on public.ale_fila from anon, authenticated;
grant all on public.ale_fila to service_role;
grant usage, select on sequence public.ale_fila_id_seq to service_role;

-- mensagem nova na recepção: entra na fila da Ale. Equipe respondeu: a Ale sai da conversa.
create or replace function public.ale_t_mensagem() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_num text; c public.conversas;
begin
  select valor->>'numero_clinica_id' into v_num from public.configuracoes
   where chave = 'ale_recepcao' and coalesce((valor->>'ligado')::boolean, false);
  if v_num is null then return null; end if;
  select * into c from public.conversas where id = new.conversa_id;
  if c.id is null or c.numero_clinica_id is distinct from v_num or c.canal = 'instagram' then return null; end if;
  if new.direcao = 'enviada' then
    if (coalesce(new.canal, 'crm') = 'crm' and exists (select 1 from public.equipe e where e.email = new.autor_email))
       or new.canal = 'celular' then
      update public.conversas set ale_estado = null where id = c.id and ale_estado in ('menu', 'menu2');
    end if;
    return null;
  end if;
  if coalesce(new.canal, 'paciente') <> 'paciente' or new.enviada_em < now() - interval '10 minutes' then return null; end if;
  insert into public.ale_fila (mensagem_id, conversa_id, texto, tipo)
  values (new.id, c.id, left(new.texto, 500), new.tipo) on conflict (mensagem_id) do nothing;
  return null;
exception when others then
  insert into public.espelho_erros (origem, erro, detalhe) values ('ale_t_mensagem', sqlerrm, new.conversa_id::text);
  return null;
end $$;
drop trigger if exists t_ale_mensagem on public.mensagens;
create trigger t_ale_mensagem after insert on public.mensagens
  for each row execute function public.ale_t_mensagem();

create or replace function public.ale_pegar()
returns setof public.ale_fila
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  update public.ale_fila set status = 'pendente' where status = 'processando' and criado_em < now() - interval '10 minutes';
  return query
  with x as (
    update public.ale_fila f set status = 'processando'
     where f.id in (select y.id from public.ale_fila y where y.status = 'pendente'
                     and y.criado_em < now() - interval '20 seconds'   -- espera a resposta do lembrete ser classificada
                     order by y.id limit 20 for update skip locked)
    returning f.*)
  select * from x;
end $$;
revoke all on function public.ale_pegar() from public, anon, authenticated;
revoke all on function public.ale_t_mensagem() from public, anon, authenticated;
grant execute on function public.ale_pegar() to service_role;

-- tags dos assuntos
insert into public.wa_tags (nome, cor) values
  ('remarcar ou cancelar', '#C97B63'),
  ('dúvida de tratamento', '#7FA7C9'),
  ('urgência', '#D9534F'),
  ('financeiro', '#6C9A8B'),
  ('agendar avaliação', '#A18B6C'),
  ('outro assunto', '#8C98B1')
on conflict (nome) do nothing;

-- configuração (os textos de resposta podem ser trocados aqui)
insert into public.configuracoes (chave, valor)
select 'ale_recepcao', jsonb_build_object(
  'ligado', true,
  'modo_teste', true,
  'telefones_teste', '["13996075557"]'::jsonb,
  'numero_clinica_id', (select phone_number_id from public.whatsapp_numeros where apelido = 'Recepção' and ativo limit 1),
  'horas_silencio', 12,
  'whatsapp_comercial', '5513996300176',
  'menu', E'Oii, tudo bem? Que bom ter você por aqui 💙\n\nSou a Ale, assistente virtual da Bulhões Odontologia. Me conta, como posso te ajudar hoje?\n\n1. Remarcar ou cancelar uma consulta\n2. Dúvida sobre um tratamento que já estou fazendo\n3. Estou com dor ou alguma urgência\n\n4. Pagamentos e financeiro\n\n5. Agendar avaliação\n6. Outro assunto\n\nÉ só responder com o número, que vamos te auxiliar 😊',
  'nao_entendi', 'Não consegui entender 😊 Pode me responder só com o número da opção, de 1 a 6?',
  'opcoes', jsonb_build_object(
    '1', jsonb_build_object('tag', 'remarcar ou cancelar', 'resposta', 'Claro! Já avisei a nossa equipe da recepção, e logo alguém te chama por aqui para te ajudar com a sua consulta 💙'),
    '2', jsonb_build_object('tag', 'dúvida de tratamento', 'resposta', 'Certo! Pode me contar sua dúvida por aqui, que a nossa equipe já te responde 💙'),
    '3', jsonb_build_object('tag', 'urgência', 'resposta', 'Sinto muito que você esteja passando por isso. Já avisei a nossa equipe para te atender com prioridade 💙' || E'\n\n' || 'Se for uma dor muito forte, sangramento que não para, inchaço que aumenta, febre ou dificuldade para respirar ou engolir, procure um pronto atendimento agora, sem esperar a gente, tá bom?'),
    '4', jsonb_build_object('tag', 'financeiro', 'resposta', 'Certo! Já passei para a nossa equipe, e logo alguém te chama por aqui para te ajudar 💙'),
    '5', jsonb_build_object('tag', 'agendar avaliação', 'link', true, 'mensagem_link', 'Olá! Vim pela recepção e gostaria de agendar uma avaliação 💙',
          'resposta', 'Que alegria! 💙 Para agendar sua avaliação, é só tocar no link abaixo e enviar a mensagem que vai aparecer. Nossa equipe de agendamento te atende por lá:' || E'\n\n' || '{link}'),
    '6', jsonb_build_object('tag', 'outro assunto', 'resposta', 'Certo! Pode me contar o que você precisa, que a nossa equipe já te responde por aqui 💙')
  )
)
where not exists (select 1 from public.configuracoes where chave = 'ale_recepcao');

select (select valor->>'numero_clinica_id' from public.configuracoes where chave = 'ale_recepcao') as numero_recepcao,
       (select count(*) from public.wa_tags where nome in ('remarcar ou cancelar','dúvida de tratamento','urgência','financeiro','agendar avaliação','outro assunto')) as tags;
