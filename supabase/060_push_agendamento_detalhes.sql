-- 060: notificação de agendamento com data, horário e quem agendou (31/10/2026)
-- O agendamento fica registrado em agente_registros (tipo 'agendamento'), pela IA (autor 'agente')
-- ou pela Central (autor = e-mail de quem agendou), com a data e o horário da avaliação.
-- Esse registro pode chegar alguns minutos depois da etapa "Agendou". Então o aviso nasce
-- "aguardando" e a rotina push_preparar (a cada minuto) completa o texto e libera o envio.
-- Se em 10 minutos não aparecer o registro (etapa trocada à mão), o aviso sai como antes.

alter table public.push_fila add column if not exists telefone text;
alter table public.push_fila drop constraint if exists push_fila_status_check;
alter table public.push_fila add constraint push_fila_status_check
  check (status in ('aguardando', 'pendente', 'enviando', 'enviado', 'ignorado', 'erro'));
create index if not exists push_fila_aguardando on public.push_fila (id) where status = 'aguardando';

create or replace function public.push_t_evento() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.tipo = 'CUSTOMER_STAGE_UPDATED' and lower(btrim(coalesce(new.etapa, ''))) = 'agendou'
     and new.ocorrido_em > now() - interval '1 day' then
    insert into public.push_fila (tipo, chave, titulo, corpo, pagina, status, telefone)
    values ('agendamento',
            'ag:' || new.telefone || ':' || to_char(new.ocorrido_em at time zone 'America/Sao_Paulo', 'YYYY-MM-DD'),
            'Nova avaliação agendada 📆',
            left(coalesce(nullif(btrim(new.nome), ''), 'Lead') || coalesce(' · ' || nullif(btrim(new.origem), ''), ''), 300),
            'leads', 'aguardando', new.telefone)
    on conflict (chave) do nothing;
  end if;
  return null;
exception when others then
  insert into public.espelho_erros (origem, erro, detalhe) values ('push_t_evento', sqlerrm, new.telefone);
  return null;
end $$;

-- completa os avisos de agendamento e libera para o motor enviar
create or replace function public.push_preparar() returns integer
language plpgsql security definer set search_path = public, pg_temp as $$
declare f record; r record; v_quem text; v_m text[]; v_dia date; v_linha text; n integer := 0;
  dias text[] := array['dom', 'seg', 'ter', 'qua', 'qui', 'sex', 'sáb'];
begin
  for f in select * from public.push_fila where status = 'aguardando' order by id limit 50 loop
    select ar.autor, ar.detalhe into r
      from public.agente_registros ar join public.conversas c on c.id = ar.conversa_id
     where c.telefone = f.telefone and ar.tipo = 'agendamento'
       and ar.criado_em > f.criado_em - interval '6 hours'
     order by ar.criado_em desc limit 1;
    if r.detalhe is null and f.criado_em > now() - interval '10 minutes' then
      continue; -- ainda esperando o registro
    end if;
    v_linha := null;
    if r.detalhe is not null then
      v_quem := case when r.autor = 'agente' then 'IA'
                     else coalesce((select case when e.nome = 'Raffaella' then 'Raffa' else e.nome end
                                      from public.equipe e where e.email = lower(r.autor)),
                                   split_part(r.autor, '@', 1)) end;
      v_m := regexp_match(r.detalhe, '(\d{4}-\d{2}-\d{2}) (\d{1,2}:\d{2})');
      if v_m is not null then
        v_dia := v_m[1]::date;
        v_linha := '📅 ' || dias[extract(dow from v_dia)::int + 1] || ', ' || to_char(v_dia, 'DD/MM') || ' às ' || v_m[2]
                   || case when r.detalhe ilike '%ONLINE%' then ' (online)' else '' end;
      end if;
      v_linha := coalesce(v_linha || ' · ', '') || 'por ' || v_quem;
      -- a etapa chegou antes do nome: usa o nome que foi para a agenda
      v_m := regexp_match(r.detalhe, '\(([^()]{3,80})\)\. Agendamento');
      if f.corpo ~ '^Lead( ·|$)' and v_m is not null then
        f.corpo := btrim(v_m[1]) || substr(f.corpo, 5);
      end if;
    end if;
    update public.push_fila
       set status = 'pendente',
           corpo = left(f.corpo || coalesce(E'\n' || v_linha, ''), 300),
           detalhe = case when r.detalhe is null then 'sem registro do agendamento' end
     where id = f.id and status = 'aguardando';
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.push_preparar() from public, anon, authenticated;

do $$ begin
  perform cron.unschedule('push-preparar');
exception when others then null; end $$;
select cron.schedule('push-preparar', '* * * * *', $cron$ select public.push_preparar(); $cron$);

select (select count(*) from public.push_fila where status = 'aguardando') as aguardando,
       (select string_agg(id || ':' || status, ', ') from public.push_fila where id in (875, 639)) as conferencia;
