-- ============================================================
-- 082 (14/11/2026): lembretes da recepção
--   Os lembretes passam a ter "programa":
--     • avaliacao  = o que já existia (número comercial, só avaliações), configuração 'lembretes_consulta'
--     • recepcao   = todos os agendamentos do Clinicorp MENOS avaliação, pelo número da recepção,
--                    configuração 'lembretes_recepcao' (9h e 15h da véspera; sábado manda os de segunda)
--   Nada muda no que já roda para as avaliações.
--   A recepção entra LIGADA em MODO TESTE sem telefone de teste: não envia nada até a gestão liberar.
-- ============================================================

-- 1) coluna programa nos lembretes e nas rodadas
alter table public.lembretes_consulta add column if not exists programa text not null default 'avaliacao';
alter table public.lembretes_rodadas  add column if not exists programa text not null default 'avaliacao';

do $$
declare r record;
begin
  -- único antigo (data, tipo, telefone) vira (programa, data, tipo, telefone)
  for r in select conname from pg_constraint
            where conrelid = 'public.lembretes_consulta'::regclass and contype = 'u' loop
    execute format('alter table public.lembretes_consulta drop constraint %I', r.conname);
  end loop;
  -- chave das rodadas (dia, tipo) vira (programa, dia, tipo)
  for r in select conname from pg_constraint
            where conrelid = 'public.lembretes_rodadas'::regclass and contype = 'p' loop
    execute format('alter table public.lembretes_rodadas drop constraint %I', r.conname);
  end loop;
end $$;
alter table public.lembretes_consulta add constraint lembretes_consulta_prog_data_tipo_tel_key unique (programa, data, tipo, telefone);
alter table public.lembretes_rodadas  add constraint lembretes_rodadas_pkey primary key (programa, dia, tipo);

-- 2) funções do motor com o programa (sem informar = avaliacao, como antes)
drop function if exists public.lembrete_reservar(date, text, text, text, text, text);
create or replace function public.lembrete_reservar(p_data date, p_tipo text, p_tel text, p_nome text, p_hora text, p_cid text, p_programa text default 'avaliacao')
returns jsonb
language plpgsql security definer set search_path = public, migracao, pg_temp as $$
declare v_tel text := migracao.tel(p_tel); v_id bigint;
begin
  if v_tel is null or v_tel !~ '^[0-9]{10,11}$' then return null; end if;
  insert into public.lembretes_consulta (programa, data, tipo, telefone, nome, hora, clinicorp_id)
  values (coalesce(p_programa, 'avaliacao'), p_data, p_tipo, v_tel, nullif(btrim(p_nome), ''), p_hora, p_cid)
  on conflict (programa, data, tipo, telefone) do nothing
  returning id into v_id;
  if v_id is null then return null; end if;
  return jsonb_build_object('id', v_id, 'telefone', v_tel);
end $$;

drop function if exists public.lembrete_rodada(date, text, text, integer, integer, integer, text);
create or replace function public.lembrete_rodada(p_dia date, p_tipo text, p_status text, p_consultas integer, p_enviados integer, p_falhas integer, p_erro text, p_programa text default 'avaliacao')
returns void
language sql security definer set search_path = public, pg_temp as $$
  insert into public.lembretes_rodadas (programa, dia, tipo, status, consultas, enviados, falhas, erro, atualizada_em)
  values (coalesce(p_programa, 'avaliacao'), p_dia, p_tipo, p_status, coalesce(p_consultas, 0), coalesce(p_enviados, 0), coalesce(p_falhas, 0), p_erro, now())
  on conflict (programa, dia, tipo) do update set status = excluded.status,
    consultas = excluded.consultas, enviados = lembretes_rodadas.enviados + excluded.enviados,
    falhas = lembretes_rodadas.falhas + excluded.falhas, erro = excluded.erro, atualizada_em = now();
$$;

-- respostas: o motor precisa saber de qual programa é (textos e tags de cada um)
drop function if exists public.lembrete_respostas_pegar();
create or replace function public.lembrete_respostas_pegar()
returns table (id bigint, conversa_id uuid, acao text, lembrete_id bigint, clinicorp_id text, telefone text, data date, hora text, programa text)
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  update public.lembrete_respostas set status = 'pendente' where status = 'processando' and criado_em < now() - interval '10 minutes';
  return query
  with x as (
    update public.lembrete_respostas r set status = 'processando'
     where r.id in (select y.id from public.lembrete_respostas y where y.status = 'pendente' order by y.id limit 20 for update skip locked)
    returning r.*)
  select x.id, x.conversa_id, x.acao, x.lembrete_id, l.clinicorp_id, l.telefone, l.data, l.hora, l.programa
    from x join public.lembretes_consulta l on l.id = x.lembrete_id;
