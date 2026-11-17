-- 207 (Instituto, 17/11/2026): colunas do funil do Instituto editáveis pelo CRM
--   O Lucas cria, renomeia e apaga colunas pela Lume (botão "⚙ Colunas"). A lista fica em configuracoes.inst_colunas.
--   Por isso a etapa deixa de ter lista fechada no banco: aceita qualquer chave simples (letras minúsculas, números e _).
--   Coluna nova padrão: interesse_modelo (quer ser paciente modelo).
-- Só mexe na tabela instituto_leads. Nada da clínica.
alter table public.instituto_leads drop constraint if exists instituto_leads_etapa_check;
alter table public.instituto_leads add constraint instituto_leads_etapa_check check (etapa ~ '^[a-z0-9_]{1,40}$');

select etapa, count(*) as cards from public.instituto_leads group by etapa order by etapa;
