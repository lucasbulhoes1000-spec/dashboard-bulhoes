-- ============================================================
-- 204 (17/11/2026) INSTITUTO: Leads e Oportunidades, Estudantes e
--   Descarte, card automático para quem chama no WhatsApp do Instituto.
--   Pedido do Lucas.
--
--   1. Etapas novas: 'estudante' e 'descarte' (substituem 'nutricao').
--      Cards em 'nutricao' passam para 'estudante' (se a aplicação diz
--      estudante) ou 'descarte'.
--   2. instituto_aplicar: estudante → Estudantes; "Não no momento" →
--      Descarte (motivo "Sem condição de investir agora").
--   3. MUDANÇA ESTRUTURAL (tabela compartilhada conversas): gatilho que
--      cria o card em "Contato sem aplicação" quando chega conversa nova
--      no WhatsApp do Instituto (431996333326052). Só dispara para esse
--      número (cláusula WHEN), e qualquer erro dele é engolido e anotado
--      em espelho_erros: a chegada da mensagem nunca é afetada.
--   4. Cria o card das conversas do Instituto que já existem e ainda não
--      têm card.
-- Pode rodar mais de uma vez.
-- ============================================================

-- 1. etapas
alter table public.instituto_leads drop constraint if exists instituto_leads_etapa_check;
alter table public.instituto_leads add constraint instituto_leads_etapa_check check (etapa in
  ('lead', 'aplicacao', 'qualificado', 'call_agendada', 'call_realizada', 'proposta', 'venda', 'perdido',
   'estudante', 'descarte', 'nutricao'));

update public.instituto_leads
   set etapa = case when respostas->>'momento' = 'estudante' then 'estudante' else 'descarte' end,
       motivo_perda = coalesce(motivo_perda, case when respostas->>'momento' = 'estudante' then null else 'Sem condição de investir agora' end)
 where etapa = 'nutricao';

alter table public.instituto_leads drop constraint if exists instituto_leads_etapa_check;
alter table public.instituto_leads add constraint instituto_leads_etapa_check check (etapa in
  ('lead', 'aplicacao', 'qualificado', 'call_agendada', 'call_realizada', 'proposta', 'venda', 'perdido',
   'estudante', 'descarte'));

-- 2. aplicação: estudante e descarte
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
  v_etapa text;
  v_motivo text;
  v_card public.instituto_leads;
  k text;
begin
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

  -- (204) estudante → Estudantes; sem condição agora → Descarte
  v_etapa := case when v_momento = 'estudante' then 'estudante' when v_oferta = 'nenhuma' then 'descarte' else 'aplicacao' end;
  v_motivo := case when v_etapa = 'descarte' then 'Sem condição de investir agora' end;

  v_origem := case when v_porta ilike 'anuncio%' or lower(coalesce(v_utm->>'utm_medium', '')) ~ '(paid|cpc|ads|anuncio)'
                   then 'anuncio' else 'organico' end;

  v_resp := jsonb_build_object('momento', v_momento, 'desafios', v_desafios, 'cobra', v_cobra,
                               'casos_mes', v_casos, 'santos', v_santos, 'investimento', v_invest);

  if exists (select 1 from public.instituto_leads where telefone = v_tel and aplicou_em > now() - interval '2 minutes') then
    return jsonb_build_object('ok', true, 'perfil', v_oferta);
  end if;

  select * into v_card from public.instituto_leads
   where telefone = v_tel and etapa not in ('venda', 'perdido')
   order by atualizado_em desc limit 1;

  if found then
    update public.instituto_leads set
      nome = coalesce(nome, v_nome), instagram = coalesce(instagram, v_ig),
      respostas = v_resp, oferta_sugerida = v_oferta, porta = coalesce(v_porta, porta),
      utm = case when v_utm = '{}'::jsonb then utm else v_utm end,
      origem = coalesce(origem, v_origem), aplicou_em = now(),
      etapa = case when etapa in ('lead', 'estudante', 'descarte') then v_etapa else etapa end,
      motivo_perda = case when etapa in ('lead', 'estudante', 'descarte') then v_motivo else motivo_perda end,
      atualizado_por = 'aplicação'
    where id = v_card.id;
  else
    insert into public.instituto_leads (nome, telefone, instagram, origem, etapa, motivo_perda, oferta_sugerida, respostas, porta, utm, aplicou_em,
                                        criado_por, atualizado_por, conversa_id)
    values (v_nome, v_tel, v_ig, v_origem, v_etapa, v_motivo, v_oferta, v_resp, v_porta, nullif(v_utm, '{}'::jsonb), now(),
            'aplicação', 'aplicação',
            (select c.id from public.conversas c
              where c.telefone = v_tel and public.espaco_do_numero(c.numero_clinica_id) = 'instituto'
                and not exists (select 1 from public.instituto_leads l where l.conversa_id = c.id)
              order by c.ultima_mensagem_em desc nulls last limit 1));
  end if;

  return jsonb_build_object('ok', true, 'perfil', v_oferta);
