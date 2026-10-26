-- ============================================================
-- CRM Bulhões — respostas rápidas em grupo (26/10/2026)
-- Como no Cloudia: uma resposta pode ter 2 ou mais mensagens separadas
-- (texto, imagem ou vídeo), enviadas uma depois da outra.
-- partes = [{"tipo":"texto","texto":"..."} | {"tipo":"imagem"|"video","url":"https://...","mime":"..."}]
-- (texto continua com o resumo, para a busca)
-- ============================================================
alter table public.respostas_rapidas add column if not exists partes jsonb;
grant update (atalho, texto, partes, atualizada_em) on public.respostas_rapidas to authenticated;
select 'respostas em grupo prontas' as status;
