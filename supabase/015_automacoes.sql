-- ============================================================
-- CRM Bulhões — Automações (motor das sequências)  22/10/2026
--
-- O que tem aqui:
--   • automacoes: cada automação criada na tela "Automações" do CRM
--     (gatilho, regras e passos).
--   • automacao_execucoes: cada contato dentro de uma automação, em qual
--     passo está e quando roda o próximo.
--   • automacao_log: o histórico de tudo que o motor fez (para conferir).
--   • Gatilhos no banco que colocam o contato na automação quando:
--       a etapa muda, uma tag entra ou sai, o paciente manda mensagem,
--       ou um lead novo é criado.
--   • Funções que o motor (função whatsapp-automacoes) usa para pegar os
--     passos vencidos sem que dois motores peguem o mesmo contato.
--
-- Segurança: tudo nasce DESLIGADO.
--   • chave geral: configuracoes 'automacoes_ligadas' = false
--   • cada automação nasce com ligada = false e modo_teste = true
--     (no modo teste, só os telefones da lista de teste entram).
--
-- Rodar no Supabase: SQL Editor → New query → colar tudo → Run.
-- Pode rodar mais de uma vez sem problema.
-- ============================================================

insert into public.configuracoes (chave, valor, atualizado_por)
values ('automacoes_ligadas', 'false'::jsonb, 'migracao')
on conflict (chave) do nothing;

create or replace function public.automacoes_ligadas() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select valor = 'true'::jsonb from public.configuracoes where chave = 'automacoes_ligadas'), false);
$$;

-- ------------------------------------------------------------
-- Automações
-- gatilho (jsonb):
--   {"tipo":"etapa","etapa":"Lead"}
--   {"tipo":"tag_adicionada","tag_id":3}      {"tipo":"tag_removida","tag_id":3}
--   {"tipo":"mensagem_recebida","palavras":["preço","valor"]}   (sem palavras = qualquer mensagem)
--   {"tipo":"lead_criado","origem":"#Instagram ADS"}            (sem origem = qualquer)
--   {"tipo":"manual"}                                            (só entra quem a equipe colocar)
-- regras (jsonb):
--   {"inicio":"11:00","fim":"17:00","pular_fim_de_semana":true,
--    "sair_se_responder":true,"reentrada":"depois_de_sair"}   (nunca | depois_de_sair | sempre)
-- passos (jsonb, lista em ordem):
--   {"tipo":"esperar","minutos":120}
--   {"tipo":"texto","texto":"Oi {primeiro_nome}…"}
--   {"tipo":"modelo","nome":"fup24hrs","idioma":"pt_BR","variaveis":{"1":"{primeiro_nome}"},"cabecalho":{"formato":"IMAGE","link":"https://…"}}
--   {"tipo":"por_tag","tag_id":3}   {"tipo":"tirar_tag","tag_id":3}
--   {"tipo":"atribuir","email":"raffaella@…"}
--   {"tipo":"se","condicao":{"tipo":"tem_tag","tag_id":3} | {"tipo":"etapa","etapa":"Lead"} | {"tipo":"respondeu"},
--    "senao":"fim" | número do passo (1, 2, 3…)}
--   {"tipo":"fim"}
-- ------------------------------------------------------------
create table if not exists public.automacoes (
  id                 bigint generated always as identity primary key,
  nome               text not null check (length(btrim(nome)) between 1 and 80),
  descricao          text,
  ligada             boolean not null default false,
  modo_teste         boolean not null default true,
  telefones_teste    text[] not null default '{}',
  gatilho            jsonb not null default '{"tipo":"manual"}'::jsonb,
  regras             jsonb not null default '{"inicio":"11:00","fim":"17:00","pular_fim_de_semana":true,"sair_se_responder":true,"reentrada":"depois_de_sair"}'::jsonb,
  passos             jsonb not null default '[]'::jsonb check (jsonb_typeof(passos) = 'array'),
  numero_clinica_id  text,                -- de qual número envia (vazio = número principal)
  criada_em          timestamptz not null default now(),
  criada_por         text default public.email_atual(),
  atualizada_em      timestamptz not null default now(),
  atualizada_por     text default public.email_atual()
);

