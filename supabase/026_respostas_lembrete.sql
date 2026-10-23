-- ============================================================
-- CRM Bulhões — Respostas aos lembretes de consulta (23/10/2026)
-- Como no Cloudia (tags "confirmou lembrete" e "cancelar consulta"):
-- quando o paciente responde a um lembrete enviado nos últimos 3 dias,
--   • "Confirmar" (botão do modelo ou resposta curta como "sim", "confirmo"):
--     confirma a consulta no Clinicorp, põe a tag "confirmou lembrete" e
--     manda a mensagem de agradecimento (configurável).
--   • "Cancelar"/"Remarcar"/"desmarcar"/"não vou conseguir": põe a tag
--     "cancelar consulta", desliga o robô e manda a conversa para a fila da
--     equipe remarcar (não desmarca nada sozinho no Clinicorp).
-- Qualquer outra mensagem segue o atendimento normal.
-- O motor (whatsapp-automacoes) processa a cada minuto.
-- Rodar no Supabase: SQL Editor → New query → colar tudo → Run.
-- ============================================================
alter table public.lembretes_consulta add column if not exists resposta text check (resposta in ('confirmou', 'cancelar'));
alter table public.lembretes_consulta add column if not exists respondido_em timestamptz;
alter table public.lembretes_consulta add column if not exists confirmado_no_clinicorp boolean;

create table if not exists public.lembrete_respostas (
  id           bigint generated always as identity primary key,
  mensagem_id  uuid not null unique references public.mensagens(id) on delete cascade,
  conversa_id  uuid not null references public.conversas(id) on delete cascade,
  lembrete_id  bigint not null references public.lembretes_consulta(id) on delete cascade,
  acao         text not null check (acao in ('confirmar', 'cancelar')),
  status       text not null default 'pendente' check (status in ('pendente', 'processando', 'feito', 'erro')),
  erro         text,
  criado_em    timestamptz not null default now(),
  feito_em     timestamptz
);
alter table public.lembrete_respostas enable row level security;
revoke all on public.lembrete_respostas from anon, authenticated;
grant select on public.lembrete_respostas to authenticated;
drop policy if exists lembrete_respostas_ver on public.lembrete_respostas;
create policy lembrete_respostas_ver on public.lembrete_respostas for select to authenticated
  using (public.tem_papel('gestao', 'avaliacao', 'comercial'));

-- textos e tags (a gestão muda na tela de lembretes)
update public.configuracoes
   set valor = jsonb_build_object(
         'confirmar_no_clinicorp', true,
         'resposta_confirmou', 'Perfeito, sua presença está confirmada. Até breve! 💙',
         'resposta_cancelar', 'Tudo bem! Vou pedir para a nossa equipe te ajudar a encontrar um novo horário.',
         'tag_confirmou', 'confirmou lembrete',
         'tag_cancelar', 'cancelar consulta') || valor
 where chave = 'lembretes_consulta';

-- o que a resposta quer dizer (null = não é resposta ao lembrete)
create or replace function public.lembrete_classificar(p_tipo text, p_texto text)
returns text
language plpgsql immutable as $$
declare t text := lower(btrim(coalesce(p_texto, '')));
begin
  t := translate(t, 'áàâãéêíóôõúç', 'aaaaeeiooouc');
  if t = '' then return null; end if;
  -- botão do modelo: o texto do botão decide
  if p_tipo in ('button', 'interactive') then
    if t ~ '(cancel|desmarc|remarc|reagend|nao (vou|posso|consigo|poderei))' then return 'cancelar'; end if;
    if t ~ '(confirm|sim|estarei|vou sim|presenca|ok)' then return 'confirmar'; end if;
    return null;
  end if;
  -- texto livre: só pedidos claros
  if t ~ '(desmarc|cancel|remarc|reagend|nao (vou|posso|consigo|poderei|vai dar)|preciso (mudar|trocar) o horario)' then return 'cancelar'; end if;
  if t ~ '^(sim|ss|confirmo|confirmado|confirmada|confirmar|confirmadissimo|ok|okay|pode confirmar|confirmo sim|sim,? confirmo|sim,? estarei( ai| la)?|estarei( ai| la)?|combinado|certo|👍|✅)[ !.,💙❤️🙏😊👍✅]*$' then return 'confirmar'; end if;
  return null;
