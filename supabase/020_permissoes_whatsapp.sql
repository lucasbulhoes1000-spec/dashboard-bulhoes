-- ============================================================
-- CRM Bulhões — Permissões exatas das tabelas do WhatsApp (22/10/2026)
-- O Supabase dá à equipe logada TODAS as permissões em tabelas novas.
-- As regras de linha (RLS) já bloqueavam o uso indevido; aqui a equipe
-- fica só com o que a tela usa, como segunda camada de proteção.
-- Rodar no Supabase: SQL Editor → New query → colar tudo → Run.
-- ============================================================
revoke all on public.conversas, public.mensagens, public.wa_tags, public.conversa_tags, public.respostas_rapidas from authenticated;

grant select on public.conversas, public.mensagens to authenticated;
grant update (atribuida_a, status, nao_lidas, robo_ligado, observacoes) on public.conversas to authenticated;

grant select, insert, delete on public.wa_tags to authenticated;
grant update (nome, cor) on public.wa_tags to authenticated;

grant select, insert, delete on public.conversa_tags to authenticated;

grant select, insert, delete on public.respostas_rapidas to authenticated;
grant update (atalho, texto, atualizada_em) on public.respostas_rapidas to authenticated;

select 'permissões do WhatsApp ajustadas' as status;
