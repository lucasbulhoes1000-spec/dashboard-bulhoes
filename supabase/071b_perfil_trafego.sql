-- 071b (03/11/2026) Perfil "trafego": leitura das tabelas do Meta e do histórico de análises.
-- (O funil da tela já lê tabelas liberadas para toda a equipe: importacao_cloudia,
--  eventos_proprios, cache_painel, configuracoes, crm_sessions.)
drop policy if exists meta_estrutura_trafego on public.meta_estrutura;
create policy meta_estrutura_trafego on public.meta_estrutura for select to authenticated using (public.tem_papel('trafego'));
drop policy if exists meta_insights_dia_trafego on public.meta_insights_dia;
create policy meta_insights_dia_trafego on public.meta_insights_dia for select to authenticated using (public.tem_papel('trafego'));
drop policy if exists meta_quebras_dia_trafego on public.meta_quebras_dia;
create policy meta_quebras_dia_trafego on public.meta_quebras_dia for select to authenticated using (public.tem_papel('trafego'));
drop policy if exists analises_ia_trafego on public.analises_ia;
create policy analises_ia_trafego on public.analises_ia for select to authenticated using (public.tem_papel('trafego'));
-- Samuel (gestor de tráfego). O login (Authentication → Add user) é criado pelo Lucas.
insert into public.equipe (email, nome, papel) values ('EMAIL_DO_SAMUEL', 'Samuel', 'trafego')
  on conflict (email) do update set papel = 'trafego', ativo = true;
select email, nome, papel, ativo from public.equipe where papel = 'trafego';
