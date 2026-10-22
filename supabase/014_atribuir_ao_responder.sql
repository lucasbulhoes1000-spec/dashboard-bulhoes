-- ============================================================
-- CRM Bulhões — Atribuição automática ao responder (22/10/2026)
-- Como no Cloudia: quem manda a primeira resposta numa conversa sem
-- atendente passa a ser o responsável. Se já tem alguém, nada muda.
-- Rodar no Supabase: SQL Editor → New query → colar tudo → Run.
-- ============================================================
create or replace function public.wa_registrar_enviada(
  p_conversa uuid, p_wa_message_id text, p_tipo text, p_texto text, p_autor text,
  p_status text, p_erro text, p_bruto jsonb)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid;
begin
  insert into public.mensagens (conversa_id, wa_message_id, direcao, tipo, texto, status, erro, autor_email, canal, bruto)
  values (p_conversa, p_wa_message_id, 'enviada', p_tipo, p_texto, p_status, p_erro, p_autor, 'crm', p_bruto)
  returning id into v_id;
  if p_status <> 'falhou' then
    update public.conversas set ultima_mensagem_em = now(), ultima_mensagem_texto = p_texto,
           nao_lidas = 0, status = 'aguardando',
           atribuida_a = coalesce(atribuida_a,
             (select e.email from public.equipe e where e.email = p_autor and e.ativo))
     where id = p_conversa;
  end if;
  return v_id;
end $$;
revoke all on function public.wa_registrar_enviada(uuid, text, text, text, text, text, text, jsonb) from public, anon, authenticated;
grant execute on function public.wa_registrar_enviada(uuid, text, text, text, text, text, text, jsonb) to service_role;

select 'atribuição automática ao responder ligada' as status;
