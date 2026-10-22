-- ============================================================
-- CRM Bulhões — Observações da conversa (22/10/2026)
-- Campo "Observações" do painel Dados do contato (como no Cloudia, até 16.000 caracteres).
-- Rodar no Supabase: SQL Editor → New query → colar tudo → Run.
-- ============================================================
alter table public.conversas add column if not exists observacoes text check (length(observacoes) <= 16000);
grant update (atribuida_a, status, nao_lidas, robo_ligado, observacoes) on public.conversas to authenticated;
select 'observações da conversa prontas' as status;
