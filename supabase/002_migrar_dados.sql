-- ============================================================
-- CRM Bulhões — Fase 1, etapa 2: migrar os dados do CRM atual
-- 20/10/2026
--
-- Copia o CRM atual (crm_sessions) para as tabelas novas:
--   pacientes, orcamentos, atividades, anotacoes, comissoes, listas, configuracoes.
--
-- • NÃO altera nem apaga nada do CRM atual (só lê).
-- • Pode ser rodado de novo: limpa as tabelas novas e copia tudo outra vez,
--   até a virada (depois dela, o script se recusa a rodar).
-- • Telefones duplicados (com/sem 55, sem o 9) viram um paciente só, com a
--   mesma regra que o CRM usa na tela.
-- • Nada se perde: o que não cabe numa coluna fica no campo "legado".
-- • Os eventos da Cloudia (planilha do Google) entram na etapa 3.
--
-- Rodar no Supabase: SQL Editor → New query → colar tudo → Run.
-- ============================================================

-- Trava de segurança: depois da virada, este script não roda mais.
do $$ begin
  if exists (select 1 from public.configuracoes where chave = 'virada_concluida') then
    raise exception 'A virada já foi feita. Esta migração não pode mais ser rodada.';
  end if;
end $$;

-- ------------------------------------------------------------
-- Funções de conversão (tentam vários formatos; se não der, devolvem null)
-- ------------------------------------------------------------
create schema if not exists migracao;
revoke all on schema migracao from anon, authenticated;

create or replace function migracao.tel(t text) returns text
language plpgsql immutable as $$
declare d text := regexp_replace(coalesce(t, ''), '\D', '', 'g');
begin
  if d like '55%' and length(d) in (12, 13) then d := substr(d, 3); end if;
  if length(d) = 10 then d := substr(d, 1, 2) || '9' || substr(d, 3); end if;
  return nullif(d, '');
end $$;

create or replace function migracao.ts(t text) returns timestamptz
language plpgsql stable as $$
declare s text := btrim(coalesce(t, ''));
begin
  if s = '' then return null; end if;
  if s ~ '^\d{10,13}$' then   -- epoch em segundos ou milissegundos
    return to_timestamp(case when length(s) = 13 then s::numeric / 1000 else s::numeric end);
  end if;
  if s ~ '^\d{1,2}/\d{1,2}/\d{4}' then   -- dd/mm/aaaa [hh:mm[:ss]]
    begin
      return to_timestamp(s, case when s ~ '\d{1,2}:\d{2}:\d{2}' then 'DD/MM/YYYY HH24:MI:SS'
                                  when s ~ '\d{1,2}:\d{2}' then 'DD/MM/YYYY HH24:MI'
                                  else 'DD/MM/YYYY' end)::timestamp at time zone 'America/Sao_Paulo';
    exception when others then return null; end;
  end if;
  begin
    if s ~ '(Z|[+-]\d{2}:?\d{2})$' then return s::timestamptz; end if;
    return s::timestamp at time zone 'America/Sao_Paulo';   -- sem fuso = horário de Brasília
  exception when others then return null; end;
end $$;

create or replace function migracao.dt(t text) returns date
language plpgsql stable as $$
begin
  return (migracao.ts(t) at time zone 'America/Sao_Paulo')::date;
end $$;

create or replace function migracao.num(t text) returns numeric
language plpgsql immutable as $$
declare s text := regexp_replace(coalesce(t, ''), '[^0-9,.\-]', '', 'g');
begin
  if s = '' or s = '-' then return null; end if;
  if s ~ ',' and s ~ '\.' then                       -- 1.234,56
    s := replace(replace(s, '.', ''), ',', '.');
  elsif s ~ ',\d{1,2}$' then                          -- 1234,56
    s := replace(s, ',', '.');
  elsif s ~ '^-?\d{1,3}(\.\d{3})+$' then             -- 1.234 (milhar)
    s := replace(s, '.', '');
  else
    s := replace(s, ',', '');
  end if;
  return s::numeric;
exception when others then return null;
end $$;

