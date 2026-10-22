-- ============================================================
-- CRM Bulhões — Funil sem o Cloudia (22/10/2026)
--
-- Hoje o Dashboard conta leads, agendamentos, comparecimentos e fechamentos a
-- partir dos eventos que o Cloudia grava na planilha (CUSTOMER_CREATED,
-- CUSTOMER_STAGE_UPDATED, CUSTOMER_ACQUISITION_ORIGIN_UPDATED). Quando o
-- Cloudia for desligado, esses eventos param. Aqui o próprio CRM passa a
-- gerar os mesmos eventos, no mesmo formato:
--   • Lead novo: primeira mensagem de um telefone que o CRM ainda não conhece
--     (WhatsApp oficial). Origem pelo anúncio: com anúncio = #Instagram ADS
--     (com o id do anúncio), sem anúncio = #Organico. Também cria o paciente,
--     o que dispara as automações de "Lead novo criado".
--   • Contato conhecido que volta por um anúncio: troca de origem (igual ao
--     Cloudia), no máximo uma vez por anúncio a cada 7 dias.
--   • Mudança de etapa feita no CRM (card do lead ou Conversas): evento de
--     etapa com a data da mudança.
-- Os eventos ficam em eventos_proprios desde já (para comparar com o Cloudia
-- no período em paralelo). O Dashboard só passa a usá-los a partir da data
-- gravada em configuracoes.funil_proprio_desde (a gestão liga pelo CRM, no dia
-- em que o Cloudia for desligado), para não contar em dobro.
-- Nada aqui trava a gravação original: qualquer erro vai para espelho_erros.
-- Rodar no Supabase: SQL Editor → New query → colar tudo → Run.
-- ============================================================

create table if not exists public.eventos_proprios (
  id             bigint generated always as identity primary key,
  telefone       text not null,
  tipo           text not null check (tipo in ('CUSTOMER_CREATED', 'CUSTOMER_STAGE_UPDATED', 'CUSTOMER_ACQUISITION_ORIGIN_UPDATED')),
  nome           text,
  etapa          text,
  origem         text,
  ad_id          text,
  ad_name        text,
  adset_name     text,
  campaign_name  text,
  ocorrido_em    timestamptz not null default now(),
  lead_criado_em timestamptz,
  fonte          text not null default 'crm' check (fonte in ('whatsapp', 'crm')),
  conversa_id    uuid references public.conversas(id) on delete set null,
  criado_em      timestamptz not null default now()
);
create index if not exists eventos_proprios_data on public.eventos_proprios (ocorrido_em);
create index if not exists eventos_proprios_tel on public.eventos_proprios (telefone, tipo, ocorrido_em desc);

alter table public.eventos_proprios enable row level security;
revoke all on public.eventos_proprios from anon, authenticated;
grant select on public.eventos_proprios to authenticated;
drop policy if exists eventos_proprios_ver on public.eventos_proprios;
create policy eventos_proprios_ver on public.eventos_proprios for select to authenticated
  using (public.is_equipe_crm());

