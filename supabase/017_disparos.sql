-- ============================================================
-- CRM Bulhões — Disparo em massa (22/10/2026)
--
--   • disparos: cada envio em massa (modelo, público, ritmo, agendamento).
--   • disparo_destinos: cada contato do disparo e o que aconteceu com ele.
--   • whatsapp_optout: quem pediu para não receber mais mensagens. Entra
--     sozinho quando o paciente responde só "sair", "parar", "pare", "stop"
--     ou "descadastrar"; a equipe também pode tirar da lista.
--   • O motor (função whatsapp-automacoes, a cada minuto) envia os disparos
--     no ritmo escolhido. Disparos não dependem da chave geral das automações:
--     cada um é uma decisão da equipe.
--
-- Rodar no Supabase: SQL Editor → New query → colar tudo → Run.
-- Pode rodar mais de uma vez sem problema.
-- ============================================================

-- preço estimado por mensagem (para a tela mostrar o custo); ajuste pela fatura da Meta
insert into public.configuracoes (chave, valor, atualizado_por)
values ('whatsapp_precos', '{"moeda":"USD","MARKETING":0.0625,"UTILITY":0.0068,"AUTHENTICATION":0.0068}'::jsonb, 'migracao')
on conflict (chave) do nothing;

create table if not exists public.whatsapp_optout (
  telefone   text primary key,
  motivo     text,
  em         timestamptz not null default now(),
  por        text
);
alter table public.whatsapp_optout enable row level security;
revoke all on public.whatsapp_optout from anon, authenticated;
grant select, insert, delete on public.whatsapp_optout to authenticated;
drop policy if exists optout_ver on public.whatsapp_optout;
create policy optout_ver on public.whatsapp_optout for select to authenticated
  using (public.tem_papel('gestao', 'avaliacao', 'comercial'));
drop policy if exists optout_por on public.whatsapp_optout;
create policy optout_por on public.whatsapp_optout for insert to authenticated
  with check (public.tem_papel('gestao', 'avaliacao', 'comercial'));
drop policy if exists optout_tirar on public.whatsapp_optout;
create policy optout_tirar on public.whatsapp_optout for delete to authenticated
  using (public.tem_papel('gestao', 'comercial'));

create table if not exists public.disparos (
  id                 bigint generated always as identity primary key,
  nome               text not null check (length(btrim(nome)) between 1 and 80),
  modelo             jsonb not null,                  -- {nome, idioma, categoria, formato, campos, variaveis, cabecalho, texto_preview}
  numero_clinica_id  text,
  status             text not null default 'agendado'
                     check (status in ('agendado', 'enviando', 'pausado', 'concluido', 'cancelado')),
  agendado_para      timestamptz not null default now(),
  ritmo_por_minuto   integer not null default 20 check (ritmo_por_minuto between 1 and 200),
  filtros            jsonb not null default '{}'::jsonb,   -- só para registro (como o público foi montado)
  tag_id             bigint references public.wa_tags(id) on delete set null,
  total              integer not null default 0,
  criado_em          timestamptz not null default now(),
  criado_por         text default public.email_atual(),
  iniciado_em        timestamptz,
  concluido_em       timestamptz,
  trava_ate          timestamptz
);

create table if not exists public.disparo_destinos (
  id             bigint generated always as identity primary key,
  disparo_id     bigint not null references public.disparos(id) on delete cascade,
  telefone       text not null,
  nome           text,
  status         text not null default 'pendente'
                 check (status in ('pendente', 'enviado', 'falhou', 'pulado')),
  motivo         text,
  conversa_id    uuid references public.conversas(id) on delete set null,
  wa_message_id  text,
  enviado_em     timestamptz,
  unique (disparo_id, telefone)
);
create index if not exists disparo_destinos_pend on public.disparo_destinos (disparo_id, id) where status = 'pendente';
create index if not exists disparo_destinos_tel on public.disparo_destinos (telefone, enviado_em desc);

alter table public.disparos enable row level security;
alter table public.disparo_destinos enable row level security;
revoke all on public.disparos, public.disparo_destinos from anon, authenticated;
grant select on public.disparos, public.disparo_destinos to authenticated;
grant update (status) on public.disparos to authenticated;

drop policy if exists disparos_ver on public.disparos;
create policy disparos_ver on public.disparos for select to authenticated
  using (public.tem_papel('gestao', 'avaliacao', 'comercial'));
