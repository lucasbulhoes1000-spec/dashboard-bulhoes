-- =====================================================================
-- 077 (10/11/2026): disparo fica 2 dias para trás na Central
--   Pedido do Lucas: a conversa que recebe disparo não sobe para o topo;
--   ela entra na lista como se a última atividade fosse 2 dias antes do envio.
--   Se o paciente responder, a conversa sobe normalmente.
--   Automação e lembrete continuam como no 076 (não mexem na ordem).
-- =====================================================================

create or replace function public.t_conversa_ultima_atividade()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.conversa_id is null then return new; end if;
  if public.conversa_atividade_conta(new.direcao, new.autor_email) then
    update public.conversas
       set ultima_atividade_em = greatest(coalesce(ultima_atividade_em, '-infinity'::timestamptz), coalesce(new.enviada_em, now()))
     where id = new.conversa_id;
  elsif coalesce(new.autor_email, '') like 'disparo:%' then
    update public.conversas
       set ultima_atividade_em = greatest(coalesce(ultima_atividade_em, '-infinity'::timestamptz), coalesce(new.enviada_em, now()) - interval '2 days')
     where id = new.conversa_id;
  else
    update public.conversas
       set ultima_atividade_em = coalesce(new.enviada_em, now())
     where id = new.conversa_id and ultima_atividade_em is null;
  end if;
  return new;
end $$;

-- disparos já feitos: conversa cuja última atividade é o próprio disparo vai para 2 dias antes dele
update public.conversas c
   set ultima_atividade_em = x.t - interval '2 days'
  from (
    select conversa_id, max(enviada_em) as t
      from public.mensagens
     where autor_email like 'disparo:%' and conversa_id is not null
     group by conversa_id
  ) x
 where c.id = x.conversa_id
   and c.ultima_atividade_em >= x.t
   and not exists (
     select 1 from public.mensagens m
      where m.conversa_id = c.id and m.enviada_em >= x.t
        and public.conversa_atividade_conta(m.direcao, m.autor_email));

select count(*) as conversas_de_disparo_ajustadas
  from public.conversas c
 where exists (select 1 from public.mensagens m where m.conversa_id = c.id and m.autor_email like 'disparo:%');