create table if not exists public.automacao_execucoes (
  id             bigint generated always as identity primary key,
  automacao_id   bigint not null references public.automacoes(id) on delete cascade,
  telefone       text not null,
  conversa_id    uuid references public.conversas(id) on delete set null,
  passo          integer not null default 0,         -- índice do próximo passo (0 = primeiro)
  status         text not null default 'ativa'
                 check (status in ('ativa', 'concluida', 'saiu', 'cancelada', 'erro')),
  motivo         text,                               -- por que saiu/cancelou/deu erro
  proxima_em     timestamptz not null default now(),
  trava_ate      timestamptz,                        -- motor trabalhando nela
  entrou_em      timestamptz not null default now(),
  terminou_em    timestamptz,
  entrou_por     text,                               -- gatilho, ou e-mail de quem colocou
  contexto       jsonb not null default '{}'::jsonb
);
create unique index if not exists automacao_exec_uma_ativa
  on public.automacao_execucoes (automacao_id, telefone) where status = 'ativa';
create index if not exists automacao_exec_vencidas
  on public.automacao_execucoes (proxima_em) where status = 'ativa';
create index if not exists automacao_exec_telefone on public.automacao_execucoes (telefone, status);

create table if not exists public.automacao_log (
  id            bigint generated always as identity primary key,
  quando        timestamptz not null default now(),
  automacao_id  bigint references public.automacoes(id) on delete cascade,
  execucao_id   bigint references public.automacao_execucoes(id) on delete cascade,
  telefone      text,
  passo         integer,
  acao          text not null,                       -- entrou, esperar, texto, modelo, por_tag, …, saiu, erro
  resultado     text not null default 'ok' check (resultado in ('ok', 'erro', 'pulado', 'adiado')),
  detalhe       text
);
create index if not exists automacao_log_auto on public.automacao_log (automacao_id, quando desc);
create index if not exists automacao_log_exec on public.automacao_log (execucao_id, quando);

-- ------------------------------------------------------------
-- Permissões: equipe vê; gestão e comercial criam e editam
-- ------------------------------------------------------------
alter table public.automacoes enable row level security;
alter table public.automacao_execucoes enable row level security;
alter table public.automacao_log enable row level security;
revoke all on public.automacoes, public.automacao_execucoes, public.automacao_log from anon;
grant select, insert, delete on public.automacoes to authenticated;
grant update (nome, descricao, ligada, modo_teste, telefones_teste, gatilho, regras, passos, numero_clinica_id, atualizada_em, atualizada_por)
  on public.automacoes to authenticated;
grant select on public.automacao_execucoes, public.automacao_log to authenticated;
grant update (status, motivo, terminou_em) on public.automacao_execucoes to authenticated;

drop policy if exists automacoes_ver on public.automacoes;
create policy automacoes_ver on public.automacoes for select to authenticated
  using (public.tem_papel('gestao', 'avaliacao', 'comercial'));
drop policy if exists automacoes_criar on public.automacoes;
create policy automacoes_criar on public.automacoes for insert to authenticated
  with check (public.tem_papel('gestao', 'comercial'));
drop policy if exists automacoes_editar on public.automacoes;
create policy automacoes_editar on public.automacoes for update to authenticated
  using (public.tem_papel('gestao', 'comercial')) with check (public.tem_papel('gestao', 'comercial'));
drop policy if exists automacoes_apagar on public.automacoes;
create policy automacoes_apagar on public.automacoes for delete to authenticated
  using (public.tem_papel('gestao'));

drop policy if exists automacao_exec_ver on public.automacao_execucoes;
create policy automacao_exec_ver on public.automacao_execucoes for select to authenticated
  using (public.tem_papel('gestao', 'avaliacao', 'comercial'));
-- a equipe só pode tirar alguém da automação (status cancelada)
drop policy if exists automacao_exec_cancelar on public.automacao_execucoes;
create policy automacao_exec_cancelar on public.automacao_execucoes for update to authenticated
  using (public.tem_papel('gestao', 'comercial') and status = 'ativa')
  with check (status = 'cancelada');

drop policy if exists automacao_log_ver on public.automacao_log;
create policy automacao_log_ver on public.automacao_log for select to authenticated
  using (public.tem_papel('gestao', 'avaliacao', 'comercial'));

