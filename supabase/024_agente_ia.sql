-- ============================================================
-- CRM Bulhões — Agente de IA (22/10/2026)
--
-- Como no Cloudia (Agentes de IA → Agente Padrão): a gestão escreve as
-- instruções e a base de conhecimento, escolhe modelo, criatividade e
-- personalidade, e liga três coisas separadas:
--   • Habilitar IA: o agente responde sozinho as conversas com o robô ligado.
--   • Assistente Virtual: sugestão de resposta para a equipe na Central.
--   • Resumos: "Resumir com IA" na Central.
-- Imagens (ex.: antes e depois por queixa) ficam numa lista com "quando usar";
-- o agente escolhe e envia. Ele também passa a conversa para a equipe
-- (desliga o robô daquela conversa) quando as instruções mandarem.
--
-- Como a resposta acontece:
--   1. Chega mensagem do paciente numa conversa com o robô ligado → entra na
--      fila (agente_fila) para responder depois de "espera_segundos". Se ele
--      mandar outra mensagem antes, a espera recomeça (responde tudo junto).
--   2. A função whatsapp-agente (chamada pelo webhook na hora e pelo agendador
--      a cada minuto, como reserva) pega a fila e responde.
--   3. Quando alguém da equipe responde a conversa (CRM ou celular), o robô
--      daquela conversa desliga: a pessoa assumiu.
-- Conversa nova: com "ligar_em_novas", o robô já começa ligado na primeira
-- mensagem de um contato (só nos números que criam lead).
-- Modo teste: só os telefones de teste recebem resposta automática.
-- Chave da Anthropic: segredo ANTHROPIC_API_KEY na Supabase.
-- Rodar no Supabase: SQL Editor → New query → colar tudo → Run.
-- ============================================================

create table if not exists public.agente_ia (
  id                  integer primary key default 1 check (id = 1),
  nome                text not null default 'Agente Padrão',
  habilitar_ia        boolean not null default false,
  assistente_virtual  boolean not null default false,
  resumos             boolean not null default false,
  modelo              text not null default 'claude-sonnet-5-5',
  criatividade        numeric(3, 2) not null default 0.7 check (criatividade between 0 and 1),
  personalidade       text not null default 'Empático',
  instrucoes          text not null default '',
  base_conhecimento   text not null default '',
  espera_segundos     integer not null default 10 check (espera_segundos between 0 and 120),
  max_blocos          integer not null default 4 check (max_blocos between 1 and 10),
  ligar_em_novas      boolean not null default true,
  modo_teste          boolean not null default true,
  telefones_teste     text[] not null default '{}',
  atualizado_em       timestamptz not null default now(),
  atualizado_por      text default public.email_atual()
);
insert into public.agente_ia (id) values (1) on conflict (id) do nothing;

-- histórico das instruções e da base (como as "versões" do Cloudia)
create table if not exists public.agente_versoes (
  id                 bigint generated always as identity primary key,
  instrucoes         text,
  base_conhecimento  text,
  salva_em           timestamptz not null default now(),
  salva_por          text
);

create table if not exists public.agente_imagens (
  id          bigint generated always as identity primary key,
  nome        text not null check (length(btrim(nome)) between 1 and 80),
  quando_usar text not null default '',
  link        text not null check (link ~ '^https://'),
  ordem       integer not null default 0,
  criada_em   timestamptz not null default now()
);

create table if not exists public.agente_fila (
  conversa_id   uuid primary key references public.conversas(id) on delete cascade,
  responder_em  timestamptz not null,
  versao        integer not null default 1,
  status        text not null default 'pendente' check (status in ('pendente', 'processando')),
  pego_em       timestamptz
);
create index if not exists agente_fila_vencidas on public.agente_fila (responder_em) where status = 'pendente';

create table if not exists public.agente_registros (
  id               bigint generated always as identity primary key,
  conversa_id      uuid references public.conversas(id) on delete cascade,
  tipo             text not null check (tipo in ('resposta', 'transferencia', 'sugestao', 'resumo', 'teste', 'erro')),
  detalhe          text,
  modelo           text,
  tokens_entrada   integer,
  tokens_saida     integer,
  autor            text,
  criado_em        timestamptz not null default now()
);
create index if not exists agente_registros_conversa on public.agente_registros (conversa_id, criado_em desc);
create index if not exists agente_registros_data on public.agente_registros (criado_em desc);

