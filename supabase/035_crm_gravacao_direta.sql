-- ============================================================
-- CRM Bulhões — Gravação do CRM direto no banco, sem o Apps Script (25/10/2026)
--
--   • crm_salvar_patch(): o navegador manda só os clientes que mudaram (com a
--     versão-base e a local de cada um). Mesmas regras, na mesma ordem, do
--     saveCRMPatch/_merge3 do Apps Script. Trava a linha (for update) para duas
--     gravações nunca se atropelarem.
--   • crm_patch_log: cada cliente gravado (antes → depois), para conferência.
--   • Proteção: enquanto rotinas antigas do Apps Script ainda regravam o CRM
--     inteiro (lendo uma cópia de alguns segundos antes), um gatilho impede que
--     elas desfaçam o que a equipe acabou de gravar: se a rotina devolve um
--     cliente exatamente como ele era ANTES de uma gravação dos últimos 15 min,
--     fica a versão da equipe.
-- Rodar no Supabase: SQL Editor → New query → colar tudo → Run.
-- ============================================================

-- cópia de segurança do CRM antes da troca
create table if not exists backup.crm_sessions_20261025 as
  select * from public.crm_sessions where email_clinica = 'bulhoes-clinica-crm';
alter table backup.crm_sessions_20261025 enable row level security;
revoke all on backup.crm_sessions_20261025 from anon, authenticated;

create table if not exists public.crm_patch_log (
  id      bigint generated always as identity primary key,
  chave   text not null,
  antes   jsonb,
  depois  jsonb,
  por     text,
  em      timestamptz not null default now()
);
create index if not exists crm_patch_log_em on public.crm_patch_log (em desc);
alter table public.crm_patch_log enable row level security;
revoke all on public.crm_patch_log from anon, authenticated;

-- _merge3 do Apps Script. "Não existe" (undefined) = SQL null; JSON null = 'null'::jsonb.
create or replace function public.crm_merge3(b jsonb, l jsonb, r jsonb)
returns jsonb
language plpgsql immutable as $$
declare ob jsonb; ol jsonb; orr jsonb; o jsonb := '{}'::jsonb; k text; tb boolean; tl boolean; tr boolean; v jsonb;
begin
  if l is not distinct from b then return r; end if;
  if r is not distinct from b then return l; end if;
  if jsonb_typeof(b) = 'object' or jsonb_typeof(l) = 'object' or jsonb_typeof(r) = 'object' then
    ob := case when jsonb_typeof(b) = 'object' then b else '{}'::jsonb end;
    ol := case when jsonb_typeof(l) = 'object' then l else '{}'::jsonb end;
    orr := case when jsonb_typeof(r) = 'object' then r else '{}'::jsonb end;
    for k in select jsonb_object_keys(ob) union select jsonb_object_keys(ol) union select jsonb_object_keys(orr) loop
      tb := ob ? k; tl := ol ? k; tr := orr ? k;
      if tb and not tl then continue; end if;
      if not tb and not tl and tr then o := o || jsonb_build_object(k, orr->k); continue; end if;
      if not tb and tl and not tr then o := o || jsonb_build_object(k, ol->k); continue; end if;
      if tb and tl and not tr and (ol->k) is not distinct from (ob->k) then continue; end if;
      if tb and tl and not tr then o := o || jsonb_build_object(k, ol->k); continue; end if;
      v := public.crm_merge3(case when tb then ob->k end, case when tl then ol->k end, case when tr then orr->k end);
      if v is not null then o := o || jsonb_build_object(k, v); end if;
    end loop;
    return o;
  end if;
  return l;
end $$;

create or replace function public.crm_salvar_patch(p_mudancas jsonb, p_tem_comissoes boolean default false,
  p_base_comissoes jsonb default '[]'::jsonb, p_local_comissoes jsonb default '[]'::jsonb)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_chave constant text := 'bulhoes-clinica-crm';
  v_txt text; v_com_txt text; remoto jsonb; rcom jsonb; res jsonb := '{}'::jsonb; fcom jsonb;
  k text; m jsonb; tb boolean; tl boolean; tr boolean; b jsonb; l jsonb; fin jsonb; antes jsonb;
  v_por text := coalesce(public.email_atual(), '?');
