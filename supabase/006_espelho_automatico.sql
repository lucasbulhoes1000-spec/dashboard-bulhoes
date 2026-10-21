-- ============================================================
-- CRM Bulhões — Fase 1, etapa 3: espelho automático
-- 21/10/2026
--
-- Mantém as tabelas novas iguais ao sistema atual, sem mexer nele:
--   • Gatilho no crm_sessions: a cada gravação do CRM (equipe, webhooks do
--     Clinicorp, sincronizações do Apps Script), atualiza só os pacientes que
--     mudaram, além de comissões, listas e configurações.
--   • Função espelhar_planilha_cloudia(): o Apps Script chama a cada 10 min,
--     depois de reenviar a aba Leads, e os eventos do funil são atualizados.
--
-- Segurança: se o espelho der erro, o erro vai para a tabela espelho_erros e
-- a gravação no CRM segue normalmente. O espelho nunca trava o CRM.
-- Desligar na hora: update public.configuracoes set valor = 'false' where chave = 'espelho_ligado';
--
-- Rodar no Supabase: SQL Editor → New query → colar tudo → Run.
-- ============================================================

create table if not exists public.espelho_erros (
  id        bigint generated always as identity primary key,
  quando    timestamptz not null default now(),
  origem    text not null,
  erro      text not null,
  detalhe   text
);
alter table public.espelho_erros enable row level security;
revoke all on public.espelho_erros from anon, authenticated;

alter table public.eventos_funil add column if not exists criado_na_cloudia timestamptz;

insert into public.configuracoes (chave, valor, atualizado_por)
values ('espelho_ligado', 'true'::jsonb, 'migracao')
on conflict (chave) do nothing;

create or replace function public.espelho_ligado() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select valor = 'true'::jsonb from public.configuracoes where chave = 'espelho_ligado'), false)
     and not exists (select 1 from public.configuracoes where chave = 'virada_concluida');
$$;

