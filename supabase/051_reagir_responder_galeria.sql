-- ============================================================
-- CRM Bulhões — Central: responder, reagir e galeria de mídias (27/10/2026)
--   • reação recebida do paciente aponta para a mensagem reagida (responde_a)
--   • galeria_midias: banco de fotos, vídeos e arquivos da equipe, guardados
--     em whatsapp-midia/galeria/… (sobe uma vez, manda quantas vezes quiser)
-- Rodar no Supabase: SQL Editor → New query → colar tudo → Run.
-- ============================================================
create or replace function public.wa_t_reacao() returns trigger
language plpgsql as $$
begin
  if new.tipo = 'reaction' and new.responde_a is null then
    new.responde_a := new.bruto->'reaction'->>'message_id';
  end if;
  return new;
end $$;
drop trigger if exists wa_t_reacao on public.mensagens;
create trigger wa_t_reacao before insert on public.mensagens for each row execute function public.wa_t_reacao();
update public.mensagens set responde_a = bruto->'reaction'->>'message_id'
 where tipo = 'reaction' and responde_a is null and bruto->'reaction'->>'message_id' is not null;

create table if not exists public.galeria_midias (
  id          bigserial primary key,
  nome        text not null,
  tipo        text not null check (tipo in ('image', 'video', 'audio', 'document')),
  mime        text,
  caminho     text not null unique,          -- whatsapp-midia/galeria/...
  tamanho     bigint,
  criado_por  text,
  criado_em   timestamptz not null default now()
);
alter table public.galeria_midias enable row level security;
revoke all on public.galeria_midias from anon, authenticated;
grant select, insert, delete on public.galeria_midias to authenticated;
grant usage, select on sequence public.galeria_midias_id_seq to authenticated;
drop policy if exists galeria_ver on public.galeria_midias;
create policy galeria_ver on public.galeria_midias for select to authenticated
  using (public.tem_papel('gestao', 'avaliacao', 'comercial'));
drop policy if exists galeria_incluir on public.galeria_midias;
create policy galeria_incluir on public.galeria_midias for insert to authenticated
  with check (public.tem_papel('gestao', 'avaliacao', 'comercial') and caminho like 'galeria/%');
drop policy if exists galeria_tirar on public.galeria_midias;
create policy galeria_tirar on public.galeria_midias for delete to authenticated
  using (public.tem_papel('gestao', 'comercial'));

-- arquivos da galeria no Storage (pasta privada)
drop policy if exists whatsapp_midia_galeria_subir on storage.objects;
create policy whatsapp_midia_galeria_subir on storage.objects for insert to authenticated
  with check (bucket_id = 'whatsapp-midia' and name like 'galeria/%' and public.tem_papel('gestao', 'avaliacao', 'comercial'));
drop policy if exists whatsapp_midia_galeria_tirar on storage.objects;
create policy whatsapp_midia_galeria_tirar on storage.objects for delete to authenticated
  using (bucket_id = 'whatsapp-midia' and name like 'galeria/%' and public.tem_papel('gestao', 'comercial'));

select (select count(*) from public.mensagens where tipo = 'reaction' and responde_a is not null) as reacoes_ligadas,
       to_regclass('public.galeria_midias') is not null as galeria_ok;
