-- 208 (17/11/2026): "Apagar conversa" voltava "permission denied for table conversas" (clínica e Instituto)
--   A 078 criou a coluna oculta_em, mas a equipe só tinha permissão de editar algumas colunas da conversa
--   (atribuida_a, status, nao_lidas, robo_ligado, observacoes). Faltava oculta_em.
--   Só libera essa coluna. As regras de quem vê qual conversa (RLS) continuam as mesmas.
grant update (oculta_em) on public.conversas to authenticated;

select has_column_privilege('authenticated', 'public.conversas', 'oculta_em', 'UPDATE') as pode_apagar;