create or replace function migracao.bool(t text) returns boolean
language sql immutable as $$
  select case lower(btrim(coalesce(t, '')))
    when 'true' then true when 'sim' then true when 's' then true when '1' then true when 'yes' then true
    when 'false' then false when 'nao' then false when 'não' then false when 'n' then false when '0' then false
    when 'no' then false else null end;
$$;

-- ------------------------------------------------------------
-- Limpa as tabelas novas (só dados da migração anterior, se houver)
-- ------------------------------------------------------------
truncate public.anotacoes, public.atividades, public.orcamentos, public.agendamentos,
         public.eventos_funil, public.pacientes, public.comissoes, public.listas
         restart identity cascade;
delete from public.configuracoes
 where chave in ('ajustes_dashboard','exclusoes','legado_planilha','legado_telefones_invalidos',
                 'fluxo_tratamento','calendario_sazonal','agenda_avaliacoes');

-- Tabelas de trabalho (temporárias, somem ao fechar a sessão)
drop table if exists _crm, _crm_ord, _pac, _orc, _orc_unico, _origem_orc;

-- ------------------------------------------------------------
-- Fonte: o bloco atual do CRM
-- ------------------------------------------------------------
create temp table _crm as
select k as chave, v as dado, migracao.tel(k) as tel,
       (k = migracao.tel(k)) as canonica
from public.crm_sessions s,
     lateral jsonb_each(s.crm_json::jsonb) as e(k, v)
where s.email_clinica = 'bulhoes-clinica-crm'
  and k ~ '^\d+$'
  and jsonb_typeof(v) = 'object';

-- prioridade: a chave já normalizada vem primeiro (mesma regra da tela)
create temp table _crm_ord as
select *, row_number() over (partition by tel order by canonica desc, chave) as prio
from _crm;

-- ------------------------------------------------------------
-- Pacientes (um por telefone normalizado)
-- ------------------------------------------------------------
create temp table _pac as
select
  tel,
  (array_remove(array_agg(nullif(dado->>'nomeAtual', '') order by prio), null))[1]   as nome,
  (array_remove(array_agg(nullif(dado->>'origemAtual', '') order by prio), null))[1] as origem,
  (array_remove(array_agg(nullif(dado->>'statusAtual', '') order by prio), null))[1] as etapa,
  (array_remove(array_agg(migracao.ts(dado->>'statusAtualEditedAt') order by prio), null))[1] as etapa_alterada_em,
  coalesce(bool_or(migracao.bool(dado->>'leadImportado')), false)        as lead_importado,
  coalesce(bool_or(migracao.bool(dado->>'editadoManualmente')), false)   as editado_manualmente,
  (array_remove(array_agg(nullif(dado->>'adIdManual', '') order by prio), null))[1] as ad_id_manual,
  (array_remove(array_agg(migracao.ts(dado->>'created_at') order by prio), null))[1] as criado_em,
  -- legado: cada registro original sem as listas (que viram tabelas próprias)
  jsonb_agg(jsonb_build_object('chave_original', chave) ||
            (dado - 'orcamentos' - 'atividades' - 'anotacoes') order by prio) as legado
from _crm_ord
group by tel;

insert into public.pacientes
  (telefone, nome, origem, etapa, etapa_alterada_em, lead_importado, editado_manualmente,
   ad_id_manual, criado_em, legado)
select tel, nome, origem, etapa, etapa_alterada_em, lead_importado, editado_manualmente,
       ad_id_manual, coalesce(criado_em, now()), legado
from _pac
where tel ~ '^[0-9]{10,13}$';

-- Telefones fora do padrão não viram paciente, mas ficam guardados
insert into public.configuracoes (chave, valor, atualizado_por)
select 'legado_telefones_invalidos', coalesce(jsonb_object_agg(c.chave, c.dado), '{}'::jsonb), 'migracao'
from _crm c
where c.tel is null or c.tel !~ '^[0-9]{10,13}$';

-- paciente antigo: algum orçamento marcado como paciente antigo
-- (preenchido depois dos orçamentos, abaixo)

