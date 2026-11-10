-- =====================================================================
-- 078 (10/11/2026): apagar conversa da Central (pedido do Lucas)
--   "Apagar" esconde a conversa da lista; o histórico fica guardado.
--   Se o paciente mandar mensagem de novo, ela volta para a lista.
-- =====================================================================

alter table public.conversas add column if not exists oculta_em timestamptz;

create or replace function public.t_conversa_reaparece()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.conversa_id is not null and new.direcao = 'recebida' then
    update public.conversas set oculta_em = null
     where id = new.conversa_id and oculta_em is not null;
  end if;
  return new;
end $$;

drop trigger if exists t_conversa_reaparece on public.mensagens;
create trigger t_conversa_reaparece after insert on public.mensagens
  for each row execute function public.t_conversa_reaparece();

select count(*) as conversas, count(oculta_em) as ocultas from public.conversas;
