-- ============================================================
-- 202 (16/11/2026) Automações e disparos separados por espaço
--   Pedido do Lucas (feito no projeto do Instituto, com a conversa da
--   clínica parada). O mesmo motor (whatsapp-automacoes) atende os dois
--   espaços; a edge function NÃO muda.
--
--   Correção do que já acontecia: o motor reconhecia a pessoa só pelo
--   telefone. Uma mensagem no WhatsApp do Instituto podia colocar a
--   dentista numa automação da clínica, tirar alguém de uma sequência da
--   clínica, ou fazer a automação da clínica (sem número fixo) mandar pela
--   conversa do Instituto. Agora cada automação só reage a acontecimentos
--   do próprio espaço e só usa conversas do próprio espaço.
--
--   1. automacoes.espaco e disparos.espaco: vêm do número escolhido
--      (sem número = clínica). Tudo o que existe hoje continua da clínica.
--   2. Trava no banco (RESTRICTIVE) em automacoes, automacao_execucoes,
--      automacao_log, disparos e disparo_destinos.
--   3. Gatilhos de mensagem, tag e estado da conversa levam o espaço do
--      número; automacao_disparar só dispara automação do mesmo espaço.
--      Gatilhos de paciente (lead novo, etapa) continuam só da clínica.
--   4. automacao_entrar: automação sem número fixo só usa conversa do
--      próprio espaço.
--   5. disparo_criar: a tag do disparo nasce no espaço do disparo.
--
--   Para as automações da clínica, nada muda além de deixarem de reagir
--   ao WhatsApp do Instituto.
-- Pode rodar mais de uma vez sem problema.
-- ============================================================

-- espaço de um número (Instagram e número desconhecido = clínica)
create or replace function public.espaco_do_numero(p_numero text)
returns text
language sql stable security definer set search_path = ''
as $$
  select coalesce((select n.espaco from public.whatsapp_numeros n where n.phone_number_id = p_numero), 'clinica');
$$;

-- ------------------------------------------------------------
-- 1. Espaço das automações e dos disparos
-- ------------------------------------------------------------
alter table public.automacoes add column if not exists espaco text not null default 'clinica';
alter table public.disparos add column if not exists espaco text not null default 'clinica';
do $$ begin
  alter table public.automacoes add constraint automacoes_espaco_ck check (espaco in ('clinica', 'instituto'));
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.disparos add constraint disparos_espaco_ck check (espaco in ('clinica', 'instituto'));
exception when duplicate_object then null; end $$;

create or replace function public.t_espaco_pelo_numero() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  new.espaco := public.espaco_do_numero(new.numero_clinica_id);
  return new;
end $$;

drop trigger if exists t_automacoes_espaco on public.automacoes;
create trigger t_automacoes_espaco before insert or update of numero_clinica_id on public.automacoes
  for each row execute function public.t_espaco_pelo_numero();
drop trigger if exists t_disparos_espaco on public.disparos;
create trigger t_disparos_espaco before insert or update of numero_clinica_id on public.disparos
  for each row execute function public.t_espaco_pelo_numero();

update public.automacoes set espaco = public.espaco_do_numero(numero_clinica_id)
 where espaco is distinct from public.espaco_do_numero(numero_clinica_id);
update public.disparos set espaco = public.espaco_do_numero(numero_clinica_id)
 where espaco is distinct from public.espaco_do_numero(numero_clinica_id);

-- ------------------------------------------------------------
-- 2. Trava no banco
-- ------------------------------------------------------------
create or replace function public.automacoes_fora_do_meu_espaco()
returns bigint[]
language sql stable security definer set search_path = ''
as $$
  select coalesce(array_agg(a.id), '{}'::bigint[]) from public.automacoes a
   where not (a.espaco = any (public.meus_espacos()));
$$;
create or replace function public.disparos_fora_do_meu_espaco()
returns bigint[]
language sql stable security definer set search_path = ''
as $$
  select coalesce(array_agg(d.id), '{}'::bigint[]) from public.disparos d
   where not (d.espaco = any (public.meus_espacos()));
$$;

drop policy if exists espaco_automacoes on public.automacoes;
create policy espaco_automacoes on public.automacoes as restrictive for all to authenticated
  using (espaco = any ((select public.meus_espacos())::text[]))
  with check (espaco = any ((select public.meus_espacos())::text[]));
