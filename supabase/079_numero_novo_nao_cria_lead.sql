-- =====================================================================
-- 079 (13/11/2026): só o número comercial cria lead (pedido do Lucas)
--   Número conectado depois (recepção, comercial 2...) entra SEM criar lead
--   e SEM ligar o robô do comercial, até alguém mudar de propósito.
-- =====================================================================
alter table public.whatsapp_numeros alter column cria_leads set default false;

select apelido, numero_exibicao, cria_leads from public.whatsapp_numeros order by conectado_em;