-- ------------------------------------------------------------
-- Sincroniza um conjunto de telefones a partir do bloco do CRM
-- (mesmas regras da migração da etapa 2)
-- ------------------------------------------------------------
create or replace function public.espelhar_pacientes_do_crm(tels text[], crm jsonb)
returns integer
language plpgsql security definer set search_path = public, migracao, pg_temp as $$
declare n integer := 0;
begin
  drop table if exists _esp_src;
  create temp table _esp_src as
  select k as chave, v as dado, migracao.tel(k) as tel, (k = migracao.tel(k)) as canonica
  from jsonb_each(crm) e(k, v)
  where k ~ '^\d+$' and jsonb_typeof(v) = 'object' and migracao.tel(k) = any (tels);

  drop table if exists _esp_ord;
  create temp table _esp_ord as
  select *, row_number() over (partition by tel order by canonica desc, chave) as prio from _esp_src;

  -- pacientes presentes no CRM: cria ou atualiza (mantém o id)
  insert into public.pacientes
    (telefone, nome, origem, etapa, etapa_alterada_em, lead_importado, editado_manualmente, ad_id_manual, criado_em, legado)
  select tel,
         (array_remove(array_agg(nullif(dado->>'nomeAtual', '') order by prio), null))[1],
         (array_remove(array_agg(nullif(dado->>'origemAtual', '') order by prio), null))[1],
         (array_remove(array_agg(nullif(dado->>'statusAtual', '') order by prio), null))[1],
         (array_remove(array_agg(migracao.ts(dado->>'statusAtualEditedAt') order by prio), null))[1],
         coalesce(bool_or(migracao.bool(dado->>'leadImportado')), false),
         coalesce(bool_or(migracao.bool(dado->>'editadoManualmente')), false),
         (array_remove(array_agg(nullif(dado->>'adIdManual', '') order by prio), null))[1],
         coalesce((array_remove(array_agg(migracao.ts(dado->>'created_at') order by prio), null))[1], now()),
         jsonb_agg(jsonb_build_object('chave_original', chave) || (dado - 'orcamentos' - 'atividades' - 'anotacoes') order by prio)
  from _esp_ord
  where tel ~ '^[0-9]{10,13}$'
  group by tel
  on conflict (telefone) do update set
    nome = excluded.nome, origem = excluded.origem, etapa = excluded.etapa,
    etapa_alterada_em = excluded.etapa_alterada_em, lead_importado = excluded.lead_importado,
    editado_manualmente = excluded.editado_manualmente, ad_id_manual = excluded.ad_id_manual,
    criado_em = excluded.criado_em, legado = excluded.legado;

  -- refaz orçamentos, atividades e anotações desses pacientes
  delete from public.orcamentos o using public.pacientes p where o.paciente_id = p.id and p.telefone = any (tels);
  delete from public.atividades a using public.pacientes p where a.paciente_id = p.id and p.telefone = any (tels);
  delete from public.anotacoes  a using public.pacientes p where a.paciente_id = p.id and p.telefone = any (tels);

  insert into public.orcamentos
    (paciente_id, data, tratamento, valor, entrada, entrada_data, entrada_forma, pagamento, parcelas,
     avaliador, crc_participou, crc_nome, status, fechamento_data, fechamento_valor, tem_entrada,
     paciente_antigo, clinicorp_id, clinicorp_tratamento_id, origem_clinicorp, obs, legado)
  select paciente_id,
         migracao.dt(o->>'data'), nullif(o->>'tratamento', ''), migracao.num(o->>'valor'), migracao.num(o->>'entrada'),
         migracao.dt(o->>'entradaData'), nullif(o->>'entradaPgto', ''), nullif(o->>'pagamento', ''),
         migracao.num(o->>'parcelas')::integer, nullif(o->>'avaliador', ''), migracao.bool(o->>'crcParticip'),
         nullif(o->>'crcNome', ''), nullif(o->>'status', ''), migracao.dt(o->>'fechData'), migracao.num(o->>'fechValor'),
         migracao.bool(o->>'temEntrada'), migracao.bool(o->>'pacienteAntigo'),
         case when nullif(o->>'_clinicorpId', '') is not null
                   and not exists (select 1 from public.orcamentos x where x.clinicorp_id = o->>'_clinicorpId')
                   and row_number() over (partition by nullif(o->>'_clinicorpId', '') order by paciente_id, prio, pos) = 1
              then o->>'_clinicorpId' end,
         nullif(o->>'_treatmentId', ''), migracao.bool(o->>'origemClinicorp'), nullif(o->>'obs', ''), o
  from (
    select distinct on (p.id, coalesce('c' || nullif(x.value->>'_clinicorpId', ''), md5(x.value::text)))
           p.id as paciente_id, x.value as o, c.prio, x.ordinality as pos
    from _esp_ord c
    join public.pacientes p on p.telefone = c.tel
    cross join lateral jsonb_array_elements(case when jsonb_typeof(c.dado->'orcamentos') = 'array' then c.dado->'orcamentos' else '[]'::jsonb end)
         with ordinality x(value, ordinality)
    where jsonb_typeof(x.value) = 'object'
    order by p.id, coalesce('c' || nullif(x.value->>'_clinicorpId', ''), md5(x.value::text)), c.prio, x.ordinality
  ) z;

  insert into public.atividades (paciente_id, fase, quando, probabilidade, proximo_passo, obs, autor_email, criado_em)
  select distinct on (p.id, a.value::text)
         p.id, nullif(a.value->>'fase', ''),
         coalesce(migracao.ts(concat_ws(' ', a.value->>'data', a.value->>'hora')), migracao.ts(a.value->>'data')),
         nullif(a.value->>'prob', ''), nullif(a.value->>'proximo', ''), nullif(a.value->>'obs', ''),
         'migracao@crm-antigo', coalesce(migracao.ts(a.value->>'data'), now())
  from _esp_ord c
  join public.pacientes p on p.telefone = c.tel
  cross join lateral jsonb_array_elements(case when jsonb_typeof(c.dado->'atividades') = 'array' then c.dado->'atividades' else '[]'::jsonb end) a(value)
  where jsonb_typeof(a.value) = 'object'
  order by p.id, a.value::text, c.prio;

  insert into public.anotacoes (paciente_id, texto, autor_email, legado_id, criado_em)
  select distinct on (coalesce(nullif(x.value->>'id', ''), md5(p.id::text || x.value::text)))
         p.id,
         coalesce(nullif(x.value->>'text', ''), nullif(x.value->>'texto', ''), nullif(x.value->>'obs', ''), x.value::text),
         'migracao@crm-antigo', nullif(x.value->>'id', ''),
         coalesce(migracao.ts(x.value->>'createdAt'), migracao.ts(x.value->>'date'), migracao.ts(x.value->>'data'), now())
  from _esp_ord c
  join public.pacientes p on p.telefone = c.tel
  cross join lateral jsonb_array_elements(case when jsonb_typeof(c.dado->'anotacoes') = 'array' then c.dado->'anotacoes' else '[]'::jsonb end) x(value)
  where x.value is not null and x.value <> 'null'::jsonb
    and not exists (select 1 from public.anotacoes a2 where a2.legado_id = nullif(x.value->>'id', ''))
  order by coalesce(nullif(x.value->>'id', ''), md5(p.id::text || x.value::text)), c.prio;

  update public.pacientes p
     set paciente_antigo = exists (select 1 from public.orcamentos o where o.paciente_id = p.id and o.paciente_antigo)
   where p.telefone = any (tels);

  -- telefones que saíram do CRM: se não têm histórico na Cloudia, saem também
  delete from public.pacientes p
   where p.telefone = any (tels)
     and not exists (select 1 from _esp_src s where s.tel = p.telefone)
     and not exists (select 1 from public.eventos_funil e where e.paciente_id = p.id);
  update public.pacientes p set legado = jsonb_build_object('fonte', 'cloudia_planilha')
   where p.telefone = any (tels)
     and not exists (select 1 from _esp_src s where s.tel = p.telefone);

  get diagnostics n = row_count;
  return coalesce(array_length(tels, 1), 0);
