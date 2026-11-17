-- ============================================================
-- 203 (17/11/2026) INSTITUTO: a aplicação para dentistas cai na Lume
--   Pedido do Lucas. Texto e regra aprovados em 17/11
--   (projeto: claude/aplicacao-e-obrigado.md).
--
--   1. instituto_leads ganha: produto (expert | presencial), oferta
--      sugerida, respostas da aplicação, porta (bio ou anúncio), UTMs e
--      data da aplicação. Nova etapa "nutricao" (sem perfil agora).
--      Origem passa a ser: anuncio, organico, social_selling, outro
--      ('aplicacao' continua aceita para cards antigos).
--   2. instituto_aplicar(jsonb): o que a página de aplicação chama.
--      Valida, calcula a oferta pela tabela aprovada e cria (ou atualiza)
--      o card. Pode ser chamada sem login (a página é pública), só faz
--      isso e nada mais.
-- Não mexe em nada da clínica. Pode rodar mais de uma vez.
-- ============================================================

alter table public.instituto_leads add column if not exists produto text;
alter table public.instituto_leads add column if not exists oferta_sugerida text;
alter table public.instituto_leads add column if not exists respostas jsonb;
alter table public.instituto_leads add column if not exists porta text;
alter table public.instituto_leads add column if not exists utm jsonb;
alter table public.instituto_leads add column if not exists aplicou_em timestamptz;

alter table public.instituto_leads drop constraint if exists instituto_leads_produto_check;
alter table public.instituto_leads add constraint instituto_leads_produto_check check (produto in ('expert', 'presencial'));
alter table public.instituto_leads drop constraint if exists instituto_leads_oferta_sugerida_check;
alter table public.instituto_leads add constraint instituto_leads_oferta_sugerida_check check (oferta_sugerida in ('expert', 'presencial', 'nenhuma', 'sdr'));
alter table public.instituto_leads drop constraint if exists instituto_leads_porta_check;
alter table public.instituto_leads add constraint instituto_leads_porta_check check (length(porta) <= 40);
alter table public.instituto_leads drop constraint if exists instituto_leads_origem_check;
alter table public.instituto_leads add constraint instituto_leads_origem_check
  check (origem in ('anuncio', 'organico', 'social_selling', 'outro', 'aplicacao'));
alter table public.instituto_leads drop constraint if exists instituto_leads_etapa_check;
alter table public.instituto_leads add constraint instituto_leads_etapa_check check (etapa in
  ('lead', 'aplicacao', 'qualificado', 'call_agendada', 'call_realizada', 'proposta', 'venda', 'perdido', 'nutricao'));

create index if not exists instituto_leads_aplicou on public.instituto_leads (aplicou_em desc);

-- ------------------------------------------------------------
-- Recebe a aplicação
-- ------------------------------------------------------------
create or replace function public.instituto_aplicar(p jsonb)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_nome text := btrim(coalesce(p->>'nome', ''));
  v_tel text := regexp_replace(coalesce(p->>'whatsapp', ''), '\D', '', 'g');
  v_ig text := nullif(lower(btrim(replace(coalesce(p->>'instagram', ''), '@', ''))), '');
  v_momento text := p->>'momento';
  v_cobra text := p->>'cobra';
  v_santos text := p->>'santos';
  v_invest text := p->>'investimento';
  v_casos int;
  v_desafios jsonb := coalesce(p->'desafios', '[]'::jsonb);
  v_porta text := left(nullif(btrim(coalesce(p->>'porta', '')), ''), 40);
  v_utm jsonb := '{}'::jsonb;
  v_oferta text;
  v_origem text;
  v_resp jsonb;
  v_id bigint;
  v_card public.instituto_leads;
  k text;