end $$;

-- resposta do paciente: prefere o lembrete que saiu NESSA conversa (recepção x comercial)
create or replace function public.lembrete_t_resposta() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare c public.conversas; l public.lembretes_consulta; v_acao text;
begin
  if new.direcao <> 'recebida' or coalesce(new.canal, 'paciente') <> 'paciente' or new.enviada_em < now() - interval '1 day' then return null; end if;
  v_acao := public.lembrete_classificar(new.tipo, new.texto);
  if v_acao is null then return null; end if;
  select * into c from public.conversas where id = new.conversa_id;
  if c.id is null then return null; end if;
  select * into l from public.lembretes_consulta x
   where x.telefone = c.telefone and x.status = 'enviado'
     and x.enviado_em > now() - interval '3 days'
     and x.data >= (now() at time zone 'America/Sao_Paulo')::date
   order by (x.conversa_id = c.id) desc nulls last, x.enviado_em desc limit 1;
  if l.id is null then return null; end if;
  if v_acao = 'confirmar' and l.resposta = 'confirmou' then return null; end if;   -- já confirmou
  insert into public.lembrete_respostas (mensagem_id, conversa_id, lembrete_id, acao)
  values (new.id, c.id, l.id, v_acao) on conflict (mensagem_id) do nothing;
  delete from public.agente_fila where conversa_id = c.id;
  if v_acao = 'cancelar' then
    update public.conversas set robo_ligado = false where id = c.id and robo_ligado;
  end if;
  return null;
exception when others then
  insert into public.espelho_erros (origem, erro, detalhe) values ('lembrete_t_resposta', sqlerrm, new.conversa_id::text);
  return null;
end $$;

revoke all on function public.lembrete_reservar(date, text, text, text, text, text, text) from public, anon, authenticated;
revoke all on function public.lembrete_rodada(date, text, text, integer, integer, integer, text, text) from public, anon, authenticated;
revoke all on function public.lembrete_respostas_pegar() from public, anon, authenticated;
revoke all on function public.lembrete_t_resposta() from public, anon, authenticated;
grant execute on function public.lembrete_reservar(date, text, text, text, text, text, text) to service_role;
grant execute on function public.lembrete_rodada(date, text, text, integer, integer, integer, text, text) to service_role;
grant execute on function public.lembrete_respostas_pegar() to service_role;

-- 3) configuração da recepção
insert into public.configuracoes (chave, valor)
select 'lembretes_recepcao', jsonb_build_object(
  'ligado', true,
  'modo_teste', true,
  'telefones_teste', '[]'::jsonb,
  'numero_clinica_id', (select phone_number_id from public.whatsapp_numeros where apelido = 'Recepção' and ativo limit 1),
  'categorias', '[]'::jsonb,                 -- vazio = todas as categorias...
  'categorias_excluir', '["avaliação"]'::jsonb, -- ...menos avaliação
  'confirmar_no_clinicorp', true,
  'resposta_confirmou', 'Perfeito, sua presença está confirmada. Até breve! 🤎',
  'resposta_cancelar', 'Tudo bem! Vou pedir para a nossa equipe te ajudar a encontrar um novo horário.',
  'tag_confirmou', 'confirmou lembrete',
  'tag_cancelar', 'cancelar consulta',
  'vespera', jsonb_build_object('hora', '09:00', 'janela_min', 240,
     'modelo', jsonb_build_object('nome', 'lembrete_vespera_recepcao', 'idioma', 'pt_BR',
        'variaveis', '["{primeiro_nome}", "{quando}, {data}", "{hora}"]'::jsonb,
        'texto_preview', 'Oi, {primeiro_nome}! Passando para lembrar da sua consulta {quando}, {data}, às {hora}, aqui na Bulhões Odontologia 🤎 Podemos confirmar sua presença?')),
  'vespera2', jsonb_build_object('hora', '15:00', 'janela_min', 180, 'no_sabado', true,
     'modelo', jsonb_build_object('nome', 'lembrete_vespera2_recepcao', 'idioma', 'pt_BR',
        'variaveis', '["{primeiro_nome}", "{quando}", "{hora}"]'::jsonb,
        'texto_preview', 'Oi, {primeiro_nome}! Estamos organizando a agenda de {quando} e seu horário das {hora} está reservado para você 🤎 Consegue confirmar para a gente?'))
)
where not exists (select 1 from public.configuracoes where chave = 'lembretes_recepcao');

select (select count(*) from public.lembretes_consulta where programa = 'avaliacao') as lembretes_avaliacao,
       (select valor->>'numero_clinica_id' from public.configuracoes where chave = 'lembretes_recepcao') as numero_recepcao;
