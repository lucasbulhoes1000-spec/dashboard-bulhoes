-- 209 (Instituto, 17/11/2026): Base antiga de leads
--   Os contatos antigos do WhatsApp do Instituto ficam na coluna "Base antiga de leads" (etapa base_antiga).
--   Quando uma dessas pessoas manda mensagem de novo para o (13) 4042-7082, o card vai sozinho para
--   "Lead sem aplicação" (etapa lead) e a Lume avisa na tela.
--   Só olha mensagens recebidas no número do Instituto. Nada da clínica muda.

create or replace function public.instituto_base_antiga_volta() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_conv record; v_tel text; v_id bigint;
begin
  if new.direcao is distinct from 'recebida' or new.conversa_id is null then return null; end if;
  select id, telefone, numero_clinica_id into v_conv from public.conversas where id = new.conversa_id;
  if not found or v_conv.numero_clinica_id is distinct from '431996333326052' then return null; end if;
  v_tel := regexp_replace(coalesce(v_conv.telefone, ''), '\D', '', 'g');
  if v_tel like '55%' and length(v_tel) >= 12 then v_tel := substr(v_tel, 3); end if;
  -- mesmo card pela conversa ou pelo telefone (DDD + últimos 8 dígitos, para o nono dígito não atrapalhar)
  select id into v_id from public.instituto_leads
   where etapa = 'base_antiga'
     and (conversa_id = new.conversa_id
          or (length(v_tel) >= 10 and left(telefone, 2) = left(v_tel, 2) and right(telefone, 8) = right(v_tel, 8)))
   order by atualizado_em desc nulls last limit 1;
  if found then
    update public.instituto_leads
       set etapa = 'lead', conversa_id = coalesce(conversa_id, new.conversa_id), atualizado_por = 'WhatsApp'
     where id = v_id;
  end if;
  return null;
exception when others then
  begin insert into public.espelho_erros (origem, erro, detalhe) values ('instituto_base_antiga_volta', sqlerrm, new.id::text); exception when others then null; end;
  return null;
end $$;

drop trigger if exists instituto_base_antiga_volta on public.mensagens;
create trigger instituto_base_antiga_volta
  after insert on public.mensagens
  for each row when (new.direcao = 'recebida')
  execute function public.instituto_base_antiga_volta();

select count(*) filter (where etapa = 'base_antiga') as na_base_antiga, count(*) as cards from public.instituto_leads;
