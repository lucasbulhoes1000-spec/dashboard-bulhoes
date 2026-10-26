-- ============================================================
-- CRM Bulhões — rotinas antigas não desfazem a etapa mudada pela equipe (26/10/2026)
-- O Apps Script ainda roda "sincronizarTodosAgendadosReais" (consulta a etapa
-- no Cloudia e regrava no CRM). Com a equipe mexendo só no CRM, isso voltaria,
-- por exemplo, um Faltou para Agendou. Regra: numa gravação que não seja da
-- equipe (crm_salvar_patch/crm_anotar), se o cliente teve a etapa mudada pela
-- equipe de A para B e a gravação tenta voltar de B para A, fica B.
-- Outras mudanças de etapa (ex.: Clinicorp marcando Ganho) continuam passando.
-- ============================================================
create or replace function public.crm_proteger_gravacoes() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare novo jsonb; velho jsonb; x record; mexeu boolean := false; nv jsonb; vv jsonb;
begin
  if new.email_clinica <> 'bulhoes-clinica-crm' or coalesce(current_setting('crm.via_rpc', true), '') = '1' then return new; end if;
  if new.crm_json is not distinct from old.crm_json then return new; end if;
  if not exists (select 1 from public.crm_patch_log where por <> 'rotina automática') then return new; end if;
  begin novo := new.crm_json::jsonb; velho := old.crm_json::jsonb; exception when others then return new; end;

  -- 1) cópia velha de um cliente gravado pela equipe nos últimos 15 min → fica a da equipe
  for x in select distinct on (chave) chave, depois from public.crm_patch_log
            where em > now() - interval '15 minutes' order by chave, id desc loop
    if (velho->x.chave) is not distinct from x.depois
       and (novo->x.chave) is distinct from (velho->x.chave)
       and exists (select 1 from public.crm_patch_log y where y.chave = x.chave and y.em > now() - interval '15 minutes'
                    and (novo->x.chave) is not distinct from y.antes) then
      if velho ? x.chave then novo := novo || jsonb_build_object(x.chave, velho->x.chave); else novo := novo - x.chave; end if;
      mexeu := true;
    end if;
  end loop;

  -- 2) etapa mudada pela equipe (A → B) não volta para A por rotina antiga
  for x in select distinct on (chave) chave, antes->>'statusAtual' as de, depois->>'statusAtual' as para
             from public.crm_patch_log
            where por <> 'rotina automática' and em > '2026-10-26 02:00+00'
              and (antes->>'statusAtual') is distinct from (depois->>'statusAtual')
            order by chave, id desc loop
    vv := velho->x.chave; nv := novo->x.chave;
    if vv is null or nv is null or jsonb_typeof(nv) <> 'object' then continue; end if;
    if (vv->>'statusAtual') is not distinct from x.para and (nv->>'statusAtual') is not distinct from x.de
       and (nv->>'statusAtual') is distinct from (vv->>'statusAtual') then
      nv := nv || jsonb_build_object('statusAtual', vv->'statusAtual')
               || case when vv ? 'statusAtualEditedAt' then jsonb_build_object('statusAtualEditedAt', vv->'statusAtualEditedAt') else '{}'::jsonb end;
      novo := novo || jsonb_build_object(x.chave, nv);
      mexeu := true;
    end if;
  end loop;

  if mexeu then
    new.crm_json := novo::text;
    insert into public.espelho_erros (origem, erro, detalhe) values ('crm_proteger_gravacoes', 'rotina antiga tentou desfazer gravação da equipe (corrigido)', null);
  end if;
  return new;
exception when others then
  return new;
end $$;

select 'proteção da etapa da equipe pronta' as status;