begin
  if not public.is_equipe_crm() then raise exception 'sem permissão'; end if;
  if jsonb_typeof(p_mudancas) <> 'object' then return jsonb_build_object('status', 'erro', 'mensagem', 'Lista de mudanças inválida; gravação cancelada.'); end if;
  select crm_json::text, comissoes_json::text into v_txt, v_com_txt
    from public.crm_sessions where email_clinica = v_chave for update;
  if not found then return jsonb_build_object('status', 'erro', 'mensagem', 'CRM da clínica não encontrado.'); end if;
  begin remoto := coalesce(nullif(v_txt, ''), '{}')::jsonb;
  exception when others then return jsonb_build_object('status', 'erro', 'mensagem', 'CRM remoto ilegível; gravação cancelada para não sobrescrever.'); end;
  if jsonb_typeof(remoto) <> 'object' then return jsonb_build_object('status', 'erro', 'mensagem', 'CRM remoto inválido; gravação cancelada.'); end if;
  begin rcom := coalesce(nullif(v_com_txt, ''), '[]')::jsonb; exception when others then rcom := '[]'::jsonb; end;

  for k, m in select * from jsonb_each(p_mudancas) loop
    tb := coalesce((m->>'temBase')::boolean, false);
    tl := coalesce((m->>'temLocal')::boolean, false);
    tr := remoto ? k;
    b := case when tb then m->'base' end;
    l := case when tl then m->'local' end;
    antes := remoto->k;
    if tb and not tl then remoto := remoto - k; res := res || jsonb_build_object(k, null);
    elsif not tb and not tl then continue;
    elsif not tb and tl and not tr then remoto := remoto || jsonb_build_object(k, l); res := res || jsonb_build_object(k, l);
    elsif tb and tl and not tr and l is not distinct from b then res := res || jsonb_build_object(k, null); continue;
    elsif tb and tl and not tr then remoto := remoto || jsonb_build_object(k, l); res := res || jsonb_build_object(k, l);
    else
      fin := public.crm_merge3(b, l, remoto->k);
      if fin is null then remoto := remoto - k; res := res || jsonb_build_object(k, null);
      else remoto := remoto || jsonb_build_object(k, fin); res := res || jsonb_build_object(k, fin); end if;
    end if;
    if antes is distinct from (remoto->k) then
      insert into public.crm_patch_log (chave, antes, depois, por) values (k, antes, remoto->k, v_por);
    end if;
  end loop;

  fcom := rcom;
  if p_tem_comissoes then
    fcom := public.crm_merge3(coalesce(p_base_comissoes, '[]'::jsonb), coalesce(p_local_comissoes, '[]'::jsonb), rcom);
    if jsonb_typeof(fcom) is distinct from 'array' then fcom := case when jsonb_typeof(p_local_comissoes) = 'array' then p_local_comissoes else rcom end; end if;
  end if;

  perform set_config('crm.via_rpc', '1', true);
  update public.crm_sessions
     set crm_json = remoto::text,
         comissoes_json = case when p_tem_comissoes then fcom::text else comissoes_json end,
         atualizado_em = now()
   where email_clinica = v_chave;
  perform set_config('crm.via_rpc', '', true);

  return jsonb_build_object('status', 'ok', 'modo', 'patch', 'crm', res,
    'comissoes', case when p_tem_comissoes then fcom end, 'totalClientes', (select count(*) from jsonb_object_keys(remoto)));
end $$;
revoke all on function public.crm_salvar_patch(jsonb, boolean, jsonb, jsonb) from public, anon;
grant execute on function public.crm_salvar_patch(jsonb, boolean, jsonb, jsonb) to authenticated;

-- Proteção contra rotinas antigas que regravam o CRM inteiro com uma cópia velha
create or replace function public.crm_proteger_gravacoes() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare novo jsonb; velho jsonb; x record; mexeu boolean := false;
begin
  if new.email_clinica <> 'bulhoes-clinica-crm' or coalesce(current_setting('crm.via_rpc', true), '') = '1' then return new; end if;
  if new.crm_json is not distinct from old.crm_json then return new; end if;
  if not exists (select 1 from public.crm_patch_log where em > now() - interval '15 minutes') then return new; end if;
  begin novo := new.crm_json::jsonb; velho := old.crm_json::jsonb; exception when others then return new; end;
  for x in select distinct on (chave) chave, depois from public.crm_patch_log
            where em > now() - interval '15 minutes' order by chave, id desc loop
    -- a rotina devolveu o cliente numa versão de ANTES de alguma gravação da equipe
    -- dos últimos 15 min (cópia velha) → fica a versão atual da equipe
    if (velho->x.chave) is not distinct from x.depois
       and (novo->x.chave) is distinct from (velho->x.chave)
       and exists (select 1 from public.crm_patch_log y where y.chave = x.chave and y.em > now() - interval '15 minutes'
                    and (novo->x.chave) is not distinct from y.antes) then
      if velho ? x.chave then novo := novo || jsonb_build_object(x.chave, velho->x.chave); else novo := novo - x.chave; end if;
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
drop trigger if exists t_crm_proteger on public.crm_sessions;
create trigger t_crm_proteger before update of crm_json on public.crm_sessions
  for each row execute function public.crm_proteger_gravacoes();

-- conferência rápida do merge (deve dar tudo true)
select public.crm_merge3('{"a":1,"b":1}', '{"a":2,"b":1}', '{"a":1,"b":3}') = '{"a":2,"b":3}'::jsonb as campos_independentes,
       public.crm_merge3('{"a":1}', '{"a":1}', '{"a":5}') = '{"a":5}'::jsonb as local_sem_mudar,
       public.crm_merge3('{"a":1,"x":1}', '{"a":1}', '{"a":1,"x":2}') = '{"a":1}'::jsonb as exclusao_local_vence,
       public.crm_merge3('[1]', '[2]', '[3]') = '[2]'::jsonb as lista_local_vence;