-- ------------------------------------------------------------
-- Orçamentos (sem duplicar quando a mesma venda aparece em duas chaves)
-- ------------------------------------------------------------
create temp table _orc as
select p.id as paciente_id, o.value as o, c.prio, o.ordinality as pos,
       coalesce('c' || nullif(o.value->>'_clinicorpId', ''), md5(o.value::text)) as id_unico
from _crm_ord c
join public.pacientes p on p.telefone = c.tel
cross join lateral jsonb_array_elements(
  case when jsonb_typeof(c.dado->'orcamentos') = 'array' then c.dado->'orcamentos' else '[]'::jsonb end
) with ordinality as o(value, ordinality)
where jsonb_typeof(o.value) = 'object';

create temp table _orc_unico as
select distinct on (paciente_id, id_unico) *
from _orc
order by paciente_id, id_unico, prio, pos;

insert into public.orcamentos
  (paciente_id, data, tratamento, valor, entrada, entrada_data, entrada_forma, pagamento, parcelas,
   avaliador, crc_participou, crc_nome, status, fechamento_data, fechamento_valor, tem_entrada,
   paciente_antigo, clinicorp_id, clinicorp_tratamento_id, origem_clinicorp, obs, legado)
select
  paciente_id,
  migracao.dt(o->>'data'),
  nullif(o->>'tratamento', ''),
  migracao.num(o->>'valor'),
  migracao.num(o->>'entrada'),
  migracao.dt(o->>'entradaData'),
  nullif(o->>'entradaPgto', ''),
  nullif(o->>'pagamento', ''),
  migracao.num(o->>'parcelas')::integer,
  nullif(o->>'avaliador', ''),
  migracao.bool(o->>'crcParticip'),
  nullif(o->>'crcNome', ''),
  nullif(o->>'status', ''),
  migracao.dt(o->>'fechData'),
  migracao.num(o->>'fechValor'),
  migracao.bool(o->>'temEntrada'),
  migracao.bool(o->>'pacienteAntigo'),
  -- o mesmo ID do Clinicorp em dois pacientes diferentes: só o primeiro fica com o ID
  case when row_number() over (partition by nullif(o->>'_clinicorpId', '') order by paciente_id, prio, pos) = 1
       then nullif(o->>'_clinicorpId', '') end,
  nullif(o->>'_treatmentId', ''),
  migracao.bool(o->>'origemClinicorp'),
  nullif(o->>'obs', ''),
  o
from _orc_unico;

update public.pacientes p set paciente_antigo = true
where exists (select 1 from public.orcamentos o where o.paciente_id = p.id and o.paciente_antigo);

-- ------------------------------------------------------------
-- Atividades e anotações
-- ------------------------------------------------------------
insert into public.atividades (paciente_id, fase, quando, probabilidade, proximo_passo, obs, autor_email, criado_em)
select distinct on (p.id, a.value::text)
  p.id,
  nullif(a.value->>'fase', ''),
  coalesce(migracao.ts(concat_ws(' ', a.value->>'data', a.value->>'hora')), migracao.ts(a.value->>'data')),
  nullif(a.value->>'prob', ''),
  nullif(a.value->>'proximo', ''),
  nullif(a.value->>'obs', ''),
  'migracao@crm-antigo',
  coalesce(migracao.ts(a.value->>'data'), now())
from _crm_ord c
join public.pacientes p on p.telefone = c.tel
cross join lateral jsonb_array_elements(
  case when jsonb_typeof(c.dado->'atividades') = 'array' then c.dado->'atividades' else '[]'::jsonb end
) as a(value)
where jsonb_typeof(a.value) = 'object'
order by p.id, a.value::text, c.prio;

insert into public.anotacoes (paciente_id, texto, autor_email, legado_id, criado_em)
select distinct on (coalesce(nullif(n.value->>'id', ''), md5(p.id::text || n.value::text)))
  p.id,
  coalesce(nullif(n.value->>'text', ''), nullif(n.value->>'texto', ''), nullif(n.value->>'obs', ''), n.value::text),
  'migracao@crm-antigo',
  nullif(n.value->>'id', ''),
  coalesce(migracao.ts(n.value->>'createdAt'), migracao.ts(n.value->>'date'), migracao.ts(n.value->>'data'), now())
