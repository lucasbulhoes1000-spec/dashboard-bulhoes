-- ============================================================
-- CRM Bulhões — Conversas parecidas com o Cloudia (22/10/2026)
--
-- 1. Tags (etiquetas) por conversa, com cor, como no Cloudia.
-- 2. Respostas rápidas (textos prontos que a equipe chama com "/").
-- 3. Envio de foto, vídeo, áudio e documento pelo CRM: a equipe sobe o
--    arquivo na pasta privada "whatsapp-midia/envios/…".
-- 4. conversas.robo_ligado: liga/desliga a IA por conversa (usado na etapa da IA).
--
-- Rodar no Supabase: SQL Editor → New query → colar tudo → Run.
-- Pode rodar mais de uma vez sem problema.
-- ============================================================

-- ------------------------------------------------------------
-- Tags
-- ------------------------------------------------------------
create table if not exists public.wa_tags (
  id         bigint generated always as identity primary key,
  nome       text not null unique check (length(btrim(nome)) between 1 and 40),
  cor        text not null default '#CCBCA6' check (cor ~ '^#[0-9A-Fa-f]{6}$'),
  criada_em  timestamptz not null default now(),
  criada_por text default public.email_atual()
);

create table if not exists public.conversa_tags (
  conversa_id    uuid not null references public.conversas(id) on delete cascade,
  tag_id         bigint not null references public.wa_tags(id) on delete cascade,
  adicionada_em  timestamptz not null default now(),
  adicionada_por text default public.email_atual(),
  primary key (conversa_id, tag_id)
);
create index if not exists conversa_tags_tag on public.conversa_tags (tag_id);

alter table public.wa_tags enable row level security;
alter table public.conversa_tags enable row level security;
revoke all on public.wa_tags, public.conversa_tags from anon;
grant select, insert on public.wa_tags to authenticated;
grant update (nome, cor), delete on public.wa_tags to authenticated;
grant select, insert, delete on public.conversa_tags to authenticated;

drop policy if exists wa_tags_ver on public.wa_tags;
create policy wa_tags_ver on public.wa_tags for select to authenticated
  using (public.tem_papel('gestao', 'avaliacao', 'comercial'));
drop policy if exists wa_tags_criar on public.wa_tags;
create policy wa_tags_criar on public.wa_tags for insert to authenticated
  with check (public.tem_papel('gestao', 'avaliacao', 'comercial'));
drop policy if exists wa_tags_editar on public.wa_tags;
create policy wa_tags_editar on public.wa_tags for update to authenticated
  using (public.tem_papel('gestao')) with check (public.tem_papel('gestao'));
drop policy if exists wa_tags_apagar on public.wa_tags;
create policy wa_tags_apagar on public.wa_tags for delete to authenticated
  using (public.tem_papel('gestao'));

drop policy if exists conversa_tags_ver on public.conversa_tags;
create policy conversa_tags_ver on public.conversa_tags for select to authenticated
  using (public.tem_papel('gestao', 'avaliacao', 'comercial'));
drop policy if exists conversa_tags_por on public.conversa_tags;
create policy conversa_tags_por on public.conversa_tags for insert to authenticated
  with check (public.tem_papel('gestao', 'avaliacao', 'comercial'));
drop policy if exists conversa_tags_tirar on public.conversa_tags;
create policy conversa_tags_tirar on public.conversa_tags for delete to authenticated
  using (public.tem_papel('gestao', 'avaliacao', 'comercial'));

-- tags que a clínica já usa no Cloudia (as de follow-up viram automação na etapa 2)
insert into public.wa_tags (nome, cor, criada_por) values
  ('lentes em resina',   '#A18B6C', 'cloudia'),
  ('lentes em porcelana','#8C6E4F', 'cloudia'),
  ('clínico',            '#7FA7C9', 'cloudia'),
  ('clareamento',        '#E9C46A', 'cloudia'),
  ('implantes',          '#6C9A8B', 'cloudia'),
  ('ortodontia',         '#B48EAD', 'cloudia'),
  ('HOF',                '#D4A5A5', 'cloudia'),
  ('retrabalho',         '#C97B63', 'cloudia'),
  ('confirmou lembrete', '#5A8A6A', 'cloudia'),
  ('cancelar consulta',  '#FFB6C1', 'cloudia')
