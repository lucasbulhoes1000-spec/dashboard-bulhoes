-- ============================================================
-- CRM Bulhões — importação do histórico da Cloudia, passo 3 de 3
-- 21/10/2026
-- Converte as linhas recebidas da planilha em eventos do funil, ligados a
-- cada paciente. Leads que só existem na Cloudia viram pacientes novos.
-- • Não altera o CRM atual nem a planilha.
-- • Pode rodar de novo: substitui os eventos vindos da planilha.
-- • Os dados ficam como a Cloudia mandou; as regras de origem que o
--   Dashboard aplica na tela (ex.: anúncio → #Instagram ADS) serão
--   aplicadas nas consultas prontas, não aqui.
-- Rodar no Supabase: SQL Editor → New query → colar tudo → Run.
-- ============================================================
do $$ begin
  if exists (select 1 from public.configuracoes where chave = 'virada_concluida') then
    raise exception 'A virada já foi feita. Esta importação não pode mais ser rodada.';
  end if;
  if not exists (select 1 from public.importacao_cloudia) then
    raise exception 'Nada recebido da planilha. Rode antes a função EXPORTAR_PLANILHA_CLOUDIA_PARA_SUPABASE no Apps Script.';
  end if;
end $$;

-- ad_id pode ter virado notação científica na planilha (1.2E+17)
create or replace function migracao.ad_id(t text) returns text
language plpgsql immutable as $$
declare s text := btrim(coalesce(t, ''));
begin
  if s = '' then return null; end if;
  if s ~* '^\d+(\.\d+)?e\+?\d+$' then return to_char(s::numeric, 'FM999999999999999999999999'); end if;
  s := substring(s from '(\d{6,})');   -- "Whatsapp:120247238399920437" → só os dígitos
  return s;
exception when others then return null;
end $$;

drop table if exists _ev;
create temp table _ev as
select i.*,
       migracao.tel(i.phone) as tel,
       coalesce(migracao.ts(i."timestamp"), migracao.ts(i.created_at)) as quando
from public.importacao_cloudia i;

-- Substitui os eventos da importação anterior
delete from public.eventos_funil where fonte = 'cloudia_planilha';

-- Pacientes que só existem na Cloudia
drop table if exists _novos;
create temp table _novos as
select tel,
       (array_remove(array_agg(nullif(btrim(name), '') order by quando desc nulls last), null))[1]   as nome,
       (array_remove(array_agg(nullif(btrim(origin), '') order by quando desc nulls last), null))[1] as origem,
       (array_remove(array_agg(nullif(btrim(stage), '') order by quando desc nulls last), null))[1]  as etapa,
       min(coalesce(migracao.ts(created_at), quando)) as criado_em
from _ev
where tel ~ '^[0-9]{10,13}$'
  and not exists (select 1 from public.pacientes p where p.telefone = _ev.tel)
group by tel;

insert into public.pacientes (telefone, nome, origem, etapa, criado_em, legado)
select tel, nome, origem, etapa, coalesce(criado_em, now()), jsonb_build_object('fonte', 'cloudia_planilha')
from _novos;

-- Eventos
insert into public.eventos_funil
  (paciente_id, telefone, tipo, etapa, origem, ad_id, ad_name, adset_name, campaign_name,
   cloudia_customer_id, valor, ocorrido_em, fonte, bruto)
select p.id, e.tel, btrim(e.type), nullif(btrim(e.stage), ''), nullif(btrim(e.origin), ''),
       migracao.ad_id(e.ad_id), nullif(btrim(e.ad_name), ''), nullif(btrim(e.adset_name), ''),
       nullif(btrim(e.campaign_name), ''), nullif(btrim(e.customer_id), ''),
       migracao.num(e.value), e.quando, 'cloudia_planilha',
       to_jsonb(e) - 'tel' - 'quando' - 'recebido_em'
from _ev e
join public.pacientes p on p.telefone = e.tel
where e.tel ~ '^[0-9]{10,13}$' and e.quando is not null and coalesce(btrim(e.type), '') <> ''
-- linhas repetidas: fica a mais completa (com anúncio, origem, valor), depois a mais recente
order by (nullif(btrim(e.ad_id), '') is not null) desc, (nullif(btrim(e.ad_name), '') is not null) desc,
         (nullif(btrim(e.origin), '') is not null) desc, (nullif(btrim(e.value), '') is not null) desc, e.linha desc
on conflict do nothing;

-- Conferência
select item, valor from (values
  (1, 'Linhas recebidas da planilha', (select count(*) from _ev)::text),
  (2, 'Eventos importados', (select count(*) from public.eventos_funil where fonte = 'cloudia_planilha')::text),
  (3, 'Ignoradas: telefone inválido', (select count(*) from _ev where tel is null or tel !~ '^[0-9]{10,13}$')::text),
  (4, 'Ignoradas: sem data legível', (select count(*) from _ev where tel ~ '^[0-9]{10,13}$' and quando is null)::text),
  (5, 'Ignoradas: sem tipo de evento', (select count(*) from _ev where tel ~ '^[0-9]{10,13}$' and quando is not null and coalesce(btrim(type), '') = '')::text),
  (6, 'Repetidas (mesmo telefone, tipo, etapa e horário)',
      ((select count(*) from _ev where tel ~ '^[0-9]{10,13}$' and quando is not null and coalesce(btrim(type), '') <> '')
       - (select count(*) from public.eventos_funil where fonte = 'cloudia_planilha'))::text),
  (7, 'Pacientes novos nesta execução (só existiam na Cloudia)', (select count(*) from _novos)::text),
  (8, 'Pacientes no total', (select count(*) from public.pacientes)::text),
  (9, 'Período dos eventos',
      (select to_char(min(ocorrido_em) at time zone 'America/Sao_Paulo', 'DD/MM/YYYY') || ' a ' ||
              to_char(max(ocorrido_em) at time zone 'America/Sao_Paulo', 'DD/MM/YYYY')
       from public.eventos_funil where fonte = 'cloudia_planilha')),
  (10, 'Eventos por tipo',
      (select string_agg(tipo || ': ' || n, ' · ' order by n desc) from
         (select tipo, count(*) n from public.eventos_funil where fonte = 'cloudia_planilha' group by tipo) z))
) t(ordem, item, valor)
order by ordem;
