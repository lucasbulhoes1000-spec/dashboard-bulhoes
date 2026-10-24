-- ============================================================
-- CRM Bulhões — Virada do Cloudia: colocar nas sequências do CRM quem já
-- estava no meio das sequências do Cloudia (24/10/2026)
-- Para cada pessoa hoje na etapa Lead (ou Faltou/desmarcou), conta o tempo
-- desde que entrou na etapa e coloca em cada sequência cujo envio AINDA NÃO
-- passou, já agendado para a hora certa (ex.: virou lead há 3 dias → entra no
-- FUP 7 dias para daqui a 4 dias; os de 24 h, 2 e 3 dias o Cloudia já mandou).
-- Uso:
--   select * from public.virada_sequencias(true);   -- só simula (não grava)
--   select * from public.virada_sequencias(false);  -- grava (rodar na virada,
--                                                    -- com as sequências ligadas)
-- Rodar no Supabase: SQL Editor → New query → colar tudo → Run.
-- ============================================================

create or replace function public.virada_sequencias(p_simular boolean default true)
returns table (sequencia text, pessoas integer, primeiro_envio timestamptz, ultimo_envio timestamptz)
language plpgsql security definer set search_path = public, migracao, pg_temp as $$
declare a record; r record; v_espera integer; v_etapa text; v_quando timestamptz; v_id bigint; v_conv uuid;
  v_n integer; v_min timestamptz; v_max timestamptz;
begin
  if not public.tem_papel('gestao') and current_user not in ('postgres', 'supabase_admin') then
    raise exception 'sem permissão';
  end if;
  for a in select * from public.automacoes
            where nome ~ '^(FUP|Faltantes) ' and jsonb_typeof(passos) = 'array' order by id loop
    v_espera := coalesce((select (p->>'minutos')::integer from jsonb_array_elements(a.passos) p where p->>'tipo' = 'esperar' limit 1), 0);
    v_etapa := a.gatilho->'lista'->0->>'etapa';
    if v_espera <= 0 or v_etapa is null then continue; end if;
    v_n := 0; v_min := null; v_max := null;
    for r in select p.telefone, coalesce(p.etapa_alterada_em, p.criado_em) as desde
               from public.pacientes p
              where lower(btrim(p.etapa)) = lower(v_etapa)
                and p.telefone ~ '^[0-9]{10,13}$'
                and coalesce(p.etapa_alterada_em, p.criado_em) + make_interval(mins => v_espera) > now()
                and coalesce(p.etapa_alterada_em, p.criado_em) > now() - interval '61 days' loop
      if exists (select 1 from public.automacao_execucoes e where e.automacao_id = a.id and e.telefone = r.telefone and e.status = 'ativa') then
        continue;
      end if;
      v_quando := r.desde + make_interval(mins => v_espera);
      v_n := v_n + 1; v_min := least(coalesce(v_min, v_quando), v_quando); v_max := greatest(coalesce(v_max, v_quando), v_quando);
      if not p_simular then
        select c.id into v_conv from public.conversas c
         where c.telefone = r.telefone and (a.numero_clinica_id is null or c.numero_clinica_id = a.numero_clinica_id)
         order by c.ultima_mensagem_em desc nulls last limit 1;
        -- já entra depois do passo "esperar", marcado para a hora em que o Cloudia mandaria
        insert into public.automacao_execucoes (automacao_id, telefone, conversa_id, passo, proxima_em, entrou_em, entrou_por, contexto)
        values (a.id, r.telefone, v_conv, 1, v_quando, r.desde, 'virada do Cloudia', jsonb_build_object('virada', true))
        on conflict do nothing returning id into v_id;
        if v_id is not null then
          insert into public.automacao_log (automacao_id, execucao_id, telefone, passo, acao, detalhe)
          values (a.id, v_id, r.telefone, 0, 'entrou', 'virada do Cloudia: envio em ' || to_char(v_quando at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'));
        end if;
      end if;
    end loop;
    sequencia := a.nome; pessoas := v_n; primeiro_envio := v_min; ultimo_envio := v_max;
    return next;
  end loop;
end $$;
revoke all on function public.virada_sequencias(boolean) from public, anon;
grant execute on function public.virada_sequencias(boolean) to authenticated;

select * from public.virada_sequencias(true);
