-- ============================================================
-- 074 (08/11/2026): cliques dos links da bio/stories gravados no Lume (substitui a planilha)
--   • cliques_links: um registro por clique nas páginas de link (Dra. Larissa e clínica).
--   • registrar_clique(p): as páginas públicas gravam o clique (só insere; não lê nada).
--   • A mensagem pronta do WhatsApp leva um código invisível (30 caracteres U+2062/U+2063
--     entre marcadores U+2060). Quando a mensagem chega, o gatilho liga o clique ao contato.
--   • Sem o código (pessoa reescreveu a mensagem), liga pelo horário: o clique mais recente
--     do mesmo perfil, até 20 min antes da mensagem, marcado como "horario".
-- ============================================================

create table if not exists public.cliques_links (
  id            bigserial primary key,
  click_id      text unique,
  codigo        text unique,
  clicado_em    timestamptz not null default now(),
  perfil        text,          -- larissa | clinica
  destino       text,          -- whatsapp_clinica, whatsapp_avaliacao, whatsapp_instituto, site_bulhoes...
  utm_source    text, utm_medium text, utm_campaign text, utm_content text, utm_term text,
  pagina        text, landing_page text, referrer text, fbclid text, gclid text,
  telefone      text,
  conversa_id   uuid,
  mensagem_id   uuid,
  ligado_em     timestamptz,
  ligado_por    text,          -- codigo | horario
  importado     boolean not null default false,
  criado_em     timestamptz not null default now()
);
create index if not exists cliques_links_tel on public.cliques_links (telefone);
create index if not exists cliques_links_quando on public.cliques_links (clicado_em);
alter table public.cliques_links enable row level security;
revoke all on public.cliques_links from anon, authenticated;
grant select on public.cliques_links to authenticated;
drop policy if exists cliques_links_equipe on public.cliques_links;
create policy cliques_links_equipe on public.cliques_links for select to authenticated using (public.is_equipe_crm());

-- perfil a partir do registro da página
create or replace function public.clique_perfil(p_click text, p_origem text, p_pagina text)
returns text language sql immutable as $$
  select case
    when coalesce(p_click,'') ilike 'LARI-%' or coalesce(p_origem,'') ilike '%larissa%' or coalesce(p_pagina,'') ilike '%dralarissabulhoes%' then 'larissa'
    when coalesce(p_click,'') ilike 'BULHOES-%' or coalesce(p_pagina,'') ilike '%bulhoes-odontologia%' then 'clinica'
    when coalesce(p_click,'') ilike 'SITE-%' or coalesce(p_pagina,'') ilike '%bulhoesodontologia.com.br%' then 'site'
  end;
$$;

create or replace function public.registrar_clique(p jsonb)
returns text
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_cod text := upper(nullif(btrim(p->>'codigo'), ''));
begin
  if v_cod is not null and v_cod !~ '^[A-Z2-7]{6}$' then return 'codigo invalido'; end if;
  -- trava simples contra abuso
  if (select count(*) from public.cliques_links where criado_em > now() - interval '1 minute') > 300 then return 'limite'; end if;
  insert into public.cliques_links (click_id, codigo, clicado_em, perfil, destino, utm_source, utm_medium, utm_campaign,
         utm_content, utm_term, pagina, landing_page, referrer, fbclid, gclid)
  values (left(nullif(p->>'click_id',''),60), v_cod, now(),
          public.clique_perfil(p->>'click_id', p->>'origem_link', p->>'pagina'),
          left(p->>'destino',40), left(p->>'utm_source',80), left(p->>'utm_medium',80), left(p->>'utm_campaign',120),
          left(p->>'utm_content',120), left(p->>'utm_term',120), left(p->>'pagina',500), left(p->>'landing_page',500),
          left(coalesce(p->>'first_referrer', p->>'referrer'),300), left(p->>'fbclid',300), left(p->>'gclid',300))
  on conflict do nothing;
  return 'ok';
end $$;
revoke all on function public.registrar_clique(jsonb) from public;
grant execute on function public.registrar_clique(jsonb) to anon, authenticated;

