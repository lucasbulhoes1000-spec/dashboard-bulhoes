-- ============================================================
-- CRM Bulhões — Correções do funil sem o Cloudia (24/10/2026)
-- Comparação CRM × Cloudia de 22/10 21h a 24/10 mostrou três diferenças:
--   1. Lead novo: o CRM achava "novo" quem já era contato no WhatsApp (o
--      cadastro do paciente chegava DEPOIS da conversa). Agora "conhecido" é
--      quem já mandou ou recebeu mensagem antes (no CRM ou na planilha do
--      Cloudia), igual ao Cloudia, que só conhece contatos do WhatsApp.
--   2. Mudança de etapa repetida: uma sincronização regrava a etapa de algumas
--      pessoas a cada 30 min, alternando (Agendou ↔ Ganho), e cada vez virava
--      um evento novo (180 eventos para a mesma pessoa em 2 dias). Agora a
--      etapa só gera evento quando é nova para aquela pessoa nos últimos
--      30 dias e não é um passo para trás no funil (ex.: Ganho → Agendou).
--   3. Origem trocada à mão no CRM (ex.: Social Selling) agora também vira
--      evento de troca de origem, como no Cloudia.
-- Os eventos que já estão gravados ficam como estão (o Dashboard ainda não
-- usa os eventos do CRM; só passa a usar a partir de funil_proprio_desde).
-- Rodar no Supabase: SQL Editor → New query → colar tudo → Run.
-- ============================================================

-- posição de cada etapa no funil (passo para trás não conta como evento)
create or replace function public.funil_ordem_etapa(p text)
returns integer
language sql immutable as $$
  select case lower(btrim(coalesce(p, '')))
    when 'lead' then 0
    when 'agendou' then 1
    when 'faltou/desmarcou' then 1
    when 'compareceu' then 2
    when 'ganho' then 3
    when 'perdido' then 3
    when 'paciente' then 4
    else 0 end;
$$;

-- 1. Lead novo
create or replace function public.funil_t_mensagem()
returns trigger
language plpgsql security definer set search_path = public, migracao, pg_temp as $$
declare
  c public.conversas; v_cria boolean; v_ad text; v_origem text; v_nome text; v_conhecido boolean;
  an record;
begin
  if new.direcao <> 'recebida' or coalesce(new.canal, 'paciente') <> 'paciente'
     or new.enviada_em < now() - interval '1 day' then
    return null;
  end if;
  select * into c from public.conversas where id = new.conversa_id;
  if c.id is null or c.telefone !~ '^[0-9]{10,13}$' then return null; end if;
  select n.cria_leads into v_cria from public.whatsapp_numeros n where n.phone_number_id = c.numero_clinica_id;
  if v_cria is false then return null; end if;

  v_ad := case when new.origem_anuncio->>'source_type' = 'ad' then nullif(new.origem_anuncio->>'source_id', '') end;
  v_origem := case when new.origem_anuncio is not null and new.origem_anuncio->>'source_type' = 'ad' then '#Instagram ADS' else '#Organico' end;
  v_nome := coalesce(nullif(btrim(c.nome_contato), ''), nullif(btrim(c.nome_perfil), ''));

  -- conhecido = já conversou com a clínica pelo WhatsApp antes desta mensagem
  v_conhecido :=
       exists (select 1 from public.eventos_proprios e where e.telefone = c.telefone and e.tipo = 'CUSTOMER_CREATED')
    or exists (select 1 from public.conversas c2 join public.mensagens m2 on m2.conversa_id = c2.id
                where c2.telefone = c.telefone and m2.id <> new.id
                  and m2.enviada_em < new.enviada_em - interval '2 minutes');
  if not v_conhecido and to_regclass('public.importacao_cloudia') is not null then
    execute 'select exists (select 1 from public.importacao_cloudia where migracao.tel(phone) = $1
                              and migracao.ts("timestamp") < $2 - interval ''2 minutes'')'
      into v_conhecido using c.telefone, new.enviada_em;
  end if;

  if not v_conhecido then
    select * into an from public.funil_anuncio(v_ad);
    insert into public.eventos_proprios
      (telefone, tipo, nome, etapa, origem, ad_id, ad_name, adset_name, campaign_name, ocorrido_em, lead_criado_em, fonte, conversa_id)
    values
      (c.telefone, 'CUSTOMER_CREATED', v_nome, 'Lead', v_origem, v_ad, an.ad_name, an.adset_name, an.campaign_name,
       new.enviada_em, new.enviada_em, 'whatsapp', c.id);
    insert into public.pacientes (telefone, nome, origem, etapa, etapa_alterada_em, criado_em, legado)
    values (c.telefone, v_nome, v_origem, 'Lead', new.enviada_em, new.enviada_em, jsonb_build_object('fonte', 'whatsapp'))
    on conflict (telefone) do nothing;
    update public.conversas set paciente_id = (select id from public.pacientes where telefone = c.telefone)
     where id = c.id and paciente_id is null;
  elsif v_ad is not null and not exists (
      select 1 from public.eventos_proprios e
       where e.telefone = c.telefone and e.ad_id = v_ad and e.ocorrido_em > new.enviada_em - interval '7 days') then
    select * into an from public.funil_anuncio(v_ad);
    insert into public.eventos_proprios
      (telefone, tipo, nome, etapa, origem, ad_id, ad_name, adset_name, campaign_name, ocorrido_em, fonte, conversa_id)
    select c.telefone, 'CUSTOMER_ACQUISITION_ORIGIN_UPDATED', coalesce(p.nome, v_nome), p.etapa, '#Instagram ADS',
           v_ad, an.ad_name, an.adset_name, an.campaign_name, new.enviada_em, 'whatsapp', c.id
      from (select 1) x left join public.pacientes p on p.telefone = c.telefone;
  end if;
  return null;
