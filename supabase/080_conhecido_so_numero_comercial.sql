-- ============================================================
-- 080 (14/11/2026): números em coexistência (recepção, Instituto, comercial 2...) não
-- interferem no funil. "Já conversou com a clínica antes" passa a olhar só conversas de
-- números que criam leads (cria_leads = true). Antes, quem falou primeiro com a recepção e
-- depois chamou o comercial não virava lead.
-- Troca só o trecho da verificação na versão que está no banco.
-- ============================================================
do $do$
declare
  d text;
  alvo constant text := 'where c2.telefone = c.telefone';
  novo constant text := 'where c2.telefone = c.telefone and coalesce((select n2.cria_leads from public.whatsapp_numeros n2 where n2.phone_number_id = c2.numero_clinica_id), true) /* 080: só números que criam leads */';
begin
  d := pg_get_functiondef('public.funil_t_mensagem'::regproc);
  if position('080: só números que criam leads' in d) > 0 then raise notice 'já aplicado'; return; end if;
  if (length(d) - length(replace(d, alvo, ''))) / length(alvo) <> 1 then
    raise exception 'não achei o trecho em funil_t_mensagem (nada foi alterado)';
  end if;
  execute replace(d, alvo, novo);
end $do$;

select position('080: só números que criam leads' in pg_get_functiondef('public.funil_t_mensagem'::regproc)) > 0 as regra_080_ativa,
       (select string_agg(coalesce(apelido, numero_exibicao) || ' = ' || cria_leads::text, ' | ' order by conectado_em)
          from public.whatsapp_numeros where ativo) as numeros_e_cria_leads;
