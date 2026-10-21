-- ============================================================
-- CRM Bulhões — planilha da Cloudia ao vivo na Supabase (21/10/2026)
--
-- Objetivo: o CRM ler os eventos da Cloudia direto da Supabase (rápido) em
-- vez de baixar a planilha pelo Apps Script (40–90 s), sem estourar o plano
-- gratuito.
--   • importacao_cloudia vira uma cópia viva da aba Leads, linha a linha.
--     Cada linha guarda quando mudou (recebido_em) e se ainda existe (ativo),
--     para o CRM buscar só o que mudou desde a última vez.
--   • espelhar_linhas_cloudia(): o Apps Script chama logo depois de cada
--     alteração na planilha, com as linhas do(s) telefone(s) alterado(s).
--   • A cópia completa de 15 em 15 min passa a gravar numa área de lote e só
--     marca como alteradas as linhas que de fato mudaram.
--   • A equipe logada pode ler importacao_cloudia (só leitura).
-- Rodar no Supabase: SQL Editor → New query → colar tudo → Run.
-- ============================================================

alter table public.importacao_cloudia add column if not exists ativo boolean not null default true;
create index if not exists importacao_cloudia_recebido on public.importacao_cloudia (recebido_em);
create index if not exists importacao_cloudia_tel on public.importacao_cloudia (migracao.tel(phone));

create table if not exists public.importacao_cloudia_lote (like public.importacao_cloudia including defaults);
alter table public.importacao_cloudia_lote drop column if exists ativo;
alter table public.importacao_cloudia_lote drop column if exists recebido_em;
alter table public.importacao_cloudia_lote enable row level security;
revoke all on public.importacao_cloudia_lote from anon, authenticated;
do $$ begin
  alter table public.importacao_cloudia_lote add primary key (linha);
exception when others then null; end $$;

-- Padroniza vazio como "sem valor" nas linhas já copiadas
update public.importacao_cloudia set
  "timestamp" = nullif("timestamp", ''), type = nullif(type, ''), customer_id = nullif(customer_id, ''),
  name = nullif(name, ''), phone = nullif(phone, ''), stage = nullif(stage, ''), value = nullif(value, ''),
  ad_id = nullif(ad_id, ''), ad_name = nullif(ad_name, ''), adset_name = nullif(adset_name, ''),
  campaign_name = nullif(campaign_name, ''), origin = nullif(origin, ''), created_at = nullif(created_at, '')
where '' in ("timestamp", type, customer_id, name, phone, stage, value, ad_id, ad_name, adset_name, campaign_name, origin, created_at);

-- Leitura pela equipe
drop policy if exists importacao_ver on public.importacao_cloudia;
create policy importacao_ver on public.importacao_cloudia for select to authenticated
  using (public.is_equipe_crm());
grant select on public.importacao_cloudia to authenticated;

-- ------------------------------------------------------------
-- Eventos de um conjunto de telefones, a partir das linhas ativas
-- ------------------------------------------------------------
create or replace function public.refazer_eventos_cloudia(tels text[])
returns void
language plpgsql security definer set search_path = public, migracao, pg_temp as $$
begin
  drop table if exists _evt;
  create temp table _evt as
  select i.*, migracao.tel(i.phone) as tel,
         coalesce(migracao.ts(i."timestamp"), migracao.ts(i.created_at)) as quando
  from public.importacao_cloudia i
  where i.ativo and (tels is null or migracao.tel(i.phone) = any (tels));

  insert into public.pacientes (telefone, nome, origem, etapa, criado_em, legado)
  select tel,
         (array_remove(array_agg(nullif(btrim(name), '') order by quando desc nulls last), null))[1],
         (array_remove(array_agg(nullif(btrim(origin), '') order by quando desc nulls last), null))[1],
         (array_remove(array_agg(nullif(btrim(stage), '') order by quando desc nulls last), null))[1],
         coalesce(min(coalesce(migracao.ts(created_at), quando)), now()),
         jsonb_build_object('fonte', 'cloudia_planilha')
  from _evt where tel ~ '^[0-9]{10,13}$'
  group by tel
  on conflict (telefone) do nothing;

  if tels is null then
    delete from public.eventos_funil where fonte = 'cloudia_planilha';
  else
    delete from public.eventos_funil where fonte = 'cloudia_planilha' and telefone = any (tels);
  end if;

  insert into public.eventos_funil
    (paciente_id, telefone, tipo, etapa, origem, ad_id, ad_name, adset_name, campaign_name,
     cloudia_customer_id, valor, ocorrido_em, criado_na_cloudia, fonte, bruto)
  select p.id, e.tel, btrim(e.type), nullif(btrim(e.stage), ''), nullif(btrim(e.origin), ''),
         migracao.ad_id(e.ad_id), nullif(btrim(e.ad_name), ''), nullif(btrim(e.adset_name), ''),
         nullif(btrim(e.campaign_name), ''), nullif(btrim(e.customer_id), ''),
         migracao.num(e.value), e.quando, migracao.ts(e.created_at), 'cloudia_planilha',
         to_jsonb(e) - 'tel' - 'quando' - 'recebido_em' - 'ativo'
  from _evt e
  join public.pacientes p on p.telefone = e.tel
  where e.tel ~ '^[0-9]{10,13}$' and e.quando is not null and coalesce(btrim(e.type), '') <> ''
  order by (nullif(btrim(e.ad_id), '') is not null) desc, (nullif(btrim(e.ad_name), '') is not null) desc,
           (nullif(btrim(e.origin), '') is not null) desc, (nullif(btrim(e.value), '') is not null) desc, e.linha desc
  on conflict do nothing;
