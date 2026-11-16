-- ============================================================
-- 201 (16/11/2026) INSTITUTO: respostas rápidas, tags, mensagens
--   agendadas e arquivos separados por espaço (pedido do Lucas).
--
--   1. respostas_rapidas.espaco e wa_tags.espaco (padrão 'clinica': tudo
--      o que existe hoje continua da clínica). Cada espaço só vê as suas.
--   2. conversa_tags e mensagens_agendadas: só da conversa do seu espaço.
--   3. Arquivos das conversas (pasta whatsapp-midia): só da conversa do
--      seu espaço. As outras pastas do Storage não mudam.
--
--   Tudo com políticas RESTRICTIVE: as que já existem não mudam.
--   Os nomes de tag e os atalhos continuam únicos na Lume inteira (as
--   automações da clínica acham a tag pelo nome), então o Instituto usa
--   nomes e atalhos diferentes dos da clínica.
-- Não mexe em: webhook, edge functions, Ale, IA, automações.
-- Pode rodar mais de uma vez sem problema.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Respostas rápidas e tags
-- ------------------------------------------------------------
alter table public.respostas_rapidas add column if not exists espaco text not null default 'clinica';
alter table public.wa_tags add column if not exists espaco text not null default 'clinica';
do $$ begin
  alter table public.respostas_rapidas add constraint respostas_rapidas_espaco_ck check (espaco in ('clinica', 'instituto'));
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.wa_tags add constraint wa_tags_espaco_ck check (espaco in ('clinica', 'instituto'));
exception when duplicate_object then null; end $$;

drop policy if exists espaco_respostas_rapidas on public.respostas_rapidas;
create policy espaco_respostas_rapidas on public.respostas_rapidas as restrictive for all to authenticated
  using (espaco = any ((select public.meus_espacos())::text[]))
  with check (espaco = any ((select public.meus_espacos())::text[]));

drop policy if exists espaco_wa_tags on public.wa_tags;
create policy espaco_wa_tags on public.wa_tags as restrictive for all to authenticated
  using (espaco = any ((select public.meus_espacos())::text[]))
  with check (espaco = any ((select public.meus_espacos())::text[]));

-- ------------------------------------------------------------
-- 2. Tags das conversas e mensagens agendadas
-- ------------------------------------------------------------
drop policy if exists espaco_conversa_tags on public.conversa_tags;
create policy espaco_conversa_tags on public.conversa_tags as restrictive for all to authenticated
  using (conversa_id <> all ((select public.conversas_fora_do_meu_espaco())::uuid[]))
  with check (conversa_id <> all ((select public.conversas_fora_do_meu_espaco())::uuid[]));

drop policy if exists espaco_mensagens_agendadas on public.mensagens_agendadas;
create policy espaco_mensagens_agendadas on public.mensagens_agendadas as restrictive for all to authenticated
  using (conversa_id <> all ((select public.conversas_fora_do_meu_espaco())::uuid[]))
  with check (conversa_id <> all ((select public.conversas_fora_do_meu_espaco())::uuid[]));

-- ------------------------------------------------------------
-- 3. Arquivos das conversas
--    Caminhos: <conversa>/<mensagem>.<ext> (recebidos) e envios/<conversa>/<arquivo> (enviados)
-- ------------------------------------------------------------
drop policy if exists espaco_whatsapp_midia on storage.objects;
create policy espaco_whatsapp_midia on storage.objects as restrictive for all to authenticated
  using (bucket_id <> 'whatsapp-midia'
         or coalesce(case when (storage.foldername(name))[1] = 'envios' then (storage.foldername(name))[2]
                          else (storage.foldername(name))[1] end, '')
            <> all ((select public.conversas_fora_do_meu_espaco())::text[]))
  with check (bucket_id <> 'whatsapp-midia'
         or coalesce(case when (storage.foldername(name))[1] = 'envios' then (storage.foldername(name))[2]
                          else (storage.foldername(name))[1] end, '')
            <> all ((select public.conversas_fora_do_meu_espaco())::text[]));

-- ------------------------------------------------------------
-- Conferência
-- ------------------------------------------------------------
select 'política' as o_que, schemaname || '.' || tablename || '.' || policyname as item, permissive as valor
  from pg_policies where policyname like 'espaco_%'
union all
select 'respostas rápidas', espaco, count(*)::text from public.respostas_rapidas group by espaco
union all
select 'tags', espaco, count(*)::text from public.wa_tags group by espaco
order by 1, 2;