drop policy if exists espaco_automacao_execucoes on public.automacao_execucoes;
create policy espaco_automacao_execucoes on public.automacao_execucoes as restrictive for all to authenticated
  using (automacao_id <> all ((select public.automacoes_fora_do_meu_espaco())::bigint[]))
  with check (automacao_id <> all ((select public.automacoes_fora_do_meu_espaco())::bigint[]));
drop policy if exists espaco_automacao_log on public.automacao_log;
create policy espaco_automacao_log on public.automacao_log as restrictive for all to authenticated
  using (automacao_id is null or automacao_id <> all ((select public.automacoes_fora_do_meu_espaco())::bigint[]));
drop policy if exists espaco_disparos on public.disparos;
create policy espaco_disparos on public.disparos as restrictive for all to authenticated
  using (espaco = any ((select public.meus_espacos())::text[]))
  with check (espaco = any ((select public.meus_espacos())::text[]));
drop policy if exists espaco_disparo_destinos on public.disparo_destinos;
create policy espaco_disparo_destinos on public.disparo_destinos as restrictive for all to authenticated
  using (disparo_id <> all ((select public.disparos_fora_do_meu_espaco())::bigint[]))
  with check (disparo_id <> all ((select public.disparos_fora_do_meu_espaco())::bigint[]));

-- ------------------------------------------------------------
-- 3. Gatilhos com o espaço do acontecimento
-- ------------------------------------------------------------
create or replace function public.automacao_disparar(p_tipo text, p_telefone text, p_dados jsonb)
returns integer
language plpgsql security definer set search_path = public, pg_temp as $$
declare a record; n integer := 0;
begin
  -- (202) só automação do mesmo espaço do acontecimento; sem espaço = clínica (paciente, lead, etapa)
  for a in select * from public.automacoes where ligada and espaco = coalesce(p_dados->>'espaco', 'clinica') loop
    if exists (select 1 from jsonb_array_elements(case when jsonb_typeof(a.gatilho->'lista') = 'array' then a.gatilho->'lista' else jsonb_build_array(a.gatilho) end) g
               where public.automacao_gatilho_bate(g, p_tipo, p_dados))
       and public.automacao_entrar(a.id, p_telefone, 'gatilho: ' || p_tipo, p_dados) is not null then
      n := n + 1;
    end if;
  end loop;
  return n;
exception when others then
  insert into public.espelho_erros (origem, erro, detalhe) values ('automacao_disparar', sqlerrm, p_tipo || ' ' || coalesce(p_telefone, ''));
  return 0;
end $$;
revoke all on function public.automacao_disparar(text, text, jsonb) from public, anon, authenticated;

create or replace function public.automacao_t_mensagens() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_tel text; v_num text; v_esp text; e record;
begin
  if new.direcao <> 'recebida' or coalesce(new.canal, 'crm') = 'historico' then return null; end if;
  select telefone, numero_clinica_id into v_tel, v_num from public.conversas where id = new.conversa_id;
  if v_tel is null then return null; end if;
  v_esp := public.espaco_do_numero(v_num);
  for e in
    select x.id, x.automacao_id, x.passo from public.automacao_execucoes x join public.automacoes a on a.id = x.automacao_id
     where x.telefone = v_tel and x.status = 'ativa' and x.entrou_em < new.enviada_em
       and a.espaco = v_esp
       and public.automacao_sai_por_mensagem(a.regras, new.texto)
  loop
    update public.automacao_execucoes set status = 'saiu', motivo = 'paciente respondeu', terminou_em = now() where id = e.id;
    insert into public.automacao_log (automacao_id, execucao_id, telefone, passo, acao, detalhe)
    values (e.automacao_id, e.id, v_tel, e.passo, 'saiu', 'paciente respondeu: ' || left(coalesce(new.texto, ''), 60));
  end loop;
  update public.automacao_execucoes x set contexto = x.contexto || jsonb_build_object('respondeu_em', new.enviada_em)
    from public.automacoes a
   where a.id = x.automacao_id and a.espaco = v_esp and x.telefone = v_tel and x.status = 'ativa';
  if public.automacoes_alguma_ligada() then
    perform public.automacao_disparar('mensagem_recebida', v_tel, jsonb_build_object('texto', new.texto, 'espaco', v_esp));
  end if;
  return null;
exception when others then
  insert into public.espelho_erros (origem, erro, detalhe) values ('automacao_t_mensagens', sqlerrm, null);
  return null;
end $$;