end $$;
revoke all on function public.instituto_aplicar(jsonb) from public;
grant execute on function public.instituto_aplicar(jsonb) to anon, authenticated;

-- 3. card automático para conversa nova no WhatsApp do Instituto
create or replace function public.instituto_card_da_conversa() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_nome text := nullif(btrim(coalesce(new.nome_contato, new.nome_perfil, '')), ''); v_id bigint;
begin
  if coalesce(new.canal, 'whatsapp') = 'instagram' or new.telefone is null then return null; end if;
  -- já tem card ligado a esta conversa: só completa o nome
  select id into v_id from public.instituto_leads where conversa_id = new.id;
  if found then
    if v_nome is not null then update public.instituto_leads set nome = v_nome where id = v_id and nome is null; end if;
    return null;
  end if;
  -- tem card ativo com o mesmo telefone: liga a conversa nele
  select id into v_id from public.instituto_leads
   where telefone = new.telefone and conversa_id is null and etapa not in ('venda', 'perdido')
   order by atualizado_em desc limit 1;
  if found then
    update public.instituto_leads set conversa_id = new.id, nome = coalesce(nome, v_nome) where id = v_id;
    return null;
  end if;
  if tg_op = 'INSERT' then
    insert into public.instituto_leads (nome, telefone, etapa, conversa_id, criado_por, atualizado_por)
    values (v_nome, new.telefone, 'lead', new.id, 'WhatsApp', 'WhatsApp')
    on conflict do nothing;
  end if;
  return null;
exception when others then
  begin insert into public.espelho_erros (origem, erro, detalhe) values ('instituto_card_da_conversa', sqlerrm, new.id::text); exception when others then null; end;
  return null;
end $$;

drop trigger if exists instituto_card_da_conversa on public.conversas;
create trigger instituto_card_da_conversa
  after insert or update of nome_perfil, nome_contato on public.conversas
  for each row when (new.numero_clinica_id = '431996333326052')
  execute function public.instituto_card_da_conversa();

-- 4. cards das conversas do Instituto que já existem
insert into public.instituto_leads (nome, telefone, etapa, conversa_id, criado_por, atualizado_por)
select nullif(btrim(coalesce(c.nome_contato, c.nome_perfil, '')), ''), c.telefone, 'lead', c.id, 'WhatsApp', 'WhatsApp'
  from public.conversas c
 where c.numero_clinica_id = '431996333326052' and coalesce(c.canal, 'whatsapp') <> 'instagram' and c.telefone ~ '^\d{10,13}$'
   and c.oculta_em is null
   and not exists (select 1 from public.instituto_leads l where l.conversa_id = c.id or l.telefone = c.telefone)
on conflict do nothing;

-- Conferência
select etapa, count(*) as cards from public.instituto_leads group by etapa order by etapa;