alter table public.conversas add column if not exists resumo_ia text;
alter table public.conversas add column if not exists resumo_ia_em timestamptz;

-- ------------------------------------------------------------
-- Permissões
-- ------------------------------------------------------------
alter table public.agente_ia enable row level security;
alter table public.agente_versoes enable row level security;
alter table public.agente_imagens enable row level security;
alter table public.agente_fila enable row level security;
alter table public.agente_registros enable row level security;
revoke all on public.agente_ia, public.agente_versoes, public.agente_imagens, public.agente_fila, public.agente_registros from anon, authenticated;

grant select on public.agente_ia, public.agente_versoes, public.agente_imagens, public.agente_registros to authenticated;
grant update (nome, habilitar_ia, assistente_virtual, resumos, modelo, criatividade, personalidade, instrucoes,
              base_conhecimento, espera_segundos, max_blocos, ligar_em_novas, modo_teste, telefones_teste)
  on public.agente_ia to authenticated;
grant insert, delete on public.agente_imagens to authenticated;
grant update (nome, quando_usar, link, ordem) on public.agente_imagens to authenticated;

drop policy if exists agente_ver on public.agente_ia;
create policy agente_ver on public.agente_ia for select to authenticated using (public.tem_papel('gestao', 'avaliacao', 'comercial'));
drop policy if exists agente_editar on public.agente_ia;
create policy agente_editar on public.agente_ia for update to authenticated using (public.tem_papel('gestao')) with check (public.tem_papel('gestao'));
drop policy if exists agente_versoes_ver on public.agente_versoes;
create policy agente_versoes_ver on public.agente_versoes for select to authenticated using (public.tem_papel('gestao'));
drop policy if exists agente_imagens_ver on public.agente_imagens;
create policy agente_imagens_ver on public.agente_imagens for select to authenticated using (public.tem_papel('gestao', 'avaliacao', 'comercial'));
drop policy if exists agente_imagens_gestao on public.agente_imagens;
create policy agente_imagens_gestao on public.agente_imagens for all to authenticated using (public.tem_papel('gestao')) with check (public.tem_papel('gestao'));
drop policy if exists agente_registros_ver on public.agente_registros;
create policy agente_registros_ver on public.agente_registros for select to authenticated using (public.tem_papel('gestao', 'avaliacao', 'comercial'));

-- quem salvou e quando; guarda a versão anterior das instruções/base
create or replace function public.agente_t_salvar() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  new.atualizado_em := now();
  new.atualizado_por := coalesce(nullif(public.email_atual(), ''), new.atualizado_por);
  if new.instrucoes is distinct from old.instrucoes or new.base_conhecimento is distinct from old.base_conhecimento then
    insert into public.agente_versoes (instrucoes, base_conhecimento, salva_por)
    values (old.instrucoes, old.base_conhecimento, old.atualizado_por);
  end if;
  return new;
end $$;
drop trigger if exists t_agente_salvar on public.agente_ia;
create trigger t_agente_salvar before update on public.agente_ia for each row execute function public.agente_t_salvar();

-- ------------------------------------------------------------
-- Mensagens → fila do agente / equipe assumiu
-- ------------------------------------------------------------
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
  select * into c from public.conversas where id = new.conversa_id;
  if c.id is null then return null; end if;
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
drop trigger if exists t_agente_mensagem on public.mensagens;
create trigger t_agente_mensagem after insert on public.mensagens
  for each row execute function public.agente_t_mensagem();

-- robô desligado à mão: sai da fila
create or replace function public.agente_t_robo() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not new.robo_ligado then delete from public.agente_fila where conversa_id = new.id; end if;
  return null;
end $$;
drop trigger if exists t_agente_robo on public.conversas;
create trigger t_agente_robo after update of robo_ligado on public.conversas
  for each row when (old.robo_ligado and not new.robo_ligado) execute function public.agente_t_robo();

