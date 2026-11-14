-- ============================================================
-- 084 (14/11/2026): coração azul 💙 vira marrom 🤎 em todas as mensagens da Lume
--   (pedido do Lucas). Troca nos textos guardados no banco: configurações
--   (lembretes, Ale), automações e Agente de IA. Os modelos aprovados na Meta
--   são outra etapa (precisam de nova análise da Meta).
-- ============================================================
update public.configuracoes set valor = replace(valor::text, '💙', '🤎')::jsonb where valor::text like '%💙%';
update public.automacoes set passos = replace(passos::text, '💙', '🤎')::jsonb where passos::text like '%💙%';
update public.agente_ia a set
  (instrucoes, base_conhecimento) = (replace(a.instrucoes, '💙', '🤎'), replace(a.base_conhecimento, '💙', '🤎'))
 where coalesce(a.instrucoes, '') like '%💙%' or coalesce(a.base_conhecimento, '') like '%💙%';

select (select count(*) from public.configuracoes where valor::text like '%💙%') as config_azul,
       (select count(*) from public.automacoes where passos::text like '%💙%') as automacoes_azul,
       (select count(*) from (select row_to_json(a)::text t from public.agente_ia a) x where t like '%💙%') as agente_azul;
