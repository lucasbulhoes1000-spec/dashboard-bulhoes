-- ============================================================
-- CRM Bulhões — Resposta de quem já está na base não vira lead novo (27/10/2026)
-- O disparo do Grupo VIP saiu pelo Cloudia (fora do CRM). Quem respondeu já
-- estava cadastrado em pacientes, mas não tinha conversa no CRM, então o funil
-- registrou "lead criado" de novo. Agora:
--   1. quem já está em pacientes nunca gera "lead criado" (clique em anúncio
--      continua registrando a troca de origem, como antes);
--   2. os "lead criado" de hoje (desde 12h) de quem já estava cadastrado saem
--      do funil, com cópia em backup.eventos_disparo_vip_20261027.
-- Rodar no Supabase: SQL Editor → New query → colar tudo → Run.
-- ============================================================
do $$
declare d text;
begin
  d := pg_get_functiondef('public.funil_t_mensagem()'::regprocedure);
  if position('já está na base' in d) = 0 then
    if position('  if not v_conhecido and to_regclass' in d) = 0 then raise exception 'trecho não encontrado'; end if;
    d := replace(d, '  if not v_conhecido and to_regclass',
      '  -- já está na base (cadastro antigo, Clinicorp, planilha): não é lead novo
  v_conhecido := v_conhecido or exists (select 1 from public.pacientes p where p.telefone = c.telefone);
  if not v_conhecido and to_regclass');
    execute d;
  end if;
end $$;

create schema if not exists backup;
create table if not exists backup.eventos_disparo_vip_20261027 as
  select e.* from public.eventos_proprios e where false;

with alvo as (
  select e.* from public.eventos_proprios e
    join public.pacientes p on p.telefone = e.telefone
   where e.tipo = 'CUSTOMER_CREATED' and e.fonte = 'whatsapp'
     and e.ocorrido_em >= '2026-10-27 15:00:00+00'
     and p.criado_em < '2026-10-27 15:00:00+00'
), copia as (
  insert into backup.eventos_disparo_vip_20261027 select * from alvo returning id
)
delete from public.eventos_proprios e using copia where e.id = copia.id;

select (select count(*) from backup.eventos_disparo_vip_20261027) as tirados_do_funil,
       (select count(*) from public.eventos_proprios where tipo = 'CUSTOMER_CREATED' and ocorrido_em >= '2026-10-27 15:00:00+00') as leads_novos_de_hoje_que_ficaram,
       position('já está na base' in pg_get_functiondef('public.funil_t_mensagem()'::regprocedure)) > 0 as regra_nova_ativa;