end $$;

-- ------------------------------------------------------------
-- Comissões, listas e configurações (pequenas: refaz inteiras)
-- ------------------------------------------------------------
create or replace function public.espelhar_extras_do_crm(linha public.crm_sessions)
returns void
language plpgsql security definer set search_path = public, migracao, pg_temp as $$
begin
  if linha.email_clinica = 'bulhoes-clinica-crm' then
    delete from public.comissoes where true;  -- a Supabase recusa DELETE sem filtro vindo do site
    insert into public.comissoes
      (data, paciente_nome, telefone, avaliador, crc, valor_tratamento, entrada, pagamento,
       comissao_avaliador, comissao_crc, status, obs, origem, criado_em)
    select migracao.dt(c->>'data'), nullif(c->>'paciente', ''), migracao.tel(c->>'telefone'),
           nullif(c->>'avaliador', ''), nullif(c->>'crc', ''), migracao.num(c->>'valorTrat'), migracao.num(c->>'entrada'),
           nullif(c->>'pgto', ''), migracao.num(c->>'comAval'), migracao.num(c->>'comCrc'),
           nullif(c->>'status', ''), nullif(c->>'obs', ''), nullif(c->>'origem', ''),
           coalesce(migracao.ts(c->>'criadoEm'), now())
    from jsonb_array_elements(case when jsonb_typeof(linha.comissoes_json::jsonb) = 'array' then linha.comissoes_json::jsonb else '[]'::jsonb end) x(c)
    where jsonb_typeof(c) = 'object';

    if linha.listas_json is not null and jsonb_typeof(linha.listas_json::jsonb) = 'object' then
      delete from public.listas where true;
      insert into public.listas (tipo, valor, ordem, ativo, fixo)
      select distinct on (l.tipo, l.valor) l.tipo, l.valor, l.ordem, l.ativo, l.fixo
      from (
        select e.key as tipo, btrim(it.value #>> '{}') as valor, it.ordinality::int as ordem,
               g.grupo <> 'desativos' as ativo, g.grupo = 'padroes' as fixo, g.prio
        from jsonb_each(linha.listas_json::jsonb) e,
             lateral (values ('padroes', 1), ('ativos', 2), ('desativos', 3)) g(grupo, prio),
             lateral jsonb_array_elements(case when jsonb_typeof(e.value -> g.grupo) = 'array' then e.value -> g.grupo else '[]'::jsonb end)
                     with ordinality it(value, ordinality)
      ) l
      where l.valor is not null and l.valor <> ''
      order by l.tipo, l.valor, l.prio;
    end if;

    insert into public.configuracoes (chave, valor, atualizado_por)
    select 'ajustes_dashboard', linha.crm_json::jsonb->'__manuais__', 'espelho'
    where linha.crm_json::jsonb ? '__manuais__'
    on conflict (chave) do update set valor = excluded.valor, atualizado_por = 'espelho';
    insert into public.configuracoes (chave, valor, atualizado_por)
    select 'exclusoes', linha.crm_json::jsonb->'__exclusoes__', 'espelho'
    where linha.crm_json::jsonb ? '__exclusoes__'
    on conflict (chave) do update set valor = excluded.valor, atualizado_por = 'espelho';
  elsif linha.email_clinica in ('bulhoes-fluxo-tratamento', 'bulhoes-calendario-sazonal', 'bulhoes-agenda-avaliacoes')
        and linha.crm_json is not null then
    insert into public.configuracoes (chave, valor, atualizado_por)
    values (case linha.email_clinica
              when 'bulhoes-fluxo-tratamento' then 'fluxo_tratamento'
              when 'bulhoes-calendario-sazonal' then 'calendario_sazonal'
              else 'agenda_avaliacoes' end,
            linha.crm_json::jsonb, 'espelho')
    on conflict (chave) do update set valor = excluded.valor, atualizado_por = 'espelho';
  end if;
end $$;

-- ------------------------------------------------------------
-- Gatilho no crm_sessions (nunca bloqueia a gravação do CRM)
-- ------------------------------------------------------------
create or replace function public.t_espelhar_crm()
returns trigger
language plpgsql security definer set search_path = public, migracao, pg_temp as $$
declare
  novo jsonb; velho jsonb; mudados text[];
begin
  if not public.espelho_ligado() then return new; end if;
  -- pacientes e extras em blocos separados: um erro num não impede o outro
  begin
    if new.email_clinica = 'bulhoes-clinica-crm' then
      if tg_op = 'INSERT' or new.crm_json is distinct from old.crm_json then
        novo := coalesce(new.crm_json::jsonb, '{}'::jsonb);
        velho := case when tg_op = 'UPDATE' then coalesce(old.crm_json::jsonb, '{}'::jsonb) else '{}'::jsonb end;
        select array_agg(distinct migracao.tel(k)) into mudados
        from (
          select coalesce(n.key, o.key) as k
          from jsonb_each(novo) n full join jsonb_each(velho) o on o.key = n.key
          where n.value is distinct from o.value
        ) d
        where k ~ '^\d+$' and migracao.tel(k) is not null;
        if mudados is not null then
          perform public.espelhar_pacientes_do_crm(mudados, novo);
        end if;
      end if;
    end if;
  exception when others then
    insert into public.espelho_erros (origem, erro, detalhe)
    values ('pacientes:' || new.email_clinica, sqlerrm, sqlstate);
  end;
  begin
    if new.email_clinica = 'bulhoes-clinica-crm' then
      if tg_op = 'INSERT' or new.crm_json is distinct from old.crm_json
         or new.comissoes_json is distinct from old.comissoes_json
         or new.listas_json is distinct from old.listas_json then
        perform public.espelhar_extras_do_crm(new);
      end if;
    else
      perform public.espelhar_extras_do_crm(new);
    end if;
  exception when others then
    insert into public.espelho_erros (origem, erro, detalhe)
    values ('extras:' || new.email_clinica, sqlerrm, sqlstate);
  end;
  return new;
end $$;

drop trigger if exists t_espelhar_crm on public.crm_sessions;
create trigger t_espelhar_crm
  after insert or update on public.crm_sessions
  for each row execute function public.t_espelhar_crm();

-- ------------------------------------------------------------
-- Planilha da Cloudia → eventos do funil (chamada pelo Apps Script)
-- Mesmas regras da importação (005).
-- ------------------------------------------------------------
create or replace function public.espelhar_planilha_cloudia()
returns jsonb
language plpgsql security definer set search_path = public, migracao, pg_temp as $$
declare r jsonb;
begin
  if not public.espelho_ligado() then return jsonb_build_object('status', 'desligado'); end if;
  if not exists (select 1 from public.importacao_cloudia) then
    return jsonb_build_object('status', 'vazio');
  end if;

  drop table if exists _ev;
  create temp table _ev as
  select i.*, migracao.tel(i.phone) as tel,
         coalesce(migracao.ts(i."timestamp"), migracao.ts(i.created_at)) as quando
  from public.importacao_cloudia i;

  insert into public.pacientes (telefone, nome, origem, etapa, criado_em, legado)
  select tel,
         (array_remove(array_agg(nullif(btrim(name), '') order by quando desc nulls last), null))[1],
         (array_remove(array_agg(nullif(btrim(origin), '') order by quando desc nulls last), null))[1],
         (array_remove(array_agg(nullif(btrim(stage), '') order by quando desc nulls last), null))[1],
         coalesce(min(coalesce(migracao.ts(created_at), quando)), now()),
         jsonb_build_object('fonte', 'cloudia_planilha')
  from _ev
  where tel ~ '^[0-9]{10,13}$'
  group by tel
  on conflict (telefone) do nothing;

  delete from public.eventos_funil where fonte = 'cloudia_planilha';

  insert into public.eventos_funil
    (paciente_id, telefone, tipo, etapa, origem, ad_id, ad_name, adset_name, campaign_name,
     cloudia_customer_id, valor, ocorrido_em, criado_na_cloudia, fonte, bruto)
  select p.id, e.tel, btrim(e.type), nullif(btrim(e.stage), ''), nullif(btrim(e.origin), ''),
         migracao.ad_id(e.ad_id), nullif(btrim(e.ad_name), ''), nullif(btrim(e.adset_name), ''),
         nullif(btrim(e.campaign_name), ''), nullif(btrim(e.customer_id), ''),
         migracao.num(e.value), e.quando, migracao.ts(e.created_at), 'cloudia_planilha',
         to_jsonb(e) - 'tel' - 'quando' - 'recebido_em'
  from _ev e
  join public.pacientes p on p.telefone = e.tel
  where e.tel ~ '^[0-9]{10,13}$' and e.quando is not null and coalesce(btrim(e.type), '') <> ''
  order by (nullif(btrim(e.ad_id), '') is not null) desc, (nullif(btrim(e.ad_name), '') is not null) desc,
           (nullif(btrim(e.origin), '') is not null) desc, (nullif(btrim(e.value), '') is not null) desc, e.linha desc
  on conflict do nothing;

  select jsonb_build_object(
    'status', 'ok',
    'linhas', (select count(*) from _ev),
    'eventos', (select count(*) from public.eventos_funil where fonte = 'cloudia_planilha'),
    'pacientes', (select count(*) from public.pacientes)) into r;
  return r;
exception when others then
  insert into public.espelho_erros (origem, erro, detalhe) values ('planilha_cloudia', sqlerrm, sqlstate);
  return jsonb_build_object('status', 'erro', 'erro', sqlerrm);
end $$;

revoke all on function public.espelhar_planilha_cloudia() from public, anon, authenticated;
revoke all on function public.espelhar_pacientes_do_crm(text[], jsonb) from public, anon, authenticated;
revoke all on function public.espelhar_extras_do_crm(public.crm_sessions) from public, anon, authenticated;
grant execute on function public.espelhar_planilha_cloudia() to service_role;

-- Preenche a nova coluna criado_na_cloudia nos eventos já importados
update public.eventos_funil set criado_na_cloudia = migracao.ts(bruto->>'created_at')
 where criado_na_cloudia is null and fonte = 'cloudia_planilha';

select 'espelho instalado' as status,
       (select count(*) from pg_trigger where tgname = 't_espelhar_crm')::text as gatilho,
       public.espelho_ligado()::text as ligado;
