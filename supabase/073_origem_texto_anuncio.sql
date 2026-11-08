-- ============================================================
-- 073 (08/11/2026): lead que clicou no anúncio mas chegou sem o dado da Meta
--   O dado do anúncio (referral) continua sendo a regra. Quando ele não vem e a primeira
--   mensagem é a mensagem pronta dos anúncios, o lead entra como #Instagram ADS (sem
--   anúncio ligado: aparece em "Sem rastreamento" no Tráfego).
--   Textos dos anúncios em configuracoes 'textos_anuncio' (lista). Mudou o texto do
--   anúncio? Atualize a lista.
--   Retroativo: leads #Organico criados pelo CRM cuja primeira mensagem é a do anúncio.
-- ============================================================

insert into public.configuracoes (chave, valor)
values ('textos_anuncio', '["Olá! Gostaria de agendar uma avaliação pra transformar meu sorriso com as lentes"]'::jsonb)
on conflict (chave) do nothing;

create or replace function public.texto_de_anuncio(p_texto text)
returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(btrim(p_texto), '') <> '' and exists (
    select 1 from public.configuracoes c, jsonb_array_elements_text(
             case when jsonb_typeof(c.valor) = 'array' then c.valor else '[]'::jsonb end) t(txt)
     where c.chave = 'textos_anuncio'
       and lower(regexp_replace(btrim(t.txt), '\s+', ' ', 'g')) = lower(regexp_replace(btrim(p_texto), '\s+', ' ', 'g')));
$$;

-- Troca só a linha da origem na versão que está no banco (a do banco tem ajustes que não estão no 028)
do $do$
declare
  d text;
  alvo constant text := $q$v_origem := case when new.origem_anuncio is not null and new.origem_anuncio->>'source_type' = 'ad' then '#Instagram ADS' else '#Organico' end;$q$;
  novo constant text := $q$v_origem := case when (new.origem_anuncio is not null and new.origem_anuncio->>'source_type' = 'ad') or public.texto_de_anuncio(new.texto) then '#Instagram ADS' else '#Organico' end; -- (08/11/2026) sem o dado da Meta, a mensagem pronta do anúncio indica clique em anúncio$q$;
begin
  d := pg_get_functiondef('public.funil_t_mensagem'::regproc);
  if position('texto_de_anuncio' in d) > 0 then raise notice 'já aplicado'; return; end if;
  if (length(d) - length(replace(d, alvo, ''))) / length(alvo) <> 1 then
    raise exception 'não achei a linha da origem em funil_t_mensagem (nada foi alterado)';
  end if;
  execute replace(d, alvo, novo);
end $do$;

-- Retroativo (só leads novos criados pelo CRM, ainda #Organico, sem anúncio, sem origem trocada à mão depois).
-- O gatilho de troca de origem fica desligado só durante esta correção (senão ele registraria uma
-- "troca de origem" hoje e o lead contaria de novo).
alter table public.pacientes disable trigger t_funil_etapa;
with prim as (
  select distinct on (m.conversa_id) m.conversa_id, m.texto
    from public.mensagens m
   where m.direcao = 'recebida'
   order by m.conversa_id, m.enviada_em
), alvo as (
  select e.id, e.telefone
    from public.eventos_proprios e
    join prim on prim.conversa_id = e.conversa_id
   where e.tipo = 'CUSTOMER_CREATED' and e.origem = '#Organico' and e.ad_id is null
     and public.texto_de_anuncio(prim.texto)
), ev as (
  update public.eventos_proprios e set origem = '#Instagram ADS'
    from alvo where e.id = alvo.id
  returning e.telefone
)
update public.pacientes p set origem = '#Instagram ADS'
  from (select distinct telefone from ev) x
 where p.telefone = x.telefone and p.origem = '#Organico';
alter table public.pacientes enable trigger t_funil_etapa;

select count(*) as leads_corrigidos
  from public.eventos_proprios e
  join (select distinct on (m.conversa_id) m.conversa_id, m.texto from public.mensagens m
         where m.direcao = 'recebida' order by m.conversa_id, m.enviada_em) prim on prim.conversa_id = e.conversa_id
 where e.tipo = 'CUSTOMER_CREATED' and e.origem = '#Instagram ADS' and e.ad_id is null and public.texto_de_anuncio(prim.texto);
