-- 070 (01/11/2026) só a conta de anúncios da clínica (a conta "CA - LARISSA BULHÕES" tem campanhas do Instituto)
insert into public.configuracoes (chave, valor) values ('meta_contas', '["act_830126674734657"]'::jsonb)
  on conflict (chave) do update set valor = excluded.valor;
-- tabelas do Meta criadas hoje: zeradas para buscar de novo só a conta da clínica
truncate public.meta_insights_dia, public.meta_quebras_dia, public.meta_estrutura;
