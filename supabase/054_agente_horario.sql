-- 054: horário de funcionamento do agente de IA (29/10/2026)
-- Pedido do Lucas:
--   segunda a sexta: 17h10 às 22h15
--   sábado:          14h10 às 22h15
--   domingo:         8h às 22h15
-- Fora do horário a IA não liga em conversas novas nem responde: a conversa fica com a
-- equipe (e a "Primeira mensagem" automática de 5 min funciona normalmente até 22h15).
-- O que já estava na fila antes do fechamento ainda é respondido.
-- Para mudar: update public.agente_ia set horarios = '{...}' where id = 1;
--   chaves = dia da semana (0 = domingo ... 6 = sábado), valor = ["HH:MM","HH:MM"].
--   Dia sem chave = IA não funciona nesse dia. horarios nulo = sem restrição.
--
-- Substitui o rascunho da "pausa noturna" (22h15 às 8h) aplicado mais cedo no mesmo dia.

drop trigger if exists t_agente_fila_pausa on public.agente_fila;
drop function if exists public.agente_t_fila_pausa();
drop function if exists public.agente_em_pausa();
alter table public.agente_ia drop column if exists pausa_inicio;
alter table public.agente_ia drop column if exists pausa_fim;

alter table public.agente_ia add column if not exists horarios jsonb;
update public.agente_ia set horarios = '{
  "0": ["08:00", "22:15"],
  "1": ["17:10", "22:15"],
  "2": ["17:10", "22:15"],
  "3": ["17:10", "22:15"],
  "4": ["17:10", "22:15"],
  "5": ["17:10", "22:15"],
  "6": ["14:10", "22:15"]
}'::jsonb where id = 1;

create or replace function public.agente_no_horario(p_quando timestamptz default now()) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((
    select case
      when a.horarios is null then true
      when a.horarios -> extract(dow from (p_quando at time zone 'America/Sao_Paulo'))::int::text is null then false
      else (p_quando at time zone 'America/Sao_Paulo')::time
             >= (a.horarios -> extract(dow from (p_quando at time zone 'America/Sao_Paulo'))::int::text ->> 0)::time
       and (p_quando at time zone 'America/Sao_Paulo')::time
             <  (a.horarios -> extract(dow from (p_quando at time zone 'America/Sao_Paulo'))::int::text ->> 1)::time
    end
    from public.agente_ia a where a.id = 1), true);
$$;
grant execute on function public.agente_no_horario(timestamptz) to authenticated;

-- mesma função de antes (versão em produção, com o filtro do Instagram) + o horário
create or replace function public.agente_t_mensagem() returns trigger
language plpgsql security definer set search_path = public, migracao, pg_temp as $$
declare a public.agente_ia; c public.conversas; v_cria boolean;
begin
  if new.direcao = 'enviada' then
    -- alguém da equipe respondeu (pelo CRM ou pelo celular): o robô sai dessa conversa
    if (coalesce(new.canal, 'crm') = 'crm' and exists (select 1 from public.equipe e where e.email = new.autor_email))
       or new.canal = 'celular' then
      update public.conversas set robo_ligado = false where id = new.conversa_id and robo_ligado;
      delete from public.agente_fila where conversa_id = new.conversa_id;
    end if;
    return null;
  end if;

  if coalesce(new.canal, 'paciente') <> 'paciente' or new.enviada_em < now() - interval '10 minutes' then return null; end if;
  select * into a from public.agente_ia where id = 1;
  if a.id is null or not a.habilitar_ia then return null; end if;
  -- (29/10/2026) fora do horário da IA: não liga o robô nem entra na fila
  if not public.agente_no_horario(now()) then return null; end if;
  select * into c from public.conversas where id = new.conversa_id;
  if c.id is null or c.canal = 'instagram' then return null; end if;
  if a.modo_teste and not (c.telefone = any (array(select migracao.tel(t) from unnest(a.telefones_teste) t))) then return null; end if;

  if not c.robo_ligado then
    -- conversa nova: o robô começa ligado (só nos números que criam lead)
    select n.cria_leads into v_cria from public.whatsapp_numeros n where n.phone_number_id = c.numero_clinica_id;
    if a.ligar_em_novas and v_cria is not false
       and not exists (select 1 from public.mensagens m where m.conversa_id = c.id and m.id <> new.id) then
      update public.conversas set robo_ligado = true where id = c.id;
    else
      return null;
    end if;
  end if;

  insert into public.agente_fila (conversa_id, responder_em, versao, status)
  values (c.id, now() + make_interval(secs => a.espera_segundos), 1, 'pendente')
  on conflict (conversa_id) do update
    set responder_em = excluded.responder_em, versao = agente_fila.versao + 1, status = 'pendente', pego_em = null;
  return null;
exception when others then
  insert into public.espelho_erros (origem, erro, detalhe) values ('agente_t_mensagem', sqlerrm, new.conversa_id::text);
  return null;
end $$;

-- a IA fica habilitada; quem decide se responde agora é o horário
update public.agente_ia set habilitar_ia = true where id = 1;

-- "Primeira mensagem (5 min sem resposta)": só das 8h às 22h15. Fora disso não sai
-- (nem fica guardada para a manhã): regra nova fora_do_horario = "pular" no motor.
update public.automacoes
   set regras = regras || '{"inicio":"08:00","fim":"22:15","pular_fim_de_semana":false,"fora_do_horario":"pular"}'::jsonb
 where id = 15;

select public.agente_no_horario(now()) as ia_no_horario_agora,
       (select horarios from public.agente_ia where id = 1) as horarios,
       (select regras from public.automacoes where id = 15) as regras_primeira_msg;