from _crm_ord c
join public.pacientes p on p.telefone = c.tel
cross join lateral jsonb_array_elements(
  case when jsonb_typeof(c.dado->'anotacoes') = 'array' then c.dado->'anotacoes' else '[]'::jsonb end
) as n(value)
where n.value is not null and n.value <> 'null'::jsonb
order by coalesce(nullif(n.value->>'id', ''), md5(p.id::text || n.value::text)), c.prio;

-- ------------------------------------------------------------
-- Comissões, listas e configurações
-- ------------------------------------------------------------
insert into public.comissoes
  (data, paciente_nome, telefone, avaliador, crc, valor_tratamento, entrada, pagamento,
   comissao_avaliador, comissao_crc, status, obs, origem, criado_em)
select
  migracao.dt(c->>'data'), nullif(c->>'paciente', ''), migracao.tel(c->>'telefone'),
  nullif(c->>'avaliador', ''), nullif(c->>'crc', ''),
  migracao.num(c->>'valorTrat'), migracao.num(c->>'entrada'), nullif(c->>'pgto', ''),
  migracao.num(c->>'comAval'), migracao.num(c->>'comCrc'),
  nullif(c->>'status', ''), nullif(c->>'obs', ''), nullif(c->>'origem', ''),
  coalesce(migracao.ts(c->>'criadoEm'), now())
from public.crm_sessions s,
     lateral jsonb_array_elements(
       case when jsonb_typeof(s.comissoes_json::jsonb) = 'array' then s.comissoes_json::jsonb else '[]'::jsonb end
     ) as x(c)
where s.email_clinica = 'bulhoes-clinica-crm' and jsonb_typeof(c) = 'object';

