-- ============================================================
-- CRM Bulhões — importação do histórico da Cloudia, passo 1 de 3
-- 21/10/2026
-- Cria a área de recebimento da planilha "Leads" (texto puro, sem conversão).
-- Só o Apps Script (chave de serviço) grava aqui; o site não enxerga.
-- Rodar no Supabase: SQL Editor → New query → colar tudo → Run.
-- ============================================================
create table if not exists public.importacao_cloudia (
  linha          integer primary key,
  "timestamp"    text,
  type           text,
  customer_id    text,
  name           text,
  phone          text,
  stage          text,
  value          text,
  ad_id          text,
  ad_name        text,
  adset_name     text,
  campaign_name  text,
  origin         text,
  created_at     text,
  recebido_em    timestamptz not null default now()
);
alter table public.importacao_cloudia enable row level security;
revoke all on public.importacao_cloudia from anon, authenticated;

select 'área de recebimento pronta' as status;
