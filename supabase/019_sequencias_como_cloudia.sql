-- ============================================================
-- CRM Bulhões — Sequências como no Cloudia (22/10/2026)
--   • Vários gatilhos de entrada por sequência:
--       gatilho = {"lista":[{"tipo":"etapa","etapa":"Lead"},{"tipo":"tag_adicionada","tag_id":3}, …]}
--     (o formato antigo, um gatilho só, continua valendo)
--   • Gatilho novo: mudança de estado da conversa (atendimento / fila / concluido)
--   • Gatilho de saída configurável (regras.saida):
--       {"tipo":"nenhuma"} | {"tipo":"qualquer"} | {"tipo":"igual","valor":"sair"}
--       {"tipo":"contem","valor":"agendei"} | {"tipo":"tag","tag_id":3}
--     (sem regras.saida vale o antigo sair_se_responder)
--   • Pasta pública "automacoes-midia" para imagem, vídeo, áudio e arquivo dos passos.
-- Rodar no Supabase: SQL Editor → New query → colar tudo → Run.
-- ============================================================

-- um gatilho bate com o evento?
create or replace function public.automacao_gatilho_bate(g jsonb, p_tipo text, p_dados jsonb)
returns boolean
language sql immutable as $$
  select coalesce(g->>'tipo', '') = p_tipo and case p_tipo
    when 'etapa' then lower(coalesce(g->>'etapa', '')) = lower(coalesce(p_dados->>'etapa', ''))
    when 'tag_adicionada' then (g->>'tag_id') = (p_dados->>'tag_id')
    when 'tag_removida' then (g->>'tag_id') = (p_dados->>'tag_id')
    when 'lead_criado' then coalesce(g->>'origem', '') in ('', coalesce(p_dados->>'origem', ''))
    when 'estado' then coalesce(g->>'estado', '') in ('', coalesce(p_dados->>'estado', ''))
    when 'mensagem_recebida' then
      jsonb_array_length(coalesce(g->'palavras', '[]'::jsonb)) = 0
      or exists (select 1 from jsonb_array_elements_text(g->'palavras') w
                 where length(btrim(w)) > 0
                   and lower(coalesce(p_dados->>'texto', '')) like '%' || lower(btrim(w)) || '%')
    else false end;
$$;

create or replace function public.automacao_disparar(p_tipo text, p_telefone text, p_dados jsonb)
returns integer
language plpgsql security definer set search_path = public, pg_temp as $$
declare a record; n integer := 0;
begin
  for a in select * from public.automacoes where ligada loop
    if exists (select 1 from jsonb_array_elements(case when jsonb_typeof(a.gatilho->'lista') = 'array' then a.gatilho->'lista' else jsonb_build_array(a.gatilho) end) g
               where public.automacao_gatilho_bate(g, p_tipo, p_dados))
       and public.automacao_entrar(a.id, p_telefone, 'gatilho: ' || p_tipo, p_dados) is not null then
      n := n + 1;
    end if;
  end loop;
  return n;
exception when others then
  insert into public.espelho_erros (origem, erro, detalhe) values ('automacao_disparar', sqlerrm, p_tipo || ' ' || coalesce(p_telefone, ''));
  return 0;
end $$;
revoke all on function public.automacao_disparar(text, text, jsonb) from public, anon, authenticated;

-- regra de saída de uma sequência para uma mensagem recebida
create or replace function public.automacao_sai_por_mensagem(regras jsonb, p_texto text)
returns boolean
language sql immutable as $$
  select case coalesce(regras->'saida'->>'tipo', case when coalesce((regras->>'sair_se_responder')::boolean, true) then 'qualquer' else 'nenhuma' end)
    when 'qualquer' then true
    when 'igual' then lower(btrim(coalesce(p_texto, ''))) = lower(btrim(coalesce(regras->'saida'->>'valor', '')))
    when 'contem' then length(btrim(coalesce(regras->'saida'->>'valor', ''))) > 0
                       and lower(coalesce(p_texto, '')) like '%' || lower(btrim(regras->'saida'->>'valor')) || '%'
    else false end;
$$;