-- Listas: cada tipo guarda {padroes, ativos, desativos}.
-- padroes = itens fixos do sistema (fixo), ativos = aparecem nas opções,
-- desativos = escondidos das opções mas mantidos (ativo = false).
alter table public.listas add column if not exists fixo boolean not null default false;
insert into public.listas (tipo, valor, ordem, ativo, fixo)
select distinct on (l.tipo, l.valor) l.tipo, l.valor, l.ordem, l.ativo, l.fixo
from (
  select e.key as tipo, btrim(it.value #>> '{}') as valor, it.ordinality::int as ordem,
         g.grupo <> 'desativos' as ativo, g.grupo = 'padroes' as fixo, g.prio
  from public.crm_sessions s,
       lateral jsonb_each(case when jsonb_typeof(s.listas_json::jsonb) = 'object' then s.listas_json::jsonb else '{}'::jsonb end) e,
       lateral (values ('padroes', 1), ('ativos', 2), ('desativos', 3)) g(grupo, prio),
       lateral jsonb_array_elements(case when jsonb_typeof(e.value -> g.grupo) = 'array' then e.value -> g.grupo else '[]'::jsonb end)
               with ordinality it(value, ordinality)
  where s.email_clinica = 'bulhoes-clinica-crm'
) l
where l.valor is not null and l.valor <> ''
order by l.tipo, l.valor, l.prio;

insert into public.configuracoes (chave, valor, atualizado_por)
select 'ajustes_dashboard', s.crm_json::jsonb->'__manuais__', 'migracao'
from public.crm_sessions s
where s.email_clinica = 'bulhoes-clinica-crm' and s.crm_json::jsonb ? '__manuais__';

insert into public.configuracoes (chave, valor, atualizado_por)
select 'exclusoes', s.crm_json::jsonb->'__exclusoes__', 'migracao'
from public.crm_sessions s
where s.email_clinica = 'bulhoes-clinica-crm' and s.crm_json::jsonb ? '__exclusoes__';

insert into public.configuracoes (chave, valor, atualizado_por)
select 'legado_planilha', coalesce(jsonb_object_agg(k, v), '{}'::jsonb), 'migracao'
from public.crm_sessions s, lateral jsonb_each(s.crm_json::jsonb) e(k, v)
where s.email_clinica = 'bulhoes-clinica-crm' and k like 'planilha::%';

insert into public.configuracoes (chave, valor, atualizado_por)
select case s.email_clinica
         when 'bulhoes-fluxo-tratamento'   then 'fluxo_tratamento'
         when 'bulhoes-calendario-sazonal' then 'calendario_sazonal'
         when 'bulhoes-agenda-avaliacoes'  then 'agenda_avaliacoes' end,
       s.crm_json::jsonb, 'migracao'
from public.crm_sessions s
where s.email_clinica in ('bulhoes-fluxo-tratamento','bulhoes-calendario-sazonal','bulhoes-agenda-avaliacoes')
  and s.crm_json is not null;

-- ------------------------------------------------------------
-- Conferência: CRM antigo × tabelas novas
-- ------------------------------------------------------------
create temp table _origem_orc as
select o.value as o
from _crm c
cross join lateral jsonb_array_elements(
  case when jsonb_typeof(c.dado->'orcamentos') = 'array' then c.dado->'orcamentos' else '[]'::jsonb end
) as o(value)
where jsonb_typeof(o.value) = 'object';

select item, antigo, novo from (values
  (1, 'Registros de cliente no CRM antigo',
      (select count(*) from _crm)::text, '—'),
  (2, 'Pacientes (telefones únicos)',
      (select count(distinct tel) from _crm where tel ~ '^[0-9]{10,13}$')::text,
      (select count(*) from public.pacientes)::text),
  (3, 'Duplicatas de telefone unidas',
      '—', (select (count(*) - count(distinct tel))::text from _crm where tel ~ '^[0-9]{10,13}$')),
  (4, 'Telefones fora do padrão (guardados à parte)',
      '—', (select count(*)::text from _crm where tel is null or tel !~ '^[0-9]{10,13}$')),
  (5, 'Orçamentos (sem repetidos)',
      (select count(distinct coalesce('c' || nullif(o->>'_clinicorpId', ''), md5(o::text))) from _origem_orc)::text,
      (select count(*) from public.orcamentos)::text),
  (6, 'Soma dos valores dos orçamentos (R$)',
      (select translate(to_char(sum(v), 'FM999,999,990.00'), ',.', '.,') from
         (select distinct on (coalesce('c' || nullif(o->>'_clinicorpId', ''), md5(o::text))) migracao.num(o->>'valor') v
          from _origem_orc) z)::text,
      (select translate(to_char(sum(valor), 'FM999,999,990.00'), ',.', '.,') from public.orcamentos)),
  (7, 'Orçamentos com valor que não deu para ler',
      '—', (select count(*)::text from public.orcamentos where valor is null and coalesce(legado->>'valor', '') <> '')),
  (8, 'Orçamentos com data que não deu para ler',
      '—', (select count(*)::text from public.orcamentos where data is null and coalesce(legado->>'data', '') <> '')),
  (9, 'Atividades (repetidas entre fichas duplicadas contam 1 vez)',
      (select count(*) from _crm c, jsonb_array_elements(case when jsonb_typeof(c.dado->'atividades') = 'array' then c.dado->'atividades' else '[]'::jsonb end))::text,
      (select count(*) from public.atividades)::text),
  (10, 'Anotações (repetidas entre fichas duplicadas contam 1 vez)',
      (select count(*) from _crm c, jsonb_array_elements(case when jsonb_typeof(c.dado->'anotacoes') = 'array' then c.dado->'anotacoes' else '[]'::jsonb end))::text,
      (select count(*) from public.anotacoes)::text),
  (11, 'Comissões',
      (select coalesce(jsonb_array_length(comissoes_json::jsonb), 0) from public.crm_sessions where email_clinica = 'bulhoes-clinica-crm')::text,
      (select count(*) from public.comissoes)::text),
  (12, 'Itens de listas', '—', (select count(*) from public.listas)::text),
  (13, 'Configurações copiadas', '—', (select string_agg(chave, ', ' order by chave) from public.configuracoes))
) t(ordem, item, antigo, novo)
order by ordem;