begin
  -- campo escondido: robô preenche, gente não vê
  if coalesce(p->>'site', '') <> '' then return jsonb_build_object('ok', true); end if;

  if length(v_nome) < 2 or length(v_nome) > 200 then raise exception 'nome inválido'; end if;
  if v_tel ~ '^55\d{10,11}$' then v_tel := substr(v_tel, 3); end if;
  if v_tel !~ '^\d{10,11}$' then raise exception 'WhatsApp inválido'; end if;
  if v_ig is not null and length(v_ig) > 100 then raise exception 'Instagram inválido'; end if;
  if v_momento is null or v_momento not in ('recem_formado', 'dono_clinica', 'clinica_popular', 'clinica_parceiro', 'estudante') then raise exception 'momento inválido'; end if;
  if v_cobra is null or v_cobra not in ('nao_faz', 'ate_1000', '1000_2500', '2500_4000', '4000_5000', '5000_mais') then raise exception 'valor cobrado inválido'; end if;
  if v_santos is null or v_santos not in ('sim', 'nao') then raise exception 'disponibilidade inválida'; end if;
  if v_invest is null or v_invest not in ('avista', 'parcelado', 'organizar', 'nao') then raise exception 'investimento inválido'; end if;
  if jsonb_typeof(v_desafios) <> 'array' or exists (
       select 1 from jsonb_array_elements_text(v_desafios) d where d not in ('comecar', 'tecnica', 'naturalidade', 'captacao')) then
    raise exception 'desafio inválido';
  end if;
  v_casos := case when coalesce(p->>'casos_mes', '') ~ '^\d{1,3}$' then (p->>'casos_mes')::int else null end;

  foreach k in array array['utm_source', 'utm_medium', 'utm_campaign', 'utm_content', 'utm_term'] loop
    if nullif(btrim(coalesce(p->>k, '')), '') is not null then
      v_utm := v_utm || jsonb_build_object(k, left(btrim(p->>k), 200));
    end if;
  end loop;

  -- oferta pela tabela aprovada (17/11), na ordem
  v_oferta := case
    when v_momento = 'estudante' or v_invest = 'nao' then 'nenhuma'
    when v_momento in ('dono_clinica', 'clinica_parceiro') and v_cobra in ('2500_4000', '4000_5000', '5000_mais')
         and v_invest in ('avista', 'parcelado') then 'expert'
    when (v_momento = 'recem_formado' or v_cobra = 'nao_faz') and v_santos = 'sim' then 'presencial'
    when (v_momento = 'clinica_popular' or v_cobra in ('ate_1000', '1000_2500')) and v_santos = 'sim' then 'presencial'
    when v_santos = 'nao' and v_invest in ('avista', 'parcelado') then 'expert'
    when v_invest = 'organizar' and v_santos = 'sim' then 'presencial'
    else 'sdr' end;

  v_origem := case when v_porta ilike 'anuncio%' or lower(coalesce(v_utm->>'utm_medium', '')) ~ '(paid|cpc|ads|anuncio)'
                   then 'anuncio' else 'organico' end;

  v_resp := jsonb_build_object('momento', v_momento, 'desafios', v_desafios, 'cobra', v_cobra,
                               'casos_mes', v_casos, 'santos', v_santos, 'investimento', v_invest);

  -- a mesma pessoa aplicou há menos de 2 minutos: é clique repetido
  if exists (select 1 from public.instituto_leads where telefone = v_tel and aplicou_em > now() - interval '2 minutes') then
    return jsonb_build_object('ok', true, 'perfil', v_oferta);
  end if;

  -- já tem card ativo: atualiza as respostas (não cria outro)
  select * into v_card from public.instituto_leads
   where telefone = v_tel and etapa not in ('venda', 'perdido')
   order by atualizado_em desc limit 1;

  if found then
    update public.instituto_leads set
      nome = coalesce(nome, v_nome), instagram = coalesce(instagram, v_ig),
      respostas = v_resp, oferta_sugerida = v_oferta, porta = coalesce(v_porta, porta),
      utm = case when v_utm = '{}'::jsonb then utm else v_utm end,
      origem = coalesce(origem, v_origem), aplicou_em = now(),
      etapa = case when etapa in ('lead', 'nutricao') then (case when v_oferta = 'nenhuma' then 'nutricao' else 'aplicacao' end) else etapa end,
      atualizado_por = 'aplicação'
    where id = v_card.id;
    v_id := v_card.id;
  else
    insert into public.instituto_leads (nome, telefone, instagram, origem, etapa, oferta_sugerida, respostas, porta, utm, aplicou_em, criado_por, atualizado_por,
                                        conversa_id)
    values (v_nome, v_tel, v_ig, v_origem, case when v_oferta = 'nenhuma' then 'nutricao' else 'aplicacao' end,
            v_oferta, v_resp, v_porta, nullif(v_utm, '{}'::jsonb), now(), 'aplicação', 'aplicação',
            (select c.id from public.conversas c
              where c.telefone = v_tel and c.numero_clinica_id = any (array(select phone_number_id from public.whatsapp_numeros where espaco = 'instituto'))
                and not exists (select 1 from public.instituto_leads l where l.conversa_id = c.id)
              order by c.ultima_mensagem_em desc nulls last limit 1))
    returning id into v_id;
  end if;

  return jsonb_build_object('ok', true, 'perfil', v_oferta);
end $$;

revoke all on function public.instituto_aplicar(jsonb) from public;
grant execute on function public.instituto_aplicar(jsonb) to anon, authenticated;

-- ------------------------------------------------------------
-- Conferência: uma aplicação de teste, conferida e apagada em seguida
-- ------------------------------------------------------------
do $$
declare r jsonb; l public.instituto_leads;
begin
  r := public.instituto_aplicar('{"nome":"Teste Lume","whatsapp":"(13) 90000-0000","instagram":"@teste","momento":"dono_clinica","desafios":["tecnica"],"cobra":"4000_5000","casos_mes":"6","santos":"nao","investimento":"parcelado","porta":"bio"}'::jsonb);
  select * into l from public.instituto_leads where telefone = '13900000000';
  raise notice 'retorno: %, etapa: %, oferta: %, origem: %', r, l.etapa, l.oferta_sugerida, l.origem;
  if l.oferta_sugerida is distinct from 'expert' or l.etapa is distinct from 'aplicacao' then
    raise exception 'conferência falhou: % %', l.etapa, l.oferta_sugerida;
  end if;
  delete from public.instituto_leads where telefone = '13900000000';
end $$;

select 'ok' as resultado, 'aplicação recebe e calcula a oferta (teste apagado)' as detalhe;