-- atualizada_em/atualizada_por sozinhos
create or replace function public.automacoes_tocar() returns trigger
language plpgsql as $$
begin new.atualizada_em := now(); new.atualizada_por := coalesce(public.email_atual(), new.atualizada_por); return new; end $$;
drop trigger if exists t_automacoes_tocar on public.automacoes;
create trigger t_automacoes_tocar before update on public.automacoes
  for each row execute function public.automacoes_tocar();

-- ------------------------------------------------------------
-- Colocar um telefone numa automação (respeita teste, reentrada e chave geral)
-- ------------------------------------------------------------
create or replace function public.automacao_entrar(p_auto bigint, p_telefone text, p_por text, p_contexto jsonb default '{}'::jsonb, p_forcar boolean default false)
returns bigint
language plpgsql security definer set search_path = public, migracao, pg_temp as $$
declare a public.automacoes; v_tel text := migracao.tel(p_telefone); v_id bigint; v_reent text; v_conv uuid;
begin
  if v_tel is null then return null; end if;
  select * into a from public.automacoes where id = p_auto;
  if not found then return null; end if;
  if not p_forcar then
    if not a.ligada or not public.automacoes_ligadas() then return null; end if;
    if a.modo_teste and not (v_tel = any (array(select migracao.tel(t) from unnest(a.telefones_teste) t))) then return null; end if;
  end if;
  if jsonb_array_length(a.passos) = 0 then return null; end if;
  -- já está ativa nesta automação: não entra de novo
  if exists (select 1 from public.automacao_execucoes where automacao_id = a.id and telefone = v_tel and status = 'ativa') then return null; end if;
  v_reent := coalesce(a.regras->>'reentrada', 'depois_de_sair');
  if v_reent = 'nunca' and exists (select 1 from public.automacao_execucoes where automacao_id = a.id and telefone = v_tel) then return null; end if;
  select c.id into v_conv from public.conversas c
   where c.telefone = v_tel and (a.numero_clinica_id is null or c.numero_clinica_id = a.numero_clinica_id)
   order by c.ultima_mensagem_em desc nulls last limit 1;
  insert into public.automacao_execucoes (automacao_id, telefone, conversa_id, entrou_por, contexto)
  values (a.id, v_tel, v_conv, p_por, coalesce(p_contexto, '{}'::jsonb))
  on conflict do nothing
  returning id into v_id;
  if v_id is not null then
    insert into public.automacao_log (automacao_id, execucao_id, telefone, passo, acao, detalhe)
    values (a.id, v_id, v_tel, 0, 'entrou', p_por);
  end if;
  return v_id;
end $$;

-- a equipe coloca alguém numa automação pela tela (só entra se a automação estiver ligada ou em teste com o número na lista)
create or replace function public.automacao_colocar(p_auto bigint, p_telefone text)
returns bigint
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not public.tem_papel('gestao', 'comercial') then raise exception 'sem permissão'; end if;
  return public.automacao_entrar(p_auto, p_telefone, 'manual: ' || coalesce(public.email_atual(), '?'));
end $$;

-- Dispara todas as automações ligadas de um tipo de gatilho
create or replace function public.automacao_disparar(p_tipo text, p_telefone text, p_dados jsonb)
returns integer
language plpgsql security definer set search_path = public, pg_temp as $$
declare a record; n integer := 0; ok boolean;
begin
  if not public.automacoes_ligadas() then return 0; end if;
  for a in select * from public.automacoes where ligada and gatilho->>'tipo' = p_tipo loop
    ok := case p_tipo
      when 'etapa' then coalesce(a.gatilho->>'etapa', '') = coalesce(p_dados->>'etapa', '')
      when 'tag_adicionada' then (a.gatilho->>'tag_id') = (p_dados->>'tag_id')
      when 'tag_removida' then (a.gatilho->>'tag_id') = (p_dados->>'tag_id')
      when 'lead_criado' then coalesce(a.gatilho->>'origem', '') in ('', coalesce(p_dados->>'origem', ''))
      when 'mensagem_recebida' then
        jsonb_array_length(coalesce(a.gatilho->'palavras', '[]'::jsonb)) = 0
        or exists (select 1 from jsonb_array_elements_text(a.gatilho->'palavras') w
                   where length(btrim(w)) > 0
                     and lower(coalesce(p_dados->>'texto', '')) like '%' || lower(btrim(w)) || '%')
      else false end;
    if ok and public.automacao_entrar(a.id, p_telefone, 'gatilho: ' || p_tipo, p_dados) is not null then n := n + 1; end if;
  end loop;
  return n;