create or replace function public.automacao_t_tags() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_tel text; v_num text; v_esp text; e record;
begin
  if tg_op = 'INSERT' then
    select telefone, numero_clinica_id into v_tel, v_num from public.conversas where id = new.conversa_id;
    if v_tel is null then return null; end if;
    v_esp := public.espaco_do_numero(v_num);
    for e in
      select x.id, x.automacao_id, x.passo from public.automacao_execucoes x join public.automacoes a on a.id = x.automacao_id
       where x.telefone = v_tel and x.status = 'ativa' and a.espaco = v_esp
         and a.regras->'saida'->>'tipo' = 'tag' and (a.regras->'saida'->>'tag_id') = new.tag_id::text
    loop
      update public.automacao_execucoes set status = 'saiu', motivo = 'recebeu a tag de saída', terminou_em = now() where id = e.id;
      insert into public.automacao_log (automacao_id, execucao_id, telefone, passo, acao, detalhe)
      values (e.automacao_id, e.id, v_tel, e.passo, 'saiu', 'recebeu a tag de saída');
    end loop;
    if public.automacoes_alguma_ligada() then
      perform public.automacao_disparar('tag_adicionada', v_tel, jsonb_build_object('tag_id', new.tag_id, 'espaco', v_esp));
    end if;
  else
    select telefone, numero_clinica_id into v_tel, v_num from public.conversas where id = old.conversa_id;
    if v_tel is not null and public.automacoes_alguma_ligada() then
      perform public.automacao_disparar('tag_removida', v_tel, jsonb_build_object('tag_id', old.tag_id, 'espaco', public.espaco_do_numero(v_num)));
    end if;
  end if;
  return null;
exception when others then
  insert into public.espelho_erros (origem, erro, detalhe) values ('automacao_t_tags', sqlerrm, null);
  return null;
end $$;

create or replace function public.automacao_t_conversas() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if public.automacoes_alguma_ligada() and public.automacao_estado(new) is distinct from public.automacao_estado(old) then
    perform public.automacao_disparar('estado', new.telefone,
      jsonb_build_object('estado', public.automacao_estado(new), 'espaco', public.espaco_do_numero(new.numero_clinica_id)));
  end if;
  return null;
exception when others then
  insert into public.espelho_erros (origem, erro, detalhe) values ('automacao_t_conversas', sqlerrm, null);
  return null;
end $$;

-- ------------------------------------------------------------
-- 4. Entrada: conversa do próprio espaço
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
    if not a.ligada then return null; end if;
    if not a.modo_teste and not public.automacoes_ligadas() then return null; end if;
    if a.modo_teste and not (v_tel = any (array(select migracao.tel(t) from unnest(a.telefones_teste) t))) then return null; end if;
  end if;
  if jsonb_array_length(a.passos) = 0 then return null; end if;
  -- já está ativa nesta automação: não entra de novo
  if exists (select 1 from public.automacao_execucoes where automacao_id = a.id and telefone = v_tel and status = 'ativa') then return null; end if;
  v_reent := coalesce(a.regras->>'reentrada', 'depois_de_sair');
  if v_reent = 'nunca' and exists (select 1 from public.automacao_execucoes where automacao_id = a.id and telefone = v_tel) then return null; end if;
  -- (202) sem número fixo: só conversa do próprio espaço (a clínica não usa a conversa do Instituto, e vice-versa)
  select c.id into v_conv from public.conversas c
   where c.telefone = v_tel
     and (case when a.numero_clinica_id is null then public.espaco_do_numero(c.numero_clinica_id) = a.espaco
               else c.numero_clinica_id = a.numero_clinica_id end)
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

-- ------------------------------------------------------------
-- 5. Disparo: tag no espaço do disparo
-- ------------------------------------------------------------
create or replace function public.disparo_criar(
  p_nome text, p_modelo jsonb, p_destinos jsonb, p_agendado_para timestamptz default null,
  p_ritmo integer default 20, p_filtros jsonb default '{}'::jsonb, p_dias_repeticao integer default 7,
  p_numero text default null, p_criar_tag boolean default true)
