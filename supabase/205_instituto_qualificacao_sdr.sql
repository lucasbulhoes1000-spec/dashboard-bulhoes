-- ============================================================
-- 205 (17/11/2026) INSTITUTO: qualificação preenchida pela SDR
--   Pedido do Lucas: quem chega pelo WhatsApp ou pelo social selling é
--   qualificado pela SDR na conversa, sem link. Ela preenche no card as
--   mesmas perguntas da aplicação, e a oferta sugerida sai pela mesma
--   regra aprovada em 17/11.
--
--   1. instituto_oferta(respostas): a regra da oferta num lugar só.
--   2. Gatilho: quando as respostas do card mudam e as 4 perguntas que
--      decidem a oferta estão respondidas (momento, quanto cobra, Santos,
--      investimento), recalcula a oferta sugerida.
-- Só tabelas do Instituto. Pode rodar mais de uma vez.
-- ============================================================

create or replace function public.instituto_oferta(r jsonb)
returns text
language sql immutable set search_path = '' as $$
  select case
    when r->>'momento' is null or r->>'cobra' is null or r->>'santos' is null or r->>'investimento' is null then null
    when r->>'momento' = 'estudante' or r->>'investimento' = 'nao' then 'nenhuma'
    when r->>'momento' in ('dono_clinica', 'clinica_parceiro') and r->>'cobra' in ('2500_4000', '4000_5000', '5000_mais')
         and r->>'investimento' in ('avista', 'parcelado') then 'expert'
    when (r->>'momento' = 'recem_formado' or r->>'cobra' = 'nao_faz') and r->>'santos' = 'sim' then 'presencial'
    when (r->>'momento' = 'clinica_popular' or r->>'cobra' in ('ate_1000', '1000_2500')) and r->>'santos' = 'sim' then 'presencial'
    when r->>'santos' = 'nao' and r->>'investimento' in ('avista', 'parcelado') then 'expert'
    when r->>'investimento' = 'organizar' and r->>'santos' = 'sim' then 'presencial'
    else 'sdr' end;
$$;
grant execute on function public.instituto_oferta(jsonb) to authenticated;

create or replace function public.instituto_leads_oferta() returns trigger
language plpgsql set search_path = public, pg_temp as $$
declare v text;
begin
  if new.respostas is not null and (tg_op = 'INSERT' or new.respostas is distinct from old.respostas) then
    v := public.instituto_oferta(new.respostas);
    if v is not null then new.oferta_sugerida := v; end if;
  end if;
  return new;
end $$;

drop trigger if exists instituto_leads_oferta on public.instituto_leads;
create trigger instituto_leads_oferta before insert or update of respostas on public.instituto_leads
  for each row execute function public.instituto_leads_oferta();

-- Conferência: a regra devolve o esperado
select public.instituto_oferta('{"momento":"dono_clinica","cobra":"4000_5000","santos":"nao","investimento":"parcelado"}') as deve_ser_expert,
       public.instituto_oferta('{"momento":"recem_formado","cobra":"nao_faz","santos":"sim","investimento":"organizar"}') as deve_ser_presencial,
       public.instituto_oferta('{"momento":"estudante","cobra":"nao_faz","santos":"sim","investimento":"avista"}') as deve_ser_nenhuma,
       public.instituto_oferta('{"momento":"dono_clinica"}') as incompleta_fica_vazia;