exception when others then
  insert into public.espelho_erros (origem, erro, detalhe) values ('automacao_disparar', sqlerrm, p_tipo || ' ' || coalesce(p_telefone, ''));
  return 0;
end $$;

-- ------------------------------------------------------------
-- Gatilhos no banco (nunca travam a gravação original)
-- ------------------------------------------------------------
create or replace function public.automacao_t_pacientes() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not public.automacoes_ligadas() then return new; end if;
  if tg_op = 'INSERT' then
    perform public.automacao_disparar('lead_criado', new.telefone, jsonb_build_object('origem', new.origem, 'etapa', new.etapa));
    if new.etapa is not null then
      perform public.automacao_disparar('etapa', new.telefone, jsonb_build_object('etapa', new.etapa, 'antes', null));
    end if;
  elsif new.etapa is distinct from old.etapa and new.etapa is not null then
    perform public.automacao_disparar('etapa', new.telefone, jsonb_build_object('etapa', new.etapa, 'antes', old.etapa));
  end if;
  return new;
exception when others then
  insert into public.espelho_erros (origem, erro, detalhe) values ('automacao_t_pacientes', sqlerrm, new.telefone);
  return new;
end $$;
drop trigger if exists t_automacao_pacientes on public.pacientes;
create trigger t_automacao_pacientes after insert or update of etapa on public.pacientes
  for each row execute function public.automacao_t_pacientes();

create or replace function public.automacao_t_tags() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_tel text;
begin
  if not public.automacoes_ligadas() then return null; end if;
  if tg_op = 'INSERT' then
    select telefone into v_tel from public.conversas where id = new.conversa_id;
    if v_tel is not null then perform public.automacao_disparar('tag_adicionada', v_tel, jsonb_build_object('tag_id', new.tag_id)); end if;
  else
    select telefone into v_tel from public.conversas where id = old.conversa_id;
    if v_tel is not null then perform public.automacao_disparar('tag_removida', v_tel, jsonb_build_object('tag_id', old.tag_id)); end if;
  end if;
  return null;
exception when others then
  insert into public.espelho_erros (origem, erro, detalhe) values ('automacao_t_tags', sqlerrm, null);
  return null;
end $$;
drop trigger if exists t_automacao_tags on public.conversa_tags;
create trigger t_automacao_tags after insert or delete on public.conversa_tags
  for each row execute function public.automacao_t_tags();

-- mensagem recebida: tira de quem tem "sair se responder" e dispara gatilho de mensagem
create or replace function public.automacao_t_mensagens() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_tel text; e record;
begin
  if new.direcao <> 'recebida' or coalesce(new.canal, 'crm') = 'historico' then return null; end if;
  select telefone into v_tel from public.conversas where id = new.conversa_id;
  if v_tel is null then return null; end if;
  for e in
    select x.id, x.automacao_id, x.passo from public.automacao_execucoes x join public.automacoes a on a.id = x.automacao_id
     where x.telefone = v_tel and x.status = 'ativa' and coalesce((a.regras->>'sair_se_responder')::boolean, true)
       and x.entrou_em < new.enviada_em
  loop
    update public.automacao_execucoes set status = 'saiu', motivo = 'paciente respondeu', terminou_em = now() where id = e.id;
    insert into public.automacao_log (automacao_id, execucao_id, telefone, passo, acao, detalhe)
    values (e.automacao_id, e.id, v_tel, e.passo, 'saiu', 'paciente respondeu');
  end loop;
  -- marca a resposta para a condição "respondeu"
  update public.automacao_execucoes set contexto = contexto || jsonb_build_object('respondeu_em', new.enviada_em)
   where telefone = v_tel and status = 'ativa';
  if public.automacoes_ligadas() then
    perform public.automacao_disparar('mensagem_recebida', v_tel, jsonb_build_object('texto', new.texto));
  end if;
  return null;
exception when others then
  insert into public.espelho_erros (origem, erro, detalhe) values ('automacao_t_mensagens', sqlerrm, null);
  return null;
end $$;
drop trigger if exists t_automacao_mensagens on public.mensagens;
create trigger t_automacao_mensagens after insert on public.mensagens
  for each row execute function public.automacao_t_mensagens();

