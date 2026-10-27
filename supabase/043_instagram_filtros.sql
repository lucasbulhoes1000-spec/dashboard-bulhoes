-- ============================================================
-- CRM Bulhões — Instagram: só quem respondeu, e lista de ignorados (27/10/2026)
--   • Conversa que só tem mensagem da equipe (abordagem da Lívia sem resposta)
--     fica guardada, mas não aparece na Central até a pessoa responder
--     (a tela esconde conversa do Instagram sem ultima_recebida_em).
--   • instagram_ignorados: pessoas que nunca devem entrar no CRM (amigas da
--     Dra. Larissa etc.). ig_ignorar() cadastra e apaga a conversa; daí em
--     diante as mensagens dessa pessoa nem são gravadas.
-- Rodar no Supabase: SQL Editor → New query → colar tudo → Run.
-- ============================================================
create table if not exists public.instagram_ignorados (
  ig_conta     text not null,
  igsid        text not null,
  nome         text,
  ignorado_por text,
  ignorado_em  timestamptz not null default now(),
  primary key (ig_conta, igsid)
);
alter table public.instagram_ignorados enable row level security;
revoke all on public.instagram_ignorados from anon, authenticated;
grant select on public.instagram_ignorados to authenticated;
drop policy if exists instagram_ignorados_ver on public.instagram_ignorados;
create policy instagram_ignorados_ver on public.instagram_ignorados for select to authenticated
  using (public.tem_papel('gestao', 'avaliacao', 'comercial'));

create or replace function public.ig_ignorar(p_conversa uuid)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare c public.conversas;
begin
  if not public.tem_papel('gestao', 'avaliacao', 'comercial') then raise exception 'sem permissão'; end if;
  select * into c from public.conversas where id = p_conversa and canal = 'instagram';
  if c.id is null then return jsonb_build_object('ok', false, 'erro', 'conversa do Instagram não encontrada'); end if;
  insert into public.instagram_ignorados (ig_conta, igsid, nome, ignorado_por)
  values (c.numero_clinica_id, c.wa_id, coalesce(c.nome_perfil, c.ig_usuario), public.email_atual())
  on conflict do nothing;
  delete from public.conversas where id = c.id;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.ig_ignorar(uuid) from public, anon;
grant execute on function public.ig_ignorar(uuid) to authenticated;

create or replace function public.ig_desfazer_ignorar(p_conta text, p_igsid text)
returns void
language sql security definer set search_path = public, pg_temp as $$
  delete from public.instagram_ignorados where ig_conta = p_conta and igsid = p_igsid
    and public.tem_papel('gestao', 'avaliacao', 'comercial');
$$;
revoke all on function public.ig_desfazer_ignorar(text, text) from public, anon;
grant execute on function public.ig_desfazer_ignorar(text, text) to authenticated;

-- ig_processar pula quem está na lista
do $$
declare d text;
begin
  d := pg_get_functiondef('public.ig_processar(jsonb)'::regprocedure);
  if position('instagram_ignorados' in d) = 0 then
    d := replace(d, '        if v_pessoa is null or v_pessoa = v_conta then continue; end if;',
                    '        if v_pessoa is null or v_pessoa = v_conta then continue; end if;' || chr(10) ||
                    '        if exists (select 1 from public.instagram_ignorados i where i.ig_conta = v_conta and i.igsid = v_pessoa) then continue; end if;');
    execute d;
  end if;
end $$;

select position('instagram_ignorados' in pg_get_functiondef('public.ig_processar(jsonb)'::regprocedure)) > 0 as ignorados_ligado;
