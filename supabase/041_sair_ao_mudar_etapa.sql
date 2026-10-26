-- ============================================================
-- CRM Bulhões — Sequência sai na hora quando o paciente muda de etapa (26/10/2026)
-- Antes, a sequência que entrou por uma etapa (ex.: Lead) só saía no próximo
-- passo, quando o "se etapa" conferia — até lá aparecia como "Ativo" na
-- Central, mesmo com o paciente já em Perdido/Agendou. Agora, ao mudar a etapa,
-- as sequências que entraram por outra etapa saem na hora (motivo "mudou de
-- etapa") e só depois entram as da etapa nova.
-- Rodar no Supabase: SQL Editor → New query → colar tudo → Run.
-- ============================================================
create or replace function public.automacao_sair_por_etapa(p_telefone text, p_etapa text)
returns integer
language plpgsql security definer set search_path = public, pg_temp as $$
declare e record; n integer := 0;
begin
  for e in
    select x.id, x.automacao_id, x.passo, x.contexto->>'etapa' as etapa_entrada
      from public.automacao_execucoes x
     where x.telefone = p_telefone and x.status = 'ativa' and x.entrou_por = 'gatilho: etapa'
       and lower(coalesce(x.contexto->>'etapa', '')) is distinct from lower(coalesce(p_etapa, ''))
  loop
    update public.automacao_execucoes set status = 'saiu', motivo = 'mudou de etapa', terminou_em = now() where id = e.id;
    insert into public.automacao_log (automacao_id, execucao_id, telefone, passo, acao, detalhe)
    values (e.automacao_id, e.id, p_telefone, e.passo, 'saiu', 'mudou de etapa: ' || coalesce(e.etapa_entrada, '?') || ' → ' || coalesce(p_etapa, '(sem etapa)'));
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.automacao_sair_por_etapa(text, text) from public, anon, authenticated;

create or replace function public.automacao_t_pacientes() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if tg_op = 'UPDATE' and lower(new.etapa) is distinct from lower(old.etapa) then
    perform public.automacao_sair_por_etapa(new.telefone, new.etapa);
  end if;
  if not public.automacoes_alguma_ligada() then return new; end if;
  if tg_op = 'INSERT' then
    perform public.automacao_disparar('lead_criado', new.telefone, jsonb_build_object('origem', new.origem, 'etapa', new.etapa));
    if new.etapa is not null then
      perform public.automacao_disparar('etapa', new.telefone, jsonb_build_object('etapa', new.etapa, 'antes', null));
    end if;
  elsif lower(new.etapa) is distinct from lower(old.etapa) and new.etapa is not null then
    perform public.automacao_disparar('etapa', new.telefone, jsonb_build_object('etapa', new.etapa, 'antes', old.etapa));
  end if;
  return new;
exception when others then
  insert into public.espelho_erros (origem, erro, detalhe) values ('automacao_t_pacientes', sqlerrm, new.telefone);
  return new;
end $$;

-- quem já mudou de etapa e ainda está com sequência ativa da etapa anterior
select count(*) as ajustadas from (
  select public.automacao_sair_por_etapa(p.telefone, p.etapa)
    from public.pacientes p
   where exists (select 1 from public.automacao_execucoes x
                  where x.telefone = p.telefone and x.status = 'ativa' and x.entrou_por = 'gatilho: etapa'
                    and lower(coalesce(x.contexto->>'etapa', '')) is distinct from lower(coalesce(p.etapa, '')))
) t;