returns jsonb
language plpgsql security definer set search_path = public, migracao, pg_temp as $$
declare v_id bigint; v_tag bigint; v_nome_tag text; v_total int; v_pul int; v_esp text := public.espaco_do_numero(p_numero);
begin
  if not public.tem_papel('gestao', 'comercial') then raise exception 'sem permissão para disparo em massa'; end if;
  if not public.tem_espaco(v_esp) then raise exception 'sem acesso a este número'; end if;
  if coalesce(p_modelo->>'nome', '') = '' then raise exception 'escolha um modelo'; end if;
  if jsonb_typeof(p_destinos) <> 'array' or jsonb_array_length(p_destinos) = 0 then raise exception 'nenhum contato no público'; end if;
  if jsonb_array_length(p_destinos) > 20000 then raise exception 'público grande demais (máx. 20.000 por disparo)'; end if;

  if p_criar_tag then
    v_nome_tag := left('disparo ' || to_char(coalesce(p_agendado_para, now()) at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI') || ' ' || btrim(p_nome), 40);
    insert into public.wa_tags (nome, cor, criada_por, espaco) values (v_nome_tag, '#9AA5B1', public.email_atual(), v_esp)
    on conflict (nome) do update set nome = excluded.nome returning id into v_tag;
  end if;

  insert into public.disparos (nome, modelo, numero_clinica_id, agendado_para, ritmo_por_minuto, filtros, tag_id)
  values (btrim(p_nome), p_modelo, p_numero, coalesce(p_agendado_para, now()), greatest(1, least(200, coalesce(p_ritmo, 20))), coalesce(p_filtros, '{}'::jsonb), v_tag)
  returning id into v_id;

  with entrada as (
    select case when public.wa_eh_fixo(d.v->>'telefone') then null else migracao.tel(d.v->>'telefone') end as tel,
           nullif(btrim(d.v->>'nome'), '') as nome, d.ord
    from jsonb_array_elements(p_destinos) with ordinality as d(v, ord)
  ), unicos as (
    select distinct on (coalesce(tel, 'x' || ord)) tel, nome, ord from entrada order by coalesce(tel, 'x' || ord), ord
  )
  insert into public.disparo_destinos (disparo_id, telefone, nome, status, motivo)
  select v_id, coalesce(u.tel, 'invalido-' || u.ord), u.nome,
    case when u.tel is null or u.tel !~ '^\d{2}9\d{8}$' then 'pulado'
         when exists (select 1 from public.whatsapp_optout o where o.telefone = u.tel) then 'pulado'
         when p_dias_repeticao > 0 and exists (
           select 1 from public.disparo_destinos x join public.disparos y on y.id = x.disparo_id
            where x.telefone = u.tel and x.status = 'enviado' and y.modelo->>'nome' = p_modelo->>'nome'
              and x.enviado_em > now() - make_interval(days => p_dias_repeticao)) then 'pulado'
         else 'pendente' end,
    case when u.tel is null or u.tel !~ '^\d{2}9\d{8}$' then 'telefone inválido (precisa ser celular com DDD)'
         when exists (select 1 from public.whatsapp_optout o where o.telefone = u.tel) then 'pediu para não receber'
         when p_dias_repeticao > 0 and exists (
           select 1 from public.disparo_destinos x join public.disparos y on y.id = x.disparo_id
            where x.telefone = u.tel and x.status = 'enviado' and y.modelo->>'nome' = p_modelo->>'nome'
              and x.enviado_em > now() - make_interval(days => p_dias_repeticao)) then 'já recebeu este modelo há menos de ' || p_dias_repeticao || ' dias'
         else null end
  from unicos u;

  select count(*) filter (where status = 'pendente'), count(*) filter (where status = 'pulado')
    into v_total, v_pul from public.disparo_destinos where disparo_id = v_id;
  update public.disparos set total = v_total where id = v_id;
  if v_total = 0 then
    update public.disparos set status = 'concluido', concluido_em = now() where id = v_id;
  end if;
  return jsonb_build_object('id', v_id, 'enviar', v_total, 'pulados', v_pul, 'tag_id', v_tag);
end $$;
revoke all on function public.disparo_criar(text, jsonb, jsonb, timestamptz, integer, jsonb, integer, text, boolean) from public, anon;
grant execute on function public.disparo_criar(text, jsonb, jsonb, timestamptz, integer, jsonb, integer, text, boolean) to authenticated;

-- ------------------------------------------------------------
-- Conferência
-- ------------------------------------------------------------
select 'automações' as o_que, espaco as item, count(*)::text as valor from public.automacoes group by espaco
union all
select 'disparos', espaco, count(*)::text from public.disparos group by espaco
union all
select 'política', tablename || '.' || policyname, permissive from pg_policies
 where policyname in ('espaco_automacoes', 'espaco_automacao_execucoes', 'espaco_automacao_log', 'espaco_disparos', 'espaco_disparo_destinos')
order by 1, 2;
