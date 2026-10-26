-- ============================================================
-- CRM Bulhões — Desliga a cópia da planilha do Cloudia (25/10/2026)
-- O CRM para de receber os eventos que o Cloudia grava na planilha (aba
-- Leads). O histórico já copiado fica em importacao_cloudia (o Dashboard usa
-- até funil_proprio_desde); daí em diante só valem os eventos do próprio CRM.
-- O espelho das gravações do CRM (crm_sessions → pacientes) continua ligado:
-- é ele que leva as mudanças de etapa da equipe para as sequências.
-- Religar: update public.configuracoes set valor = 'false' where chave = 'cloudia_desligado';
-- Rodar no Supabase: SQL Editor → New query → colar tudo → Run.
-- ============================================================
insert into public.configuracoes (chave, valor, atualizado_por)
values ('cloudia_desligado', 'true'::jsonb, 'virada')
on conflict (chave) do update set valor = 'true'::jsonb, atualizado_por = 'virada';

create or replace function public.cloudia_desligado() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select valor = 'true'::jsonb from public.configuracoes where chave = 'cloudia_desligado'), false);
$$;

do $$
declare f text; d text;
begin
  foreach f in array array['public.espelhar_linhas_cloudia(text[],jsonb,integer[])', 'public.espelhar_planilha_cloudia()'] loop
    d := pg_get_functiondef(f::regprocedure);
    if position('public.cloudia_desligado()' in d) = 0 then
      d := replace(d, 'if not public.espelho_ligado() then', 'if not public.espelho_ligado() or public.cloudia_desligado() then');
      execute d;
    end if;
  end loop;
end $$;

select p.proname, position('cloudia_desligado' in pg_get_functiondef(p.oid)) > 0 as desligavel
  from pg_proc p where p.proname in ('espelhar_linhas_cloudia', 'espelhar_planilha_cloudia');
