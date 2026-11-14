-- ============================================================
-- 081 (14/11/2026): fila do histórico da coexistência
--   O histórico importado do celular chega em lotes enormes e processar na hora travou o banco.
--   O webhook agora só guarda o lote aqui; um processador lento (wa_historico_processar)
--   grava poucos lotes por vez.
-- ============================================================
create table if not exists public.whatsapp_historico_fila (
  id bigserial primary key,
  corpo jsonb not null,
  recebido_em timestamptz not null default now(),
  processado_em timestamptz,
  erro text
);
alter table public.whatsapp_historico_fila enable row level security;
revoke all on public.whatsapp_historico_fila from anon, authenticated;
grant all on public.whatsapp_historico_fila to service_role;
grant usage, select on sequence public.whatsapp_historico_fila_id_seq to service_role;

-- processa até p_limite lotes (chamar de tempos em tempos)
create or replace function public.wa_historico_processar(p_limite integer default 3)
returns integer
language plpgsql security definer set search_path = public, pg_temp as $$
declare r record; n integer := 0;
begin
  for r in select id, corpo from public.whatsapp_historico_fila
            where processado_em is null order by id limit p_limite for update skip locked loop
    begin
      perform public.wa_processar(r.corpo);
      update public.whatsapp_historico_fila set processado_em = now(), erro = null where id = r.id;
    exception when others then
      update public.whatsapp_historico_fila set processado_em = now(), erro = left(sqlerrm, 500) where id = r.id;
    end;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.wa_historico_processar(integer) from public, anon, authenticated;
grant execute on function public.wa_historico_processar(integer) to service_role;

select 'fila criada' as ok;
