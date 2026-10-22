-- ============================================================
-- CRM Bulhões — Agendador do motor das automações (22/10/2026)
-- A cada minuto o banco chama a função whatsapp-automacoes com a chave
-- do motor. Enquanto a chave geral 'automacoes_ligadas' estiver false,
-- a função responde "desligado" e não faz nada.
--
-- Rodar DEPOIS de publicar a função whatsapp-automacoes (com Verify JWT
-- desligado: quem protege é a chave do motor).
-- Rodar no Supabase: SQL Editor → New query → colar tudo → Run.
-- Parar o agendador: select cron.unschedule('automacoes-motor');
-- ============================================================
create extension if not exists pg_cron;
create extension if not exists pg_net;

do $$ begin
  perform cron.unschedule('automacoes-motor');
exception when others then null; end $$;

select cron.schedule(
  'automacoes-motor',
  '* * * * *',
  $cron$
  select net.http_post(
    url := 'https://gcxuikfjyajlmqbqlyca.supabase.co/functions/v1/whatsapp-automacoes',
    headers := jsonb_build_object('Content-Type', 'application/json',
                                  'x-motor-chave', (select chave from public.automacao_segredo where id = 1)),
    body := '{}'::jsonb,
    timeout_milliseconds := 60000
  );
  $cron$
);

-- limpa o histórico do agendador (fica só 3 dias)
do $$ begin
  perform cron.unschedule('automacoes-limpeza');
exception when others then null; end $$;
select cron.schedule('automacoes-limpeza', '17 4 * * *',
  $cron$ delete from cron.job_run_details where end_time < now() - interval '3 days';
         delete from net._http_response where created < now() - interval '3 days'; $cron$);

select jobname, schedule, active from cron.job where jobname like 'automacoes-%';
