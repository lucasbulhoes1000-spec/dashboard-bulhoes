-- ============================================================
-- CRM Bulhões — correção do espelho (21/10/2026)
-- A Supabase recusa DELETE sem filtro quando a gravação vem pelo site, e o
-- gatilho usava isso para refazer comissões e listas. Resultado: desde as
-- 10h08 o espelho registrava erro em toda gravação do CRM (o CRM em si
-- gravou normalmente). Esta correção:
--   1. ajusta as funções (DELETE com filtro; erro em pacientes e em extras
--      tratados separadamente);
--   2. refaz a cópia de todos os pacientes, comissões, listas e configurações;
--   3. limpa os erros antigos e mostra a conferência.
-- Rodar no Supabase: SQL Editor → New query → colar tudo → Run.
-- ============================================================
create or replace function public.espelhar_extras_do_crm(linha public.crm_sessions)
returns void
language plpgsql security definer set search_path = public, migracao, pg_temp as $$
begin
  if linha.email_clinica = 'bulhoes-clinica-crm' then
    delete from public.comissoes where true;  -- a Supabase recusa DELETE sem filtro vindo do site
    insert into public.comissoes
      (data, paciente_nome, telefone, avaliador, crc, valor_tratamento, entrada, pagamento,
       comissao_avaliador, comissao_crc, status, obs, origem, criado_em)
    select migracao.dt(c->>'data'), nullif(c->>'paciente', ''), migracao.tel(c->>'telefone'),
           nullif(c->>'avaliador', ''), nullif(c->>'crc', ''), migracao.num(c->>'valorTrat'), migracao.num(c->>'entrada'),
           nullif(c->>'pgto', ''), migracao.num(c->>'comAval'), migracao.num(c->>'comCrc'),
           nullif(c->>'status', ''), nullif(c->>'obs', ''), nullif(c->>'origem', ''),
           coalesce(migracao.ts(c->>'criadoEm'), now())
    from jsonb_array_elements(case when jsonb_typeof(linha.comissoes_json::jsonb) = 'array' then linha.comissoes_json::jsonb else '[]'::jsonb end) x(c)
    where jsonb_typeof(c) = 'object';

    if linha.listas_json is not null and jsonb_typeof(linha.listas_json::jsonb) = 'object' then
      delete from public.listas where true;
      insert into public.listas (tipo, valor, ordem, ativo, fixo)
      select distinct on (l.tipo, l.valor) l.tipo, l.valor, l.ordem, l.ativo, l.fixo
      from (
        select e.key as tipo, btrim(it.value #>> '{}') as valor, it.ordinality::int as ordem,
               g.grupo <> 'desativos' as ativo, g.grupo = 'padroes' as fixo, g.prio
        from jsonb_each(linha.listas_json::jsonb) e,
             lateral (values ('padroes', 1), ('ativos', 2), ('desativos', 3)) g(grupo, prio),
             lateral jsonb_array_elements(case when jsonb_typeof(e.value -> g.grupo) = 'array' then e.value -> g.grupo else '[]'::jsonb end)
                     with ordinality it(value, ordinality)
      ) l
      where l.valor is not null and l.valor <> ''
      order by l.tipo, l.valor, l.prio;
    end if;

    insert into public.configuracoes (chave, valor, atualizado_por)
    select 'ajustes_dashboard', linha.crm_json::jsonb->'__manuais__', 'espelho'
    where linha.crm_json::jsonb ? '__manuais__'
    on conflict (chave) do update set valor = excluded.valor, atualizado_por = 'espelho';
    insert into public.configuracoes (chave, valor, atualizado_por)
    select 'exclusoes', linha.crm_json::jsonb->'__exclusoes__', 'espelho'
    where linha.crm_json::jsonb ? '__exclusoes__'
    on conflict (chave) do update set valor = excluded.valor, atualizado_por = 'espelho';
  elsif linha.email_clinica in ('bulhoes-fluxo-tratamento', 'bulhoes-calendario-sazonal', 'bulhoes-agenda-avaliacoes')
        and linha.crm_json is not null then
    insert into public.configuracoes (chave, valor, atualizado_por)
    values (case linha.email_clinica
              when 'bulhoes-fluxo-tratamento' then 'fluxo_tratamento'
              when 'bulhoes-calendario-sazonal' then 'calendario_sazonal'
              else 'agenda_avaliacoes' end,
            linha.crm_json::jsonb, 'espelho')
    on conflict (chave) do update set valor = excluded.valor, atualizado_por = 'espelho';
  end if;
end $$;

create or replace function public.t_espelhar_crm()
returns trigger
language plpgsql security definer set search_path = public, migracao, pg_temp as $$
declare
  novo jsonb; velho jsonb; mudados text[];
begin
  if not public.espelho_ligado() then return new; end if;
  -- pacientes e extras em blocos separados: um erro num não impede o outro
  begin
    if new.email_clinica = 'bulhoes-clinica-crm' then
      if tg_op = 'INSERT' or new.crm_json is distinct from old.crm_json then
        novo := coalesce(new.crm_json::jsonb, '{}'::jsonb);
        velho := case when tg_op = 'UPDATE' then coalesce(old.crm_json::jsonb, '{}'::jsonb) else '{}'::jsonb end;
        select array_agg(distinct migracao.tel(k)) into mudados
        from (
          select coalesce(n.key, o.key) as k
          from jsonb_each(novo) n full join jsonb_each(velho) o on o.key = n.key
          where n.value is distinct from o.value
        ) d
        where k ~ '^\d+$' and migracao.tel(k) is not null;
        if mudados is not null then
          perform public.espelhar_pacientes_do_crm(mudados, novo);
        end if;
      end if;
    end if;
  exception when others then
    insert into public.espelho_erros (origem, erro, detalhe)
    values ('pacientes:' || new.email_clinica, sqlerrm, sqlstate);
  end;
  begin
    if new.email_clinica = 'bulhoes-clinica-crm' then
      if tg_op = 'INSERT' or new.crm_json is distinct from old.crm_json
         or new.comissoes_json is distinct from old.comissoes_json
         or new.listas_json is distinct from old.listas_json then
        perform public.espelhar_extras_do_crm(new);
      end if;
    else
      perform public.espelhar_extras_do_crm(new);
    end if;
  exception when others then
    insert into public.espelho_erros (origem, erro, detalhe)
    values ('extras:' || new.email_clinica, sqlerrm, sqlstate);
  end;
  return new;
end $$;

-- Recuperação completa
select public.espelhar_pacientes_do_crm(
  (select array_agg(distinct migracao.tel(k))
     from public.crm_sessions s, jsonb_object_keys(s.crm_json::jsonb) k
    where s.email_clinica = 'bulhoes-clinica-crm' and k ~ '^\d+$' and migracao.tel(k) is not null),
  (select crm_json::jsonb from public.crm_sessions where email_clinica = 'bulhoes-clinica-crm')
) as pacientes_ressincronizados;
select public.espelhar_extras_do_crm(s) from public.crm_sessions s
 where s.email_clinica in ('bulhoes-clinica-crm','bulhoes-fluxo-tratamento','bulhoes-calendario-sazonal','bulhoes-agenda-avaliacoes');

delete from public.espelho_erros where true;

select public.conferir_espelho() as conferencia;