end $$;

create or replace function public.lembrete_t_resposta() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare c public.conversas; l public.lembretes_consulta; v_acao text;
begin
  if new.direcao <> 'recebida' or coalesce(new.canal, 'paciente') <> 'paciente' or new.enviada_em < now() - interval '1 day' then return null; end if;
  v_acao := public.lembrete_classificar(new.tipo, new.texto);
  if v_acao is null then return null; end if;
  select * into c from public.conversas where id = new.conversa_id;
  if c.id is null then return null; end if;
  select * into l from public.lembretes_consulta x
   where x.telefone = c.telefone and x.status = 'enviado'
     and x.enviado_em > now() - interval '3 days'
     and x.data >= (now() at time zone 'America/Sao_Paulo')::date
   order by x.enviado_em desc limit 1;
  if l.id is null then return null; end if;
  if v_acao = 'confirmar' and l.resposta = 'confirmou' then return null; end if;   -- já confirmou
  insert into public.lembrete_respostas (mensagem_id, conversa_id, lembrete_id, acao)
  values (new.id, c.id, l.id, v_acao) on conflict (mensagem_id) do nothing;
  -- quem responde é a resposta do lembrete: o Agente de IA não responde por cima
  delete from public.agente_fila where conversa_id = c.id;
  -- pediu para cancelar: o robô não responde por cima, a equipe assume
  if v_acao = 'cancelar' then
    update public.conversas set robo_ligado = false where id = c.id and robo_ligado;
  end if;
  return null;
exception when others then
  insert into public.espelho_erros (origem, erro, detalhe) values ('lembrete_t_resposta', sqlerrm, new.conversa_id::text);
  return null;
end $$;
drop trigger if exists t_lembrete_resposta on public.mensagens;
create trigger t_lembrete_resposta after insert on public.mensagens
  for each row execute function public.lembrete_t_resposta();

-- motor
create or replace function public.lembrete_respostas_pegar()
returns table (id bigint, conversa_id uuid, acao text, lembrete_id bigint, clinicorp_id text, telefone text, data date, hora text)
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  update public.lembrete_respostas set status = 'pendente' where status = 'processando' and criado_em < now() - interval '10 minutes';
  return query
  with x as (
    update public.lembrete_respostas r set status = 'processando'
     where r.id in (select y.id from public.lembrete_respostas y where y.status = 'pendente' order by y.id limit 20 for update skip locked)
    returning r.*)
  select x.id, x.conversa_id, x.acao, x.lembrete_id, l.clinicorp_id, l.telefone, l.data, l.hora
    from x join public.lembretes_consulta l on l.id = x.lembrete_id;
end $$;

create or replace function public.lembrete_resposta_feita(p_id bigint, p_ok boolean, p_erro text, p_confirmado boolean)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare r public.lembrete_respostas;
begin
  update public.lembrete_respostas set status = case when p_ok then 'feito' else 'erro' end, erro = p_erro, feito_em = now()
   where id = p_id returning * into r;
  if r.id is null then return; end if;
  update public.lembretes_consulta
     set resposta = case r.acao when 'confirmar' then 'confirmou' else 'cancelar' end,
         respondido_em = now(),
         confirmado_no_clinicorp = coalesce(p_confirmado, confirmado_no_clinicorp)
   where id = r.lembrete_id;
end $$;

revoke all on function public.lembrete_respostas_pegar() from public, anon, authenticated;
revoke all on function public.lembrete_resposta_feita(bigint, boolean, text, boolean) from public, anon, authenticated;
revoke all on function public.lembrete_t_resposta() from public, anon, authenticated;
grant execute on function public.lembrete_respostas_pegar() to service_role;
grant execute on function public.lembrete_resposta_feita(bigint, boolean, text, boolean) to service_role;

select 'respostas aos lembretes prontas' as status;
