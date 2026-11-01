-- 067 (01/11/2026) Meta Ads direto da API (sem o Apps Script)
-- meta_estrutura: um registro por anúncio, com status real e objetivo da campanha.
-- meta_insights_dia: números do Meta por anúncio e por dia (para tendência).
-- Quem grava é a função meta-sync (segredo META_ACCESS_TOKEN); a cada hora o cron
-- busca os últimos 3 dias e a estrutura. A gestão, a avaliação e o comercial leem.

create table if not exists public.meta_estrutura (
  ad_id               text primary key,
  ad_nome             text,
  ad_status           text,          -- status escolhido (ACTIVE, PAUSED…)
  ad_status_efetivo   text,          -- status real (ACTIVE, CAMPAIGN_PAUSED, ADSET_PAUSED, DISAPPROVED…)
  ad_criado_em        timestamptz,
  adset_id            text,
  adset_nome          text,
  adset_status_efetivo text,
  otimizacao          text,          -- optimization_goal do conjunto
  destino             text,          -- destination_type do conjunto (WHATSAPP, INSTAGRAM_PROFILE…)
  orcamento_dia_conjunto numeric,
  campaign_id         text,
  campaign_nome       text,
  campaign_status_efetivo text,
  objetivo            text,          -- objective da campanha (OUTCOME_ENGAGEMENT, OUTCOME_TRAFFIC…)
  orcamento_dia_campanha numeric,
  tipo                text,          -- mensagem | perfil | cadastro | outro (calculado pela função)
  criativo_tipo       text,          -- VIDEO, PHOTO, SHARE…
  criativo_titulo     text,
  criativo_texto      text,
  criativo_miniatura  text,
  atualizado_em       timestamptz not null default now()
);
create index if not exists meta_estrutura_campanha on public.meta_estrutura (campaign_id);

create table if not exists public.meta_insights_dia (
  dia              date not null,
  ad_id            text not null,
  gasto            numeric not null default 0,
  impressoes       integer not null default 0,
  alcance          integer,
  frequencia       numeric,
  cliques          integer,
  cliques_link     integer,
  ctr              numeric,
  cpm              numeric,
  conversas        integer,          -- conversas iniciadas por mensagem (7 dias)
  visitas_perfil   integer,          -- visitas ao perfil do Instagram
  leads_formulario integer,
  video_3s         integer,
  video_25         integer,
  video_50         integer,
  video_75         integer,
  video_100        integer,
  thruplays        integer,
  acoes            jsonb,            -- todas as ações, como o Meta mandou
  atualizado_em    timestamptz not null default now(),
  primary key (dia, ad_id)
);
create index if not exists meta_insights_dia_ad on public.meta_insights_dia (ad_id, dia);

alter table public.meta_estrutura enable row level security;
alter table public.meta_insights_dia enable row level security;
revoke all on public.meta_estrutura from anon;
revoke all on public.meta_insights_dia from anon;
grant select on public.meta_estrutura to authenticated;
grant select on public.meta_insights_dia to authenticated;
drop policy if exists meta_estrutura_ver on public.meta_estrutura;
create policy meta_estrutura_ver on public.meta_estrutura for select to authenticated using (public.tem_papel('gestao', 'avaliacao', 'comercial'));
drop policy if exists meta_insights_dia_ver on public.meta_insights_dia;
create policy meta_insights_dia_ver on public.meta_insights_dia for select to authenticated using (public.tem_papel('gestao', 'avaliacao', 'comercial'));

-- cron: de hora em hora (minuto 7), últimos 3 dias + estrutura
select cron.unschedule('meta-sync') where exists (select 1 from cron.job where jobname = 'meta-sync');
select cron.schedule('meta-sync', '7 * * * *', $$
  select net.http_post(
    url := 'https://gcxuikfjyajlmqbqlyca.supabase.co/functions/v1/meta-sync',
    headers := jsonb_build_object('Content-Type', 'application/json',
                                  'x-motor-chave', (select chave from public.automacao_segredo where id = 1)),
    body := '{"acao":"sincronizar","dias":3}'::jsonb,
    timeout_milliseconds := 120000)
$$);

select 'meta_ads pronto' as status;
