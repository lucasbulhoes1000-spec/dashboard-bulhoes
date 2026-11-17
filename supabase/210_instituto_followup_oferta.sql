-- 210 (Instituto, 17/11/2026): quadro de Oportunidades igual ao de Clientes da clínica
--   fup_etapa: em qual mensagem do follow-up o card está (1. Agradecimento a 7. Despedida, ou Cadência mensal)
--   oferta_em: data da oferta, de onde contam os prazos de cada mensagem (igual a data da avaliação na clínica)
--   Ao entrar em Follow-up (etapa proposta), o card ganha a data da oferta e começa no 1. Agradecimento.
-- Só mexe na tabela instituto_leads. Nada da clínica.
alter table public.instituto_leads add column if not exists fup_etapa text;
alter table public.instituto_leads add column if not exists oferta_em timestamptz;

create or replace function public.instituto_leads_followup() returns trigger
language plpgsql set search_path = public, pg_temp as $$
begin
  if new.etapa = 'proposta' and (tg_op = 'INSERT' or old.etapa is distinct from 'proposta') then
    new.oferta_em := coalesce(new.oferta_em, now());
    new.fup_etapa := coalesce(new.fup_etapa, '1. Agradecimento');
  end if;
  return new;
end $$;

drop trigger if exists instituto_leads_followup on public.instituto_leads;
create trigger instituto_leads_followup before insert or update of etapa on public.instituto_leads
  for each row execute function public.instituto_leads_followup();

-- cards que já estão em Follow-up: data da oferta tirada do resumo da leitura do WhatsApp
-- ("Recebeu material 28/10" etc.); sem data no resumo, fica a data em que entraram em Follow-up
update public.instituto_leads l
   set oferta_em = coalesce(
         (select make_date(2026, m[2]::int, m[1]::int)::timestamptz
            from regexp_match(l.obs, '(?:material|PDF|valores|proposta|oferecemos)[^0-9]{0,40}([0-3][0-9])/([01][0-9])') m
           where m is not null and m[2]::int between 1 and 12 and m[1]::int between 1 and 31),
         (select make_date(2026, m[2]::int, m[1]::int)::timestamptz
            from regexp_match(l.obs, '([0-3][0-9])/([01][0-9])') m
           where m is not null and m[2]::int between 1 and 12 and m[1]::int between 1 and 31),
         l.etapa_em),
       fup_etapa = coalesce(l.fup_etapa, '1. Agradecimento')
 where l.etapa = 'proposta' and l.oferta_em is null;

select count(*) filter (where etapa = 'proposta') as em_follow_up, count(oferta_em) as com_data_da_oferta from public.instituto_leads;