-- No formato das colunas da planilha do Cloudia (o Dashboard lê assim)
create or replace view public.eventos_proprios_planilha with (security_invoker = true) as
select e.id, e.ocorrido_em,
       to_char(e.ocorrido_em at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') as "timestamp",
       e.tipo as type, 'crm-' || e.id as customer_id, e.nome as name, e.telefone as phone, e.etapa as stage,
       null::text as value, e.ad_id, e.ad_name, e.adset_name, e.campaign_name, e.origem as origin,
       to_char(coalesce(e.lead_criado_em, e.ocorrido_em) at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') as created_at
from public.eventos_proprios e;
revoke all on public.eventos_proprios_planilha from anon, authenticated;
grant select on public.eventos_proprios_planilha to authenticated;

-- Números da clínica que criam lead (um número pessoal em coexistência pode ficar de fora)
alter table public.whatsapp_numeros add column if not exists cria_leads boolean not null default true;

-- A partir de quando o Dashboard usa os eventos do CRM (null = ainda usa só o Cloudia)
insert into public.configuracoes (chave, valor, atualizado_por)
values ('funil_proprio_desde', 'null'::jsonb, 'migracao')
on conflict (chave) do nothing;

-- ------------------------------------------------------------
-- Nome do anúncio, conjunto e campanha pelo id (o WhatsApp só manda o id)
-- ------------------------------------------------------------
create or replace function public.funil_anuncio(p_ad text)
returns table (ad_name text, adset_name text, campaign_name text)
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if p_ad is null then return; end if;
  return query
    select a.ad_name, a.adset_name, a.campaign_name from public.anuncios_dia a
     where a.ad_id = p_ad and a.ad_name is not null order by a.data desc limit 1;
  if found then return; end if;
  if to_regclass('public.importacao_cloudia') is not null then
    return query execute
      'select nullif(ad_name, ''''), nullif(adset_name, ''''), nullif(campaign_name, '''')
         from public.importacao_cloudia where ad_id = $1 and nullif(ad_name, '''') is not null
        order by linha desc limit 1' using p_ad;
  end if;
end $$;

-- Último anúncio conhecido de um telefone (o Cloudia repete nos eventos de etapa)
create or replace function public.funil_ultimo_anuncio(p_tel text)
returns table (ad_id text, ad_name text, adset_name text, campaign_name text)
language plpgsql stable security definer set search_path = public, migracao, pg_temp as $$
begin
  return query
    select e.ad_id, e.ad_name, e.adset_name, e.campaign_name from public.eventos_proprios e
     where e.telefone = p_tel and e.ad_id is not null order by e.ocorrido_em desc limit 1;
  if found then return; end if;
  if to_regclass('public.importacao_cloudia') is not null then
    return query execute
      'select nullif(ad_id, ''''), nullif(ad_name, ''''), nullif(adset_name, ''''), nullif(campaign_name, '''')
         from public.importacao_cloudia where ativo and migracao.tel(phone) = $1 and nullif(ad_id, '''') is not null
        order by linha desc limit 1' using p_tel;
  end if;
end $$;

-- ------------------------------------------------------------
-- Lead novo / volta por anúncio: depois de gravar a mensagem recebida
-- (adiado para o fim da gravação, quando o nome do perfil já está na conversa)
-- ------------------------------------------------------------
create or replace function public.funil_t_mensagem()
returns trigger
language plpgsql security definer set search_path = public, migracao, pg_temp as $$
declare
  c public.conversas; v_cria boolean; v_ad text; v_origem text; v_nome text; v_conhecido boolean;
  an record;
begin
  if new.direcao <> 'recebida' or coalesce(new.canal, 'paciente') <> 'paciente'
     or new.enviada_em < now() - interval '1 day' then
    return null;
  end if;
  select * into c from public.conversas where id = new.conversa_id;
  if c.id is null or c.telefone !~ '^[0-9]{10,13}$' then return null; end if;
  select n.cria_leads into v_cria from public.whatsapp_numeros n where n.phone_number_id = c.numero_clinica_id;
  if v_cria is false then return null; end if;

  v_ad := case when new.origem_anuncio->>'source_type' = 'ad' then nullif(new.origem_anuncio->>'source_id', '') end;
  v_origem := case when new.origem_anuncio is not null and new.origem_anuncio->>'source_type' = 'ad' then '#Instagram ADS' else '#Organico' end;
  v_nome := coalesce(nullif(btrim(c.nome_contato), ''), nullif(btrim(c.nome_perfil), ''));

  -- conhecido: já era paciente antes desta conversa começar, ou o CRM já criou o lead
  v_conhecido := exists (select 1 from public.pacientes p where p.telefone = c.telefone
                                and p.criado_em < c.criada_em - interval '2 minutes')
              or exists (select 1 from public.eventos_proprios e where e.telefone = c.telefone and e.tipo = 'CUSTOMER_CREATED');

  if not v_conhecido then
    select * into an from public.funil_anuncio(v_ad);
    insert into public.eventos_proprios
      (telefone, tipo, nome, etapa, origem, ad_id, ad_name, adset_name, campaign_name, ocorrido_em, lead_criado_em, fonte, conversa_id)
    values
      (c.telefone, 'CUSTOMER_CREATED', v_nome, 'Lead', v_origem, v_ad, an.ad_name, an.adset_name, an.campaign_name,
       new.enviada_em, new.enviada_em, 'whatsapp', c.id);
    insert into public.pacientes (telefone, nome, origem, etapa, etapa_alterada_em, criado_em, legado)
    values (c.telefone, v_nome, v_origem, 'Lead', new.enviada_em, new.enviada_em, jsonb_build_object('fonte', 'whatsapp'))
    on conflict (telefone) do nothing;
    update public.conversas set paciente_id = (select id from public.pacientes where telefone = c.telefone)
     where id = c.id and paciente_id is null;
  elsif v_ad is not null and not exists (
      select 1 from public.eventos_proprios e
       where e.telefone = c.telefone and e.ad_id = v_ad and e.ocorrido_em > new.enviada_em - interval '7 days') then
    select * into an from public.funil_anuncio(v_ad);
    insert into public.eventos_proprios
      (telefone, tipo, nome, etapa, origem, ad_id, ad_name, adset_name, campaign_name, ocorrido_em, fonte, conversa_id)
    select c.telefone, 'CUSTOMER_ACQUISITION_ORIGIN_UPDATED', coalesce(p.nome, v_nome), p.etapa, '#Instagram ADS',
           v_ad, an.ad_name, an.adset_name, an.campaign_name, new.enviada_em, 'whatsapp', c.id
      from (select 1) x left join public.pacientes p on p.telefone = c.telefone;
  end if;
  return null;
exception when others then
  insert into public.espelho_erros (origem, erro, detalhe) values ('funil_t_mensagem', sqlerrm, new.conversa_id::text);
  return null;
end $$;
drop trigger if exists t_funil_mensagem on public.mensagens;
create constraint trigger t_funil_mensagem after insert on public.mensagens
  deferrable initially deferred
  for each row execute function public.funil_t_mensagem();

-- ------------------------------------------------------------
-- Mudança de etapa no CRM
-- ------------------------------------------------------------
create or replace function public.funil_t_etapa()
returns trigger
language plpgsql security definer set search_path = public, migracao, pg_temp as $$
declare an record;
begin
  if new.etapa is null or lower(btrim(new.etapa)) is not distinct from lower(btrim(old.etapa)) then return null; end if;
  -- só mudança recente e com data (recarga em massa do espelho não vira evento)
  if new.etapa_alterada_em is null or new.etapa_alterada_em < now() - interval '1 day' then return null; end if;
  if exists (select 1 from public.eventos_proprios e
              where e.telefone = new.telefone and e.tipo = 'CUSTOMER_STAGE_UPDATED'
                and lower(e.etapa) = lower(new.etapa) and e.ocorrido_em > new.etapa_alterada_em - interval '1 minute') then
    return null;
  end if;
  if new.ad_id_manual is not null then
    select new.ad_id_manual as ad_id, f.ad_name, f.adset_name, f.campaign_name into an from public.funil_anuncio(new.ad_id_manual) f;
    if not found then select new.ad_id_manual as ad_id, null::text as ad_name, null::text as adset_name, null::text as campaign_name into an; end if;
  else
    select * into an from public.funil_ultimo_anuncio(new.telefone);
  end if;
  insert into public.eventos_proprios
    (telefone, tipo, nome, etapa, origem, ad_id, ad_name, adset_name, campaign_name, ocorrido_em, lead_criado_em, fonte)
  values
    (new.telefone, 'CUSTOMER_STAGE_UPDATED', new.nome, new.etapa, new.origem, an.ad_id, an.ad_name, an.adset_name, an.campaign_name,
     least(new.etapa_alterada_em, now()), new.criado_em, 'crm');
  return null;
exception when others then
  insert into public.espelho_erros (origem, erro, detalhe) values ('funil_t_etapa', sqlerrm, new.telefone);
  return null;
end $$;
drop trigger if exists t_funil_etapa on public.pacientes;
create trigger t_funil_etapa after update of etapa on public.pacientes
  for each row execute function public.funil_t_etapa();

-- Conferência para o período em paralelo (o que o CRM registrou × o que o Cloudia registrou)
create or replace function public.funil_comparar(p_desde timestamptz default now() - interval '7 days')
returns jsonb
language sql stable security definer set search_path = public, migracao, pg_temp as $$
  select jsonb_build_object(
    'crm', (select coalesce(jsonb_object_agg(tipo || coalesce(':' || etapa, ''), n), '{}'::jsonb)
              from (select tipo, case when tipo = 'CUSTOMER_STAGE_UPDATED' then etapa end etapa, count(*) n
                      from public.eventos_proprios where ocorrido_em >= p_desde group by 1, 2) x),
    'cloudia', (select coalesce(jsonb_object_agg(tipo || coalesce(':' || etapa, ''), n), '{}'::jsonb)
              from (select type tipo, case when type = 'CUSTOMER_STAGE_UPDATED' then stage end etapa, count(*) n
                      from public.importacao_cloudia
                     where ativo and coalesce(migracao.ts("timestamp"), migracao.ts(created_at)) >= p_desde group by 1, 2) y)
  );
$$;
revoke all on function public.funil_comparar(timestamptz) from public, anon;
grant execute on function public.funil_comparar(timestamptz) to authenticated;
revoke all on function public.funil_anuncio(text) from public, anon, authenticated;
revoke all on function public.funil_ultimo_anuncio(text) from public, anon, authenticated;
revoke all on function public.funil_t_mensagem() from public, anon, authenticated;
revoke all on function public.funil_t_etapa() from public, anon, authenticated;

select 'funil do CRM pronto (eventos gravando; o Dashboard só usa depois de ligar)' as status;