exception when others then
  insert into public.espelho_erros (origem, erro, detalhe) values ('funil_t_mensagem', sqlerrm, new.conversa_id::text);
  return null;
end $$;

-- 2. Mudança de etapa (e 3. troca de origem feita à mão)
create or replace function public.funil_t_etapa()
returns trigger
language plpgsql security definer set search_path = public, migracao, pg_temp as $$
declare an record; v_ultima text; v_mudou_etapa boolean; v_mudou_origem boolean;
begin
  v_mudou_etapa := new.etapa is not null and lower(btrim(new.etapa)) is distinct from lower(btrim(old.etapa))
                   and new.etapa_alterada_em is not null and new.etapa_alterada_em >= now() - interval '1 day';
  v_mudou_origem := nullif(btrim(new.origem), '') is not null and new.origem is distinct from old.origem;

  if v_mudou_etapa then
    -- já houve esta mesma etapa para a pessoa nos últimos 30 dias: não é mudança nova
    if exists (select 1 from public.eventos_proprios e
                where e.telefone = new.telefone and e.tipo = 'CUSTOMER_STAGE_UPDATED'
                  and lower(e.etapa) = lower(new.etapa) and e.ocorrido_em > now() - interval '30 days') then
      v_mudou_etapa := false;
    end if;
  end if;
  if v_mudou_etapa then
    -- passo para trás no funil em relação ao último evento dos últimos 30 dias (ex.: Ganho → Agendou)
    select e.etapa into v_ultima from public.eventos_proprios e
     where e.telefone = new.telefone and e.tipo = 'CUSTOMER_STAGE_UPDATED' and e.ocorrido_em > now() - interval '30 days'
     order by e.ocorrido_em desc limit 1;
    if v_ultima is not null and public.funil_ordem_etapa(new.etapa) < public.funil_ordem_etapa(v_ultima)
       and lower(new.etapa) <> 'lead' then
      v_mudou_etapa := false;
    end if;
  end if;

  if not v_mudou_etapa and not v_mudou_origem then return null; end if;

  if new.ad_id_manual is not null then
    select new.ad_id_manual as ad_id, f.ad_name, f.adset_name, f.campaign_name into an from public.funil_anuncio(new.ad_id_manual) f;
    if not found then select new.ad_id_manual as ad_id, null::text as ad_name, null::text as adset_name, null::text as campaign_name into an; end if;
  else
    select * into an from public.funil_ultimo_anuncio(new.telefone);
  end if;

  if v_mudou_etapa then
    insert into public.eventos_proprios
      (telefone, tipo, nome, etapa, origem, ad_id, ad_name, adset_name, campaign_name, ocorrido_em, lead_criado_em, fonte)
    values
      (new.telefone, 'CUSTOMER_STAGE_UPDATED', new.nome, new.etapa, new.origem, an.ad_id, an.ad_name, an.adset_name, an.campaign_name,
       least(new.etapa_alterada_em, now()), new.criado_em, 'crm');
  end if;
  if v_mudou_origem and not exists (
       select 1 from public.eventos_proprios e
        where e.telefone = new.telefone and e.tipo = 'CUSTOMER_ACQUISITION_ORIGIN_UPDATED'
          and e.origem = new.origem and e.ocorrido_em > now() - interval '30 days') then
    insert into public.eventos_proprios
      (telefone, tipo, nome, etapa, origem, ad_id, ad_name, adset_name, campaign_name, ocorrido_em, lead_criado_em, fonte)
    values
      (new.telefone, 'CUSTOMER_ACQUISITION_ORIGIN_UPDATED', new.nome, new.etapa, new.origem,
       case when new.origem ilike '%ads%' then an.ad_id end, case when new.origem ilike '%ads%' then an.ad_name end,
       case when new.origem ilike '%ads%' then an.adset_name end, case when new.origem ilike '%ads%' then an.campaign_name end,
       now(), new.criado_em, 'crm');
  end if;
  return null;
exception when others then
  insert into public.espelho_erros (origem, erro, detalhe) values ('funil_t_etapa', sqlerrm, new.telefone);
  return null;
end $$;

-- o gatilho de etapa passa a olhar também a origem
drop trigger if exists t_funil_etapa on public.pacientes;
create trigger t_funil_etapa after update of etapa, origem on public.pacientes
  for each row execute function public.funil_t_etapa();

select 'funil do CRM corrigido' as status;
