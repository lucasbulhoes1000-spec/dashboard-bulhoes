-- ============================================================
-- 085 (16/11/2026): o perfil "clinica" (Dra. Gabi) passa a ver e atender as
--   conversas da Central, com as mesmas permissões do comercial (pedido do Lucas:
--   "pra Gabi pode liberar tudo"). Só mexe nas tabelas da Central de mensagens;
--   pacientes, orçamentos, comissões etc. ficam como estavam.
-- ============================================================
do $$
declare r record; novo_q text; novo_c text; n int := 0;
begin
  for r in
    select schemaname, tablename, policyname, qual, with_check
      from pg_policies
     where ((schemaname = 'public' and tablename in (
              'conversas', 'mensagens', 'wa_tags', 'conversa_tags', 'respostas_rapidas',
              'mensagens_agendadas', 'whatsapp_numeros', 'instagram_contas'))
            or (schemaname = 'storage' and policyname like 'whatsapp_midia%'))
       and (coalesce(qual, '') like '%''comercial''%' or coalesce(with_check, '') like '%''comercial''%')
       and coalesce(qual, '') || coalesce(with_check, '') not like '%''clinica''%'
  loop
    novo_q := regexp_replace(r.qual, '''comercial''::([a-z_.]*papel_equipe)', '''comercial''::\1, ''clinica''::\1', 'g');
    novo_c := regexp_replace(r.with_check, '''comercial''::([a-z_.]*papel_equipe)', '''comercial''::\1, ''clinica''::\1', 'g');
    execute format('alter policy %I on %I.%I', r.policyname, r.schemaname, r.tablename)
         || case when novo_q is not null then ' using (' || novo_q || ')' else '' end
         || case when novo_c is not null then ' with check (' || novo_c || ')' else '' end;
    n := n + 1;
  end loop;
  raise notice 'políticas ajustadas: %', n;
end $$;

-- lista de atendentes (atribuir conversa) também mostra a Gabi
create or replace function public.equipe_atendentes()
returns table (email text, nome text)
language sql stable security definer set search_path = public, pg_temp as $$
  select e.email, e.nome from public.equipe e
  where e.ativo and e.papel in ('gestao', 'avaliacao', 'comercial', 'clinica')
    and public.tem_papel('gestao', 'avaliacao', 'comercial', 'clinica')
  order by e.nome;
$$;

-- conferência: cada política da Central e se já inclui a clínica
select schemaname || '.' || tablename as tabela, policyname as politica,
       (coalesce(qual, '') || coalesce(with_check, '')) like '%''clinica''%' as clinica_ok
  from pg_policies
 where (schemaname = 'public' and tablename in ('conversas', 'mensagens', 'wa_tags', 'conversa_tags',
        'respostas_rapidas', 'mensagens_agendadas', 'whatsapp_numeros', 'instagram_contas'))
    or (schemaname = 'storage' and policyname like 'whatsapp_midia%')
 order by 1, 2;