create or replace function public.automacao_t_mensagens() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_tel text; e record;
begin
  if new.direcao <> 'recebida' or coalesce(new.canal, 'crm') = 'historico' then return null; end if;
  select telefone into v_tel from public.conversas where id = new.conversa_id;
  if v_tel is null then return null; end if;
  for e in
    select x.id, x.automacao_id, x.passo from public.automacao_execucoes x join public.automacoes a on a.id = x.automacao_id
     where x.telefone = v_tel and x.status = 'ativa' and x.entrou_em < new.enviada_em
       and public.automacao_sai_por_mensagem(a.regras, new.texto)
  loop
    update public.automacao_execucoes set status = 'saiu', motivo = 'paciente respondeu', terminou_em = now() where id = e.id;
    insert into public.automacao_log (automacao_id, execucao_id, telefone, passo, acao, detalhe)
    values (e.automacao_id, e.id, v_tel, e.passo, 'saiu', 'paciente respondeu: ' || left(coalesce(new.texto, ''), 60));
  end loop;
  update public.automacao_execucoes set contexto = contexto || jsonb_build_object('respondeu_em', new.enviada_em)
   where telefone = v_tel and status = 'ativa';
  if public.automacoes_alguma_ligada() then
    perform public.automacao_disparar('mensagem_recebida', v_tel, jsonb_build_object('texto', new.texto));
  end if;
  return null;
exception when others then
  insert into public.espelho_erros (origem, erro, detalhe) values ('automacao_t_mensagens', sqlerrm, null);
  return null;
end $$;

-- tags: entrada e saída por tag
create or replace function public.automacao_t_tags() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_tel text; e record;
begin
  if tg_op = 'INSERT' then
    select telefone into v_tel from public.conversas where id = new.conversa_id;
    if v_tel is null then return null; end if;
    for e in
      select x.id, x.automacao_id, x.passo from public.automacao_execucoes x join public.automacoes a on a.id = x.automacao_id
       where x.telefone = v_tel and x.status = 'ativa'
         and a.regras->'saida'->>'tipo' = 'tag' and (a.regras->'saida'->>'tag_id') = new.tag_id::text
    loop
      update public.automacao_execucoes set status = 'saiu', motivo = 'recebeu a tag de saída', terminou_em = now() where id = e.id;
      insert into public.automacao_log (automacao_id, execucao_id, telefone, passo, acao, detalhe)
      values (e.automacao_id, e.id, v_tel, e.passo, 'saiu', 'recebeu a tag de saída');
    end loop;
    if public.automacoes_alguma_ligada() then
      perform public.automacao_disparar('tag_adicionada', v_tel, jsonb_build_object('tag_id', new.tag_id));
    end if;
  else
    select telefone into v_tel from public.conversas where id = old.conversa_id;
    if v_tel is not null and public.automacoes_alguma_ligada() then
      perform public.automacao_disparar('tag_removida', v_tel, jsonb_build_object('tag_id', old.tag_id));
    end if;
  end if;
  return null;
exception when others then
  insert into public.espelho_erros (origem, erro, detalhe) values ('automacao_t_tags', sqlerrm, null);
  return null;
end $$;

-- estado da conversa (atendimento / fila / concluido)
create or replace function public.automacao_estado(c public.conversas) returns text
language sql immutable as $$
  select case when c.status = 'encerrada' then 'concluido' when c.atribuida_a is not null then 'atendimento' else 'fila' end;
$$;
create or replace function public.automacao_t_conversas() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if public.automacoes_alguma_ligada() and public.automacao_estado(new) is distinct from public.automacao_estado(old) then
    perform public.automacao_disparar('estado', new.telefone, jsonb_build_object('estado', public.automacao_estado(new)));
  end if;
  return null;
exception when others then
  insert into public.espelho_erros (origem, erro, detalhe) values ('automacao_t_conversas', sqlerrm, null);
  return null;
end $$;
drop trigger if exists t_automacao_conversas on public.conversas;
create trigger t_automacao_conversas after update of status, atribuida_a on public.conversas
  for each row execute function public.automacao_t_conversas();

-- pasta pública para as mídias dos passos (o WhatsApp baixa pelo link)
insert into storage.buckets (id, name, public) values ('automacoes-midia', 'automacoes-midia', true)
on conflict (id) do update set public = true;
drop policy if exists automacoes_midia_subir on storage.objects;
create policy automacoes_midia_subir on storage.objects for insert to authenticated
  with check (bucket_id = 'automacoes-midia' and public.tem_papel('gestao', 'comercial'));
drop policy if exists automacoes_midia_ver on storage.objects;
create policy automacoes_midia_ver on storage.objects for select to authenticated
  using (bucket_id = 'automacoes-midia');

select 'sequências como no Cloudia prontas' as status;
