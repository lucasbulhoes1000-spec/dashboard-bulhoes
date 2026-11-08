-- ============================================================
-- 075 (08/11/2026): ligar pelo horário também quem chegou sem o texto pronto
--   Sem código e sem texto do perfil, a primeira mensagem de um contato novo é ligada ao
--   clique (qualquer perfil) mais próximo até 20 min antes dela, que ainda não foi usado.
--   Com o texto do perfil, só cliques daquele perfil. Sempre marcado como 'horario'.
--   Histórico da época do Lume (desde 22/10) ligado pela mesma regra; o da época do
--   Cloudia foi ligado pelo navegador (horário do Cloudia corrigido em -3 h).
-- ============================================================
create or replace function public.cliques_t_mensagem()
returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare c public.conversas; v_cod text; v_perfil text; v_id bigint;
begin
  if new.direcao <> 'recebida' then return null; end if;
  v_cod := public.link_codigo(new.texto);
  select * into c from public.conversas where id = new.conversa_id;
  if c.id is null then return null; end if;
  if v_cod is not null then
    update public.cliques_links set telefone = c.telefone, conversa_id = c.id, mensagem_id = new.id,
           ligado_em = new.enviada_em, ligado_por = 'codigo'
     where codigo = v_cod and telefone is null;
    return null;
  end if;
  -- sem código: só a primeira mensagem do contato, e só se ele ainda não tem clique ligado
  if exists (select 1 from public.cliques_links where conversa_id = c.id or telefone = c.telefone) then return null; end if;
  if exists (select 1 from public.mensagens m where m.conversa_id = c.id and m.direcao = 'recebida' and m.id <> new.id
               and m.enviada_em < new.enviada_em) then return null; end if;
  v_perfil := public.link_perfil_texto(new.texto);
  select id into v_id from public.cliques_links
   where telefone is null and destino in ('whatsapp_clinica','whatsapp_avaliacao','whatsapp')
     and (v_perfil is null or perfil = v_perfil)
     and clicado_em between new.enviada_em - interval '20 minutes' and new.enviada_em + interval '2 minutes'
   order by clicado_em desc limit 1;
  if v_id is not null then
    update public.cliques_links set telefone = c.telefone, conversa_id = c.id, mensagem_id = new.id,
           ligado_em = new.enviada_em, ligado_por = 'horario'
     where id = v_id;
  end if;
  return null;
exception when others then
  insert into public.espelho_erros (origem, erro, detalhe) values ('cliques_t_mensagem', sqlerrm, new.conversa_id::text);
  return null;
end $$;

-- histórico da época do Lume: primeira mensagem recebida de cada conversa, em ordem de chegada
create or replace function public.cliques_ligar_historico()
returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare m record; v_id bigint; v_perfil text; n int := 0;
begin
  for m in
    select * from (
      select distinct on (x.conversa_id) x.id, x.conversa_id, x.texto, x.enviada_em, c.telefone
        from public.mensagens x join public.conversas c on c.id = x.conversa_id
       where x.direcao = 'recebida' and x.enviada_em >= '2026-08-25' and coalesce(c.canal, 'whatsapp') <> 'instagram'
       order by x.conversa_id, x.enviada_em) p
    order by p.enviada_em
  loop
    continue when exists (select 1 from public.cliques_links where conversa_id = m.conversa_id or telefone = m.telefone);
    continue when public.link_codigo(m.texto) is not null;
    v_perfil := public.link_perfil_texto(m.texto);
    select id into v_id from public.cliques_links
     where telefone is null and destino in ('whatsapp_clinica','whatsapp_avaliacao','whatsapp')
       and (v_perfil is null or perfil = v_perfil)
       and clicado_em between m.enviada_em - interval '20 minutes' and m.enviada_em + interval '2 minutes'
     order by clicado_em desc limit 1;
    if v_id is not null then
      update public.cliques_links set telefone = m.telefone, conversa_id = m.conversa_id, mensagem_id = m.id,
             ligado_em = m.enviada_em, ligado_por = 'horario' where id = v_id;
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;
revoke all on function public.cliques_ligar_historico() from public, anon, authenticated;

-- ligação feita pelo navegador para a época do Cloudia (lista id do clique + telefone), só gestão
create or replace function public.cliques_ligar_lista(p jsonb)
returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare n int;
begin
  if not public.tem_papel('gestao') then raise exception 'sem permissão'; end if;
  update public.cliques_links c set telefone = x->>'tel', ligado_em = (x->>'em')::timestamptz, ligado_por = 'horario'
    from jsonb_array_elements(p) x
   where c.id = (x->>'id')::bigint and c.telefone is null
     and not exists (select 1 from public.cliques_links c2 where c2.telefone = x->>'tel');
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.cliques_ligar_lista(jsonb) from public, anon;
grant execute on function public.cliques_ligar_lista(jsonb) to authenticated;

select public.cliques_ligar_historico() as ligados_epoca_lume;

-- Rodado em 08/11/2026: 56 ligados pela época do Lume; 128 da época do Cloudia ligados pelo navegador
-- (cliques_ligar_lista, horário do Cloudia corrigido em -3 h; 131 de 165 orgânicos batiam com um clique nesse ajuste).