end $$;

-- ------------------------------------------------------------
-- Alteração pontual: linhas atuais de alguns telefones
-- ------------------------------------------------------------
drop function if exists public.espelhar_linhas_cloudia(text[], jsonb);
create or replace function public.espelhar_linhas_cloudia(telefones text[], linhas jsonb, removidas integer[] default null)
returns jsonb
language plpgsql security definer set search_path = public, migracao, pg_temp as $$
declare alteradas integer := 0;
begin
  if not public.espelho_ligado() then return jsonb_build_object('status', 'desligado'); end if;
  if telefones is null or array_length(telefones, 1) is null then return jsonb_build_object('status', 'vazio'); end if;

  -- Linhas apagadas da planilha (apagar lead, desfazer Ganho): as de baixo
  -- sobem. Renumera a cópia igual e avisa os CRMs abertos para recarregarem.
  if removidas is not null and array_length(removidas, 1) is not null then
    delete from public.importacao_cloudia where linha = any (removidas);
    update public.importacao_cloudia i
       set linha = -(i.linha - (select count(*) from unnest(removidas) r where r < i.linha))
     where i.linha > (select min(r) from unnest(removidas) r);
    update public.importacao_cloudia set linha = -linha, recebido_em = now() where linha < 0;
    insert into public.configuracoes (chave, valor, atualizado_por)
    values ('cloudia_renumerado_em', to_jsonb(now()), 'espelho')
    on conflict (chave) do update set valor = excluded.valor;
  end if;

  drop table if exists _novas;
  create temp table _novas as
  select (x->>'linha')::int as linha, nullif(x->>'timestamp', '') as "timestamp", nullif(x->>'type', '') as type,
         nullif(x->>'customer_id', '') as customer_id, nullif(x->>'name', '') as name, nullif(x->>'phone', '') as phone, nullif(x->>'stage', '') as stage,
         nullif(x->>'value', '') as value, nullif(x->>'ad_id', '') as ad_id, nullif(x->>'ad_name', '') as ad_name, nullif(x->>'adset_name', '') as adset_name,
         nullif(x->>'campaign_name', '') as campaign_name, nullif(x->>'origin', '') as origin, nullif(x->>'created_at', '') as created_at
  from jsonb_array_elements(coalesce(linhas, '[]'::jsonb)) x;

  -- linhas desses telefones que sumiram da planilha
  update public.importacao_cloudia i set ativo = false, recebido_em = now()
   where i.ativo and migracao.tel(i.phone) = any (telefones)
     and not exists (select 1 from _novas n where n.linha = i.linha);

  -- novas ou alteradas
  insert into public.importacao_cloudia
    (linha, "timestamp", type, customer_id, name, phone, stage, value, ad_id, ad_name, adset_name, campaign_name, origin, created_at, ativo, recebido_em)
  select n.*, true, now() from _novas n
  on conflict (linha) do update set
    "timestamp" = excluded."timestamp", type = excluded.type, customer_id = excluded.customer_id,
    name = excluded.name, phone = excluded.phone, stage = excluded.stage, value = excluded.value,
    ad_id = excluded.ad_id, ad_name = excluded.ad_name, adset_name = excluded.adset_name,
    campaign_name = excluded.campaign_name, origin = excluded.origin, created_at = excluded.created_at,
    ativo = true, recebido_em = now()
  where (importacao_cloudia."timestamp", importacao_cloudia.type, importacao_cloudia.customer_id, importacao_cloudia.name,
         importacao_cloudia.phone, importacao_cloudia.stage, importacao_cloudia.value, importacao_cloudia.ad_id,
         importacao_cloudia.ad_name, importacao_cloudia.adset_name, importacao_cloudia.campaign_name,
         importacao_cloudia.origin, importacao_cloudia.created_at, importacao_cloudia.ativo)
        is distinct from
        (excluded."timestamp", excluded.type, excluded.customer_id, excluded.name, excluded.phone, excluded.stage,
         excluded.value, excluded.ad_id, excluded.ad_name, excluded.adset_name, excluded.campaign_name,
         excluded.origin, excluded.created_at, true);
  get diagnostics alteradas = row_count;

  perform public.refazer_eventos_cloudia(telefones);
  return jsonb_build_object('status', 'ok', 'linhas', (select count(*) from _novas), 'alteradas', alteradas);