-- código invisível → texto de 6 letras (base32)
create or replace function public.link_codigo(t text)
returns text language plpgsql immutable as $$
declare m text; b text; r text := ''; i int; v int;
begin
  m := substring(coalesce(t,'') from '[' || chr(8290) || chr(8291) || ']{30}');
  if m is null then return null; end if;
  b := translate(m, chr(8290) || chr(8291), '01');
  for i in 0..5 loop
    v := (substr(b, i*5+1, 1))::int*16 + (substr(b, i*5+2, 1))::int*8 + (substr(b, i*5+3, 1))::int*4
       + (substr(b, i*5+4, 1))::int*2 + (substr(b, i*5+5, 1))::int;
    r := r || substr('ABCDEFGHIJKLMNOPQRSTUVWXYZ234567', v + 1, 1);
  end loop;
  return r;
end $$;

-- perfil pela mensagem pronta (para ligar pelo horário quando o código não vier)
create or replace function public.link_perfil_texto(t text)
returns text language sql immutable as $$
  select case
    when coalesce(t,'') ilike '%vim pelo instagram da dra. larissa%' then 'larissa'
    when coalesce(t,'') ilike 'olá! gostaria de agendar uma avaliação na bulhões odontologia%' then 'larissa'
    when coalesce(t,'') ilike '%vim pelo instagram da bulhões%' then 'clinica'
  end;
$$;

create or replace function public.cliques_t_mensagem()
returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare c public.conversas; v_cod text; v_perfil text; v_id bigint;
begin
  if new.direcao <> 'recebida' then return null; end if;
  v_cod := public.link_codigo(new.texto);
  v_perfil := case when v_cod is null then public.link_perfil_texto(new.texto) end;
  if v_cod is null and v_perfil is null then return null; end if;
  select * into c from public.conversas where id = new.conversa_id;
  if c.id is null then return null; end if;
  if v_cod is not null then
    update public.cliques_links set telefone = c.telefone, conversa_id = c.id, mensagem_id = new.id,
           ligado_em = new.enviada_em, ligado_por = 'codigo'
     where codigo = v_cod and telefone is null;
  else
    -- só a primeira mensagem do contato com o texto do perfil
    if exists (select 1 from public.cliques_links where conversa_id = c.id) then return null; end if;
    select id into v_id from public.cliques_links
     where telefone is null and perfil = v_perfil and destino in ('whatsapp_clinica','whatsapp_avaliacao')
       and clicado_em between new.enviada_em - interval '20 minutes' and new.enviada_em + interval '2 minutes'
     order by clicado_em desc limit 1;
    if v_id is not null then
      update public.cliques_links set telefone = c.telefone, conversa_id = c.id, mensagem_id = new.id,
             ligado_em = new.enviada_em, ligado_por = 'horario'
       where id = v_id;
    end if;
  end if;
  return null;
exception when others then
  insert into public.espelho_erros (origem, erro, detalhe) values ('cliques_t_mensagem', sqlerrm, new.conversa_id::text);
  return null;
end $$;
drop trigger if exists t_cliques_mensagem on public.mensagens;
create trigger t_cliques_mensagem after insert on public.mensagens
  for each row execute function public.cliques_t_mensagem();

-- liga o histórico (cliques importados da planilha) pelas primeiras mensagens, em ordem
create or replace function public.cliques_ligar_historico()
returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare m record; v_id bigint; n int := 0;
begin
  for m in
    select distinct on (x.conversa_id) x.id, x.conversa_id, x.texto, x.enviada_em, c.telefone
      from public.mensagens x join public.conversas c on c.id = x.conversa_id
     where x.direcao = 'recebida' and x.enviada_em >= '2026-08-25'
     order by x.conversa_id, x.enviada_em
  loop
    continue when public.link_perfil_texto(m.texto) is null;
    continue when exists (select 1 from public.cliques_links where conversa_id = m.conversa_id);
    select id into v_id from public.cliques_links
     where telefone is null and perfil = public.link_perfil_texto(m.texto) and destino in ('whatsapp_clinica','whatsapp_avaliacao')
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

select public.link_codigo('x' || chr(8288) || repeat(chr(8291),5) || chr(8290)||chr(8291)||chr(8290)||chr(8291)||chr(8290) || chr(8291)||chr(8291)||chr(8290)||chr(8291)||chr(8290) || chr(8291)||chr(8290)||chr(8290)||chr(8290)||chr(8290) || chr(8291)||chr(8290)||chr(8291)||chr(8291)||chr(8291) || repeat(chr(8290),5) || chr(8288)) as teste_7K2QXA;

-- Histórico: os cliques da planilha "Rastreamento LP" (25/08 a 08/11/2026) foram importados em 08/11
-- (importado = true) e ligados aos leads pelo horário com public.cliques_ligar_historico().