on conflict (nome) do nothing;

do $$ begin
  alter publication supabase_realtime add table public.conversa_tags;
exception when duplicate_object then null; when undefined_object then null; end $$;

-- ------------------------------------------------------------
-- Respostas rápidas
-- ------------------------------------------------------------
create table if not exists public.respostas_rapidas (
  id          bigint generated always as identity primary key,
  atalho      text not null unique check (atalho ~ '^[a-z0-9_-]{2,30}$'),
  texto       text not null check (length(texto) between 1 and 4096),
  criada_em   timestamptz not null default now(),
  criada_por  text default public.email_atual(),
  atualizada_em timestamptz not null default now()
);
alter table public.respostas_rapidas enable row level security;
revoke all on public.respostas_rapidas from anon;
grant select, insert, update (atalho, texto, atualizada_em), delete on public.respostas_rapidas to authenticated;
drop policy if exists respostas_ver on public.respostas_rapidas;
create policy respostas_ver on public.respostas_rapidas for select to authenticated
  using (public.tem_papel('gestao', 'avaliacao', 'comercial'));
drop policy if exists respostas_criar on public.respostas_rapidas;
create policy respostas_criar on public.respostas_rapidas for insert to authenticated
  with check (public.tem_papel('gestao', 'avaliacao', 'comercial'));
drop policy if exists respostas_editar on public.respostas_rapidas;
create policy respostas_editar on public.respostas_rapidas for update to authenticated
  using (public.tem_papel('gestao', 'avaliacao', 'comercial')) with check (public.tem_papel('gestao', 'avaliacao', 'comercial'));
drop policy if exists respostas_apagar on public.respostas_rapidas;
create policy respostas_apagar on public.respostas_rapidas for delete to authenticated
  using (public.tem_papel('gestao', 'avaliacao', 'comercial'));

-- ------------------------------------------------------------
-- Robô por conversa (para a etapa da IA)
-- ------------------------------------------------------------
alter table public.conversas add column if not exists robo_ligado boolean not null default false;
grant update (atribuida_a, status, nao_lidas, robo_ligado) on public.conversas to authenticated;

-- ------------------------------------------------------------
-- Envio de arquivos: a equipe sobe em whatsapp-midia/envios/<conversa>/<arquivo>
-- ------------------------------------------------------------
drop policy if exists whatsapp_midia_enviar on storage.objects;
create policy whatsapp_midia_enviar on storage.objects for insert to authenticated
  with check (bucket_id = 'whatsapp-midia' and name like 'envios/%'
              and public.tem_papel('gestao', 'avaliacao', 'comercial'));

-- mensagem enviada pelo CRM com mídia (chamado só pela função whatsapp-acoes)
create or replace function public.wa_registrar_enviada_midia(
  p_conversa uuid, p_wa_message_id text, p_tipo text, p_texto text, p_autor text,
  p_status text, p_erro text, p_bruto jsonb, p_caminho text, p_mime text, p_nome text)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid;
begin
  v_id := public.wa_registrar_enviada(p_conversa, p_wa_message_id, p_tipo, p_texto, p_autor, p_status, p_erro, p_bruto);
  update public.mensagens set midia_caminho = p_caminho, midia_tipo = p_mime, midia_nome = p_nome where id = v_id;
  return v_id;
end $$;
revoke all on function public.wa_registrar_enviada_midia(uuid, text, text, text, text, text, text, jsonb, text, text, text) from public, anon, authenticated;
grant execute on function public.wa_registrar_enviada_midia(uuid, text, text, text, text, text, text, jsonb, text, text, text) to service_role;

-- ------------------------------------------------------------
-- Lista de atendentes (nome e e-mail) para o "Atribuído a"
-- ------------------------------------------------------------
create or replace function public.equipe_atendentes()
returns table (email text, nome text)
language sql stable security definer set search_path = public, pg_temp as $$
  select e.email, e.nome from public.equipe e
  where e.ativo and public.tem_papel('gestao', 'avaliacao', 'comercial')
  order by e.nome;
$$;
revoke all on function public.equipe_atendentes() from public, anon;
grant execute on function public.equipe_atendentes() to authenticated;

select 'conversas: tags, respostas rápidas e envio de arquivos prontos' as status,
       (select count(*) from public.wa_tags) as tags;
