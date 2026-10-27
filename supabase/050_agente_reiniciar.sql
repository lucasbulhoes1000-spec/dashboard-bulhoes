-- CRM Bulhões — "Reiniciar conversa" para o Agente de IA (27/10/2026)
-- conversas.ia_desde: o agente só lê as mensagens a partir desse momento.
alter table public.conversas add column if not exists ia_desde timestamptz;
update public.conversas set ia_desde = now() where telefone like '%13996075557' and canal = 'whatsapp';
-- teste só no número do Lucas: responde em 5 s (voltar para 25 antes de ligar para todos)
update public.agente_ia set espera_segundos = 5 where id = 1 and modo_teste;
select (select count(*) from public.conversas where ia_desde is not null) as reiniciadas,
       (select espera_segundos from public.agente_ia where id = 1) as espera,
       (select modo_teste from public.agente_ia where id = 1) as modo_teste;