-- ------------------------------------------------------------
-- Funções da função whatsapp-agente (só o servidor chama)
-- ------------------------------------------------------------
-- conversas prontas para responder (marca "processando"); destrava as presas há mais de 3 min
create or replace function public.agente_pegar(p_limite integer default 10)
returns table (conversa_id uuid, versao integer)
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  update public.agente_fila set status = 'pendente', pego_em = null
   where status = 'processando' and pego_em < now() - interval '3 minutes';
  return query
  update public.agente_fila f set status = 'processando', pego_em = now()
   where f.conversa_id in (select x.conversa_id from public.agente_fila x
                            where x.status = 'pendente' and x.responder_em <= now()
                            order by x.responder_em limit p_limite for update skip locked)
  returning f.conversa_id, f.versao;
end $$;

-- próxima resposta prevista (para a função esperar sem gastar chamadas)
create or replace function public.agente_proxima()
returns timestamptz
language sql stable security definer set search_path = public, pg_temp as $$
  select min(responder_em) from public.agente_fila where status = 'pendente';
$$;

-- a versão ainda é a mesma? (se o paciente mandou mais coisa, a resposta é refeita)
create or replace function public.agente_versao(p_conversa uuid)
returns integer
language sql stable security definer set search_path = public, pg_temp as $$
  select versao from public.agente_fila where conversa_id = p_conversa;
$$;

-- terminou: sai da fila (se chegou mensagem nova no meio, volta para pendente)
create or replace function public.agente_concluir(p_conversa uuid, p_versao integer)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  delete from public.agente_fila where conversa_id = p_conversa and versao = p_versao;
  update public.agente_fila set status = 'pendente', pego_em = null where conversa_id = p_conversa and versao <> p_versao;
end $$;

-- passa para a equipe: desliga o robô da conversa e coloca na fila de atendimento
create or replace function public.agente_transferir(p_conversa uuid, p_motivo text)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  update public.conversas set robo_ligado = false, status = 'aberta', nao_lidas = greatest(nao_lidas, 1) where id = p_conversa;
  delete from public.agente_fila where conversa_id = p_conversa;
  insert into public.agente_registros (conversa_id, tipo, detalhe, autor) values (p_conversa, 'transferencia', left(p_motivo, 500), 'agente');
end $$;

revoke all on function public.agente_pegar(integer) from public, anon, authenticated;
revoke all on function public.agente_proxima() from public, anon, authenticated;
revoke all on function public.agente_versao(uuid) from public, anon, authenticated;
revoke all on function public.agente_concluir(uuid, integer) from public, anon, authenticated;
revoke all on function public.agente_transferir(uuid, text) from public, anon, authenticated;
revoke all on function public.agente_t_mensagem() from public, anon, authenticated;
revoke all on function public.agente_t_robo() from public, anon, authenticated;
revoke all on function public.agente_t_salvar() from public, anon, authenticated;
grant execute on function public.agente_pegar(integer) to service_role;
grant execute on function public.agente_proxima() to service_role;
grant execute on function public.agente_versao(uuid) to service_role;
grant execute on function public.agente_concluir(uuid, integer) to service_role;
grant execute on function public.agente_transferir(uuid, text) to service_role;

do $$ begin
  alter publication supabase_realtime add table public.agente_registros;
exception when duplicate_object then null; when undefined_object then null; end $$;

-- ------------------------------------------------------------
-- Agendador (reserva): confere a fila a cada minuto.
-- Rodar DEPOIS de publicar a função whatsapp-agente (Verify JWT desligado).
-- ------------------------------------------------------------
do $$ begin
  perform cron.unschedule('agente-fila');
exception when others then null; end $$;
do $$ begin
  perform cron.schedule('agente-fila', '* * * * *', $cron$
    select net.http_post(
      url := 'https://gcxuikfjyajlmqbqlyca.supabase.co/functions/v1/whatsapp-agente',
      headers := jsonb_build_object('Content-Type', 'application/json',
                                    'x-motor-chave', (select chave from public.automacao_segredo where id = 1)),
      body := '{"acao":"fila"}'::jsonb,
      timeout_milliseconds := 60000)
    where exists (select 1 from public.agente_fila);
  $cron$);
exception when undefined_function or invalid_schema_name then null; end $$;

select 'agente de IA pronto (desligado até a gestão ligar)' as status;