exception when others then
  insert into public.espelho_erros (origem, erro, detalhe) values ('linhas_cloudia', sqlerrm, sqlstate);
  return jsonb_build_object('status', 'erro', 'erro', sqlerrm);
end $$;

-- ------------------------------------------------------------
-- Cópia completa (15 em 15 min): compara o lote com a cópia viva
-- ------------------------------------------------------------
create or replace function public.espelhar_planilha_cloudia()
returns jsonb
language plpgsql security definer set search_path = public, migracao, pg_temp as $$
declare alteradas integer := 0; removidas integer := 0;
begin
  if not public.espelho_ligado() then return jsonb_build_object('status', 'desligado'); end if;
  if not exists (select 1 from public.importacao_cloudia_lote) then
    return jsonb_build_object('status', 'lote vazio');
  end if;

  update public.importacao_cloudia i set ativo = false, recebido_em = now()
   where i.ativo and not exists (select 1 from public.importacao_cloudia_lote l where l.linha = i.linha);
  get diagnostics removidas = row_count;

  insert into public.importacao_cloudia
    (linha, "timestamp", type, customer_id, name, phone, stage, value, ad_id, ad_name, adset_name, campaign_name, origin, created_at, ativo, recebido_em)
  select l.linha, nullif(l."timestamp", ''), nullif(l.type, ''), nullif(l.customer_id, ''), nullif(l.name, ''),
         nullif(l.phone, ''), nullif(l.stage, ''), nullif(l.value, ''), nullif(l.ad_id, ''), nullif(l.ad_name, ''),
         nullif(l.adset_name, ''), nullif(l.campaign_name, ''), nullif(l.origin, ''), nullif(l.created_at, ''), true, now()
  from public.importacao_cloudia_lote l
  on conflict (linha) do update set
    "timestamp" = excluded."timestamp", type = excluded.type, customer_id = excluded.customer_id,
    name = excluded.name, phone = excluded.phone, stage = excluded.stage, value = excluded.value,
    ad_id = excluded.ad_id, ad_name = excluded.ad_name, adset_name = excluded.adset_name,
    campaign_name = excluded.campaign_name, origin = excluded.origin, created_at = excluded.created_at,
    ativo = true, recebido_em = now()
  where (importacao_cloudia."timestamp", importacao_cloudia.type, importacao_cloudia.customer_id, importacao_cloudia.name,
         importacao_cloudia.phone, importacao_cloudia.stage, importacao_cloudia.value, importacao_cloudia.ad_id,
         importacao_cloudia.ad_name, importacao_cloudia.adset_name, importacao_cloudia.campaign_name,
         importacao_cloudia.origin, importacao_cloudia.created_at, importacao_cloudia.ativo)
        is distinct from
        (excluded."timestamp", excluded.type, excluded.customer_id, excluded.name, excluded.phone, excluded.stage,
         excluded.value, excluded.ad_id, excluded.ad_name, excluded.adset_name, excluded.campaign_name,
         excluded.origin, excluded.created_at, true);
  get diagnostics alteradas = row_count;

  delete from public.importacao_cloudia_lote where true;

  if alteradas > 0 or removidas > 0 then
    perform public.refazer_eventos_cloudia(null);
  end if;

  return jsonb_build_object('status', 'ok', 'alteradas', alteradas, 'removidas', removidas,
    'linhas_ativas', (select count(*) from public.importacao_cloudia where ativo),
    'eventos', (select count(*) from public.eventos_funil));
exception when others then
  insert into public.espelho_erros (origem, erro, detalhe) values ('planilha_cloudia', sqlerrm, sqlstate);
  return jsonb_build_object('status', 'erro', 'erro', sqlerrm);
end $$;

revoke all on function public.refazer_eventos_cloudia(text[]) from public, anon, authenticated;
revoke all on function public.espelhar_linhas_cloudia(text[], jsonb, integer[]) from public, anon, authenticated;
revoke all on function public.espelhar_planilha_cloudia() from public, anon, authenticated;
grant execute on function public.espelhar_linhas_cloudia(text[], jsonb, integer[]) to service_role;
grant execute on function public.espelhar_planilha_cloudia() to service_role;

select 'planilha ao vivo pronta' as status,
       (select count(*) from public.importacao_cloudia where ativo) as linhas_ativas;
