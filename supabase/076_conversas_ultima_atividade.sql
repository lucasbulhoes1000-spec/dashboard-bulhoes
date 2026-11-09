-- =====================================================================
-- 076 (09/11/2026): ordem da lista da Central de mensagens
--   Mensagem enviada por automação (template, lembrete, disparo) não sobe a
--   conversa para o topo. Só contam: mensagem do paciente, mensagem da equipe
--   (autor com e-mail) e resposta da IA.
--   A lista passa a ordenar por conversas.ultima_atividade_em.
-- =====================================================================

alter table public.conversas add column if not exists ultima_atividade_em timestamptz;

create or replace function public.conversa_atividade_conta(p_direcao text, p_autor text)
returns boolean language sql immutable as $$
  select p_direcao = 'recebida' or coalesce(p_autor, '') like '%@%' or coalesce(p_autor, '') like 'IA:%';
$$;

create or replace function public.t_conversa_ultima_atividade()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.conversa_id is null then return new; end if;
  if public.conversa_atividade_conta(new.direcao, new.autor_email) then
    update public.conversas
       set ultima_atividade_em = greatest(coalesce(ultima_atividade_em, '-infinity'::timestamptz), coalesce(new.enviada_em, now()))
     where id = new.conversa_id;
  else
    -- conversa que só tem automação: entra na lista pela primeira mensagem, mas não sobe depois
    update public.conversas
       set ultima_atividade_em = coalesce(new.enviada_em, now())
     where id = new.conversa_id and ultima_atividade_em is null;
  end if;
  return new;
end $$;

drop trigger if exists t_conversa_ultima_atividade on public.mensagens;
create trigger t_conversa_ultima_atividade after insert on public.mensagens
  for each row execute function public.t_conversa_ultima_atividade();

-- histórico
update public.conversas c
   set ultima_atividade_em = x.t
  from (
    select conversa_id,
           coalesce(max(enviada_em) filter (where public.conversa_atividade_conta(direcao, autor_email)), min(enviada_em)) as t
      from public.mensagens
     where conversa_id is not null
     group by conversa_id
  ) x
 where c.id = x.conversa_id;

update public.conversas set ultima_atividade_em = coalesce(ultima_mensagem_em, now()) where ultima_atividade_em is null;

create index if not exists conversas_ultima_atividade_idx on public.conversas (ultima_atividade_em desc nulls last);

select count(*) filter (where ultima_atividade_em < ultima_mensagem_em - interval '1 minute') as descem_por_automacao,
       count(*) as total
  from public.conversas;