-- a equipe só pausa, retoma ou cancela (o resto é pela função disparo_criar)
drop policy if exists disparos_status on public.disparos;
create policy disparos_status on public.disparos for update to authenticated
  using (public.tem_papel('gestao', 'comercial') and status in ('agendado', 'enviando', 'pausado'))
  with check (status in ('agendado', 'enviando', 'pausado', 'cancelado'));
drop policy if exists disparo_destinos_ver on public.disparo_destinos;
create policy disparo_destinos_ver on public.disparo_destinos for select to authenticated
  using (public.tem_papel('gestao', 'avaliacao', 'comercial'));

-- telefone fixo (10 dígitos com o número começando de 2 a 5): não tem WhatsApp de celular.
-- O CRM normaliza números antigos colocando o 9, então o teste é feito antes.
create or replace function public.wa_eh_fixo(t text) returns boolean
language sql immutable as $$
  select length(d) = 10 and substr(d, 3, 1) between '2' and '5'
  from (select case when x like '55%' and length(x) = 12 then substr(x, 3) else x end d
          from (select regexp_replace(coalesce(t, ''), '\D', '', 'g') x) a) b;
$$;

-- ------------------------------------------------------------
-- Criar um disparo (a tela manda o público já filtrado)
-- p_destinos: [{"telefone":"13991234567","nome":"Ana"}, …]
-- Pula: telefone inválido, quem pediu para sair, repetido e quem recebeu o
-- mesmo modelo nos últimos p_dias_repeticao dias (0 = não pula).
-- ------------------------------------------------------------
create or replace function public.disparo_criar(
  p_nome text, p_modelo jsonb, p_destinos jsonb, p_agendado_para timestamptz default null,
  p_ritmo integer default 20, p_filtros jsonb default '{}'::jsonb, p_dias_repeticao integer default 7,
  p_numero text default null, p_criar_tag boolean default true)
