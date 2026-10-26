-- ============================================================
-- CRM Bulhões — Anotação do cliente direto no banco (25/10/2026)
-- Substitui o saveClientAnnotationAtomic do Apps Script: põe a anotação no
-- começo da lista do cliente (sem apagar anotações que outra pessoa acabou
-- de gravar), trava a linha e devolve o cliente como ficou salvo.
-- Rodar no Supabase: SQL Editor → New query → colar tudo → Run.
-- ============================================================
create or replace function public.crm_anotar(p_chave text, p_nota jsonb)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_txt text; remoto jsonb; cli jsonb; antes jsonb; lista jsonb; v_id text := btrim(coalesce(p_nota->>'id', ''));
begin
  if not public.is_equipe_crm() then raise exception 'sem permissão'; end if;
  if btrim(coalesce(p_chave, '')) = '' then return jsonb_build_object('status', 'erro', 'mensagem', 'Cliente não identificado.'); end if;
  if v_id = '' or btrim(coalesce(p_nota->>'text', '')) = '' then return jsonb_build_object('status', 'erro', 'mensagem', 'Anotação inválida.'); end if;
  select crm_json::text into v_txt from public.crm_sessions where email_clinica = 'bulhoes-clinica-crm' for update;
  if not found then return jsonb_build_object('status', 'erro', 'mensagem', 'CRM da clínica não encontrado.'); end if;
  begin remoto := coalesce(nullif(v_txt, ''), '{}')::jsonb;
  exception when others then return jsonb_build_object('status', 'erro', 'mensagem', 'CRM remoto ilegível; gravação cancelada.'); end;
  antes := remoto->p_chave;
  cli := case when jsonb_typeof(antes) = 'object' then antes else '{"orcamentos":[],"atividades":[],"anotacoes":[]}'::jsonb end;
  lista := case when jsonb_typeof(cli->'anotacoes') = 'array' then cli->'anotacoes' else '[]'::jsonb end;
  if not exists (select 1 from jsonb_array_elements(lista) a where a->>'id' = v_id) then
    lista := jsonb_build_array(p_nota) || lista;
  end if;
  cli := cli || jsonb_build_object('anotacoes', lista);
  remoto := remoto || jsonb_build_object(p_chave, cli);
  perform set_config('crm.via_rpc', '1', true);
  update public.crm_sessions set crm_json = remoto::text, atualizado_em = now() where email_clinica = 'bulhoes-clinica-crm';
  perform set_config('crm.via_rpc', '', true);
  insert into public.crm_patch_log (chave, antes, depois, por) values (p_chave, antes, cli, coalesce(public.email_atual(), '?'));
  return jsonb_build_object('status', 'ok', 'verified', true, 'clientKey', p_chave, 'cliente', cli);
end $$;
revoke all on function public.crm_anotar(text, jsonb) from public, anon;
grant execute on function public.crm_anotar(text, jsonb) to authenticated;

select 'anotação direta pronta' as status;