-- ------------------------------------------------------------
-- Funções do motor (só a função whatsapp-automacoes, com a chave de serviço)
-- ------------------------------------------------------------
-- pega até p_limite passos vencidos e trava por 5 minutos
create or replace function public.automacao_pegar(p_limite integer default 30)
returns setof public.automacao_execucoes
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  return query
  update public.automacao_execucoes x set trava_ate = now() + interval '5 minutes'
   where x.id in (
     select y.id from public.automacao_execucoes y
      where y.status = 'ativa' and y.proxima_em <= now() and (y.trava_ate is null or y.trava_ate < now())
      order by y.proxima_em
      limit p_limite
      for update skip locked)
  returning x.*;
end $$;

-- grava o resultado de um passo e decide o próximo
create or replace function public.automacao_avancar(
  p_exec bigint, p_passo_feito integer, p_acao text, p_resultado text, p_detalhe text,
  p_proximo integer, p_proxima_em timestamptz, p_status text default 'ativa', p_conversa uuid default null)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare x public.automacao_execucoes;
begin
  select * into x from public.automacao_execucoes where id = p_exec;
  if not found then return; end if;
  if p_acao is not null then
    insert into public.automacao_log (automacao_id, execucao_id, telefone, passo, acao, resultado, detalhe)
    values (x.automacao_id, x.id, x.telefone, p_passo_feito, p_acao, coalesce(p_resultado, 'ok'), p_detalhe);
  end if;
  if x.status <> 'ativa' then return; end if;   -- saiu enquanto o motor trabalhava
  update public.automacao_execucoes set
    passo = coalesce(p_proximo, passo),
    proxima_em = coalesce(p_proxima_em, now()),
    status = coalesce(p_status, 'ativa'),
    motivo = case when coalesce(p_status, 'ativa') <> 'ativa' then p_detalhe else motivo end,
    terminou_em = case when coalesce(p_status, 'ativa') <> 'ativa' then now() else null end,
    conversa_id = coalesce(p_conversa, conversa_id),
    trava_ate = null
  where id = p_exec;
end $$;

-- conversa do telefone no número da automação (cria se não existir)
create or replace function public.automacao_conversa(p_numero text, p_telefone text)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  return public.wa_conversa(p_numero, '55' || p_telefone);
end $$;

-- chave do motor: o agendador do banco manda e a função confere
create table if not exists public.automacao_segredo (id integer primary key default 1 check (id = 1), chave text not null);
alter table public.automacao_segredo enable row level security;
revoke all on public.automacao_segredo from public, anon, authenticated;
insert into public.automacao_segredo (chave) values (md5(random()::text || clock_timestamp()::text) || md5(random()::text)) on conflict (id) do nothing;
create or replace function public.automacao_conferir_chave(p_chave text) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from public.automacao_segredo where chave = p_chave);
$$;

revoke all on function public.automacao_entrar(bigint, text, text, jsonb, boolean) from public, anon, authenticated;
revoke all on function public.automacao_disparar(text, text, jsonb) from public, anon, authenticated;
revoke all on function public.automacao_pegar(integer) from public, anon, authenticated;
revoke all on function public.automacao_avancar(bigint, integer, text, text, text, integer, timestamptz, text, uuid) from public, anon, authenticated;
revoke all on function public.automacao_conversa(text, text) from public, anon, authenticated;
revoke all on function public.automacao_conferir_chave(text) from public, anon, authenticated;
grant execute on function public.automacao_entrar(bigint, text, text, jsonb, boolean) to service_role;
grant execute on function public.automacao_pegar(integer) to service_role;
grant execute on function public.automacao_avancar(bigint, integer, text, text, text, integer, timestamptz, text, uuid) to service_role;
grant execute on function public.automacao_conversa(text, text) to service_role;
grant execute on function public.automacao_conferir_chave(text) to service_role;
revoke all on function public.automacao_colocar(bigint, text) from public, anon;
grant execute on function public.automacao_colocar(bigint, text) to authenticated;

-- tempo real para a tela acompanhar
do $$ begin
  alter publication supabase_realtime add table public.automacao_execucoes;
exception when duplicate_object then null; when undefined_object then null; end $$;

select 'automações prontas (desligadas)' as status,
       (select valor from public.configuracoes where chave = 'automacoes_ligadas') as chave_geral;