returns jsonb
language plpgsql security definer set search_path = public, migracao, pg_temp as $$
declare v_id bigint; v_tag bigint; v_nome_tag text; v_total int; v_pul int;
begin
  if not public.tem_papel('gestao', 'comercial') then raise exception 'sem permissão para disparo em massa'; end if;
  if coalesce(p_modelo->>'nome', '') = '' then raise exception 'escolha um modelo'; end if;
  if jsonb_typeof(p_destinos) <> 'array' or jsonb_array_length(p_destinos) = 0 then raise exception 'nenhum contato no público'; end if;
  if jsonb_array_length(p_destinos) > 20000 then raise exception 'público grande demais (máx. 20.000 por disparo)'; end if;

  if p_criar_tag then
    v_nome_tag := left('disparo ' || to_char(coalesce(p_agendado_para, now()) at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI') || ' ' || btrim(p_nome), 40);
    insert into public.wa_tags (nome, cor, criada_por) values (v_nome_tag, '#9AA5B1', public.email_atual())
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

-- Prévia: quantos seriam pulados (sem criar nada)
create or replace function public.disparo_previa(p_modelo text, p_telefones text[], p_dias_repeticao integer default 7)
returns jsonb
language sql stable security definer set search_path = public, migracao, pg_temp as $$
  with t as (select distinct migracao.tel(x) tel from unnest(p_telefones) x)
  select case when not public.tem_papel('gestao', 'avaliacao', 'comercial') then null else jsonb_build_object(
    'optout', (select count(*) from t join public.whatsapp_optout o on o.telefone = t.tel),
    'repetidos', (select count(distinct t.tel) from t join public.disparo_destinos x on x.telefone = t.tel join public.disparos y on y.id = x.disparo_id
                  where p_dias_repeticao > 0 and x.status = 'enviado' and y.modelo->>'nome' = p_modelo
                    and x.enviado_em > now() - make_interval(days => p_dias_repeticao))
  ) end;
$$;
revoke all on function public.disparo_previa(text, text[], integer) from public, anon;
grant execute on function public.disparo_previa(text, text[], integer) to authenticated;

-- ------------------------------------------------------------
-- Motor: pega os próximos contatos dos disparos em andamento
-- ------------------------------------------------------------
create or replace function public.disparo_pegar()
returns table (destino_id bigint, disparo_id bigint, telefone text, nome text)
language plpgsql security definer set search_path = public, pg_temp as $$
declare d record;
begin
  -- agendados que chegaram na hora começam
  update public.disparos set status = 'enviando', iniciado_em = coalesce(iniciado_em, now())
   where status = 'agendado' and agendado_para <= now();
  for d in
    select * from public.disparos
     where status = 'enviando' and (trava_ate is null or trava_ate < now())
     order by agendado_para
     for update skip locked
  loop
    update public.disparos set trava_ate = now() + interval '50 seconds' where id = d.id;
    update public.disparo_destinos x set status = 'pulado', motivo = 'pediu para não receber'
     where x.disparo_id = d.id and x.status = 'pendente'
       and exists (select 1 from public.whatsapp_optout o where o.telefone = x.telefone);
    return query
      select x.id, x.disparo_id, x.telefone, x.nome from public.disparo_destinos x
       where x.disparo_id = d.id and x.status = 'pendente'
       order by x.id limit d.ritmo_por_minuto;
    if not exists (select 1 from public.disparo_destinos x where x.disparo_id = d.id and x.status = 'pendente') then
      update public.disparos set status = 'concluido', concluido_em = now(), trava_ate = null where id = d.id;
    end if;
  end loop;
end $$;

create or replace function public.disparo_marcar(p_destino bigint, p_status text, p_motivo text, p_conversa uuid, p_wa_message_id text)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_disp bigint; v_tag bigint;
begin
  update public.disparo_destinos
     set status = p_status, motivo = p_motivo, conversa_id = coalesce(p_conversa, conversa_id),
         wa_message_id = coalesce(p_wa_message_id, wa_message_id),
         enviado_em = case when p_status = 'enviado' then now() else enviado_em end
   where id = p_destino and status = 'pendente'
  returning disparo_id into v_disp;
  if p_status = 'enviado' and p_conversa is not null then
    select tag_id into v_tag from public.disparos where id = v_disp;
    if v_tag is not null then
      insert into public.conversa_tags (conversa_id, tag_id, adicionada_por) values (p_conversa, v_tag, 'disparo')
      on conflict do nothing;
    end if;
  end if;
end $$;

-- Números do disparo (enviados, entregues, lidos, responderam…)
create or replace function public.disparo_resumo(p_disparo bigint)
returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select case when not public.tem_papel('gestao', 'avaliacao', 'comercial') then null else (
    select jsonb_build_object(
      'pendentes', count(*) filter (where x.status = 'pendente'),
      'enviados',  count(*) filter (where x.status = 'enviado'),
      'falharam',  count(*) filter (where x.status = 'falhou' or m.status = 'falhou'),
      'pulados',   count(*) filter (where x.status = 'pulado'),
      'entregues', count(*) filter (where m.status in ('entregue', 'lida')),
      'lidos',     count(*) filter (where m.status = 'lida'),
      'responderam', count(*) filter (where x.status = 'enviado' and exists (
          select 1 from public.mensagens r where r.conversa_id = x.conversa_id and r.direcao = 'recebida' and r.enviada_em > x.enviado_em)))
    from public.disparo_destinos x
    left join public.mensagens m on m.wa_message_id = x.wa_message_id
    where x.disparo_id = p_disparo) end;
$$;
revoke all on function public.disparo_resumo(bigint) from public, anon;
grant execute on function public.disparo_resumo(bigint) to authenticated;

revoke all on function public.disparo_pegar() from public, anon, authenticated;
revoke all on function public.disparo_marcar(bigint, text, text, uuid, text) from public, anon, authenticated;
grant execute on function public.disparo_pegar() to service_role;
grant execute on function public.disparo_marcar(bigint, text, text, uuid, text) to service_role;

-- ------------------------------------------------------------
-- Pediu para sair: resposta só com "sair", "parar"… entra na lista
-- ------------------------------------------------------------
create or replace function public.wa_t_optout() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_tel text;
begin
  if new.direcao <> 'recebida' or coalesce(new.canal, 'crm') = 'historico' then return null; end if;
  if lower(btrim(regexp_replace(coalesce(new.texto, ''), '[[:punct:]]', '', 'g'))) in ('sair', 'parar', 'pare', 'stop', 'descadastrar', 'cancelar inscrição', 'cancelar inscricao') then
    select telefone into v_tel from public.conversas where id = new.conversa_id;
    if v_tel is not null then
      insert into public.whatsapp_optout (telefone, motivo, por) values (v_tel, 'respondeu "' || left(new.texto, 30) || '"', 'paciente')
      on conflict (telefone) do nothing;
    end if;
  end if;
  return null;
exception when others then return null;
end $$;
drop trigger if exists t_wa_optout on public.mensagens;
create trigger t_wa_optout after insert on public.mensagens
  for each row execute function public.wa_t_optout();

do $$ begin
  alter publication supabase_realtime add table public.disparos;
exception when duplicate_object then null; when undefined_object then null; end $$;

select 'disparo em massa pronto' as status;
