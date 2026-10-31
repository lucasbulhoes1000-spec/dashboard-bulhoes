-- 057: notificações no celular (31/10/2026)
-- O backoffice vira app pela tela inicial do celular e avisa:
--   • avaliação agendada: quando o funil registra a etapa "Agendou" (eventos_proprios, já sem repetição)
--   • venda fechada: quando um orçamento fica "Aprovado" (orcamentos), uma vez por orçamento
-- Quem recebe: a gestão, em cada aparelho onde ativar na tela "Notificações".
-- O envio é feito pelo motor das automações (whatsapp-automacoes), a cada minuto.

-- chaves do envio (criadas pelo motor na primeira vez; ninguém da equipe lê)
create table if not exists public.push_chaves (
  id        integer primary key check (id = 1),
  publica   text not null,
  privada   jsonb not null,
  criado_em timestamptz not null default now()
);
alter table public.push_chaves enable row level security;
revoke all on public.push_chaves from anon, authenticated;

-- a parte pública da chave, para o navegador se inscrever
create or replace function public.push_chave_publica() returns text
language sql stable security definer set search_path = public, pg_temp as $$
  select publica from public.push_chaves where id = 1;
$$;
revoke all on function public.push_chave_publica() from public, anon;
grant execute on function public.push_chave_publica() to authenticated;

-- aparelhos inscritos (um por navegador/celular)
create table if not exists public.push_inscricoes (
  id              bigint generated always as identity primary key,
  email           text not null default public.email_atual(),
  endpoint        text not null unique,
  p256dh          text not null,
  auth            text not null,
  aparelho        text,
  tipos           text[] not null default array['agendamento', 'venda'],
  ativo           boolean not null default true,
  criado_em       timestamptz not null default now(),
  ultimo_envio_em timestamptz,
  ultimo_erro     text
);
alter table public.push_inscricoes enable row level security;
revoke all on public.push_inscricoes from anon;
grant select, insert, delete on public.push_inscricoes to authenticated;
grant update (tipos, ativo, aparelho, p256dh, auth) on public.push_inscricoes to authenticated;
drop policy if exists push_insc_ver on public.push_inscricoes;
create policy push_insc_ver on public.push_inscricoes for select to authenticated using (email = public.email_atual());
drop policy if exists push_insc_criar on public.push_inscricoes;
create policy push_insc_criar on public.push_inscricoes for insert to authenticated
  with check (email = public.email_atual() and public.tem_papel('gestao'));
drop policy if exists push_insc_mudar on public.push_inscricoes;
create policy push_insc_mudar on public.push_inscricoes for update to authenticated
  using (email = public.email_atual()) with check (email = public.email_atual());
drop policy if exists push_insc_apagar on public.push_inscricoes;
create policy push_insc_apagar on public.push_inscricoes for delete to authenticated using (email = public.email_atual());

-- fila de avisos
create table if not exists public.push_fila (
  id         bigint generated always as identity primary key,
  tipo       text not null check (tipo in ('agendamento', 'venda', 'teste')),
  chave      text unique,
  titulo     text not null check (length(titulo) <= 120),
  corpo      text not null check (length(corpo) <= 300),
  pagina     text,
  para_email text,
  status     text not null default 'pendente' check (status in ('pendente', 'enviando', 'enviado', 'ignorado', 'erro')),
  criado_em  timestamptz not null default now(),
  enviado_em timestamptz,
  detalhe    text
);
create index if not exists push_fila_pendente on public.push_fila (id) where status = 'pendente';
alter table public.push_fila enable row level security;
revoke all on public.push_fila from anon;
grant select on public.push_fila to authenticated;
grant insert (tipo, titulo, corpo, pagina, para_email) on public.push_fila to authenticated;
drop policy if exists push_fila_ver on public.push_fila;
create policy push_fila_ver on public.push_fila for select to authenticated using (public.tem_papel('gestao'));
-- a equipe só cria o teste para o próprio aparelho
drop policy if exists push_fila_teste on public.push_fila;
create policy push_fila_teste on public.push_fila for insert to authenticated
  with check (tipo = 'teste' and para_email = public.email_atual() and public.tem_papel('gestao'));

-- avaliação agendada (o funil já tira repetição: mesma etapa em 30 dias ou passo para trás)
create or replace function public.push_t_evento() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.tipo = 'CUSTOMER_STAGE_UPDATED' and lower(btrim(coalesce(new.etapa, ''))) = 'agendou'
     and new.ocorrido_em > now() - interval '1 day' then
    insert into public.push_fila (tipo, chave, titulo, corpo, pagina)
    values ('agendamento',
            'ag:' || new.telefone || ':' || to_char(new.ocorrido_em at time zone 'America/Sao_Paulo', 'YYYY-MM-DD'),
            'Nova avaliação agendada 📆',
            left(coalesce(nullif(btrim(new.nome), ''), 'Lead') || coalesce(' · ' || nullif(btrim(new.origem), ''), ''), 300),
            'leads')
    on conflict (chave) do nothing;
  end if;
  return null;
exception when others then
  insert into public.espelho_erros (origem, erro, detalhe) values ('push_t_evento', sqlerrm, new.telefone);
  return null;
end $$;
drop trigger if exists t_push_evento on public.eventos_proprios;
create trigger t_push_evento after insert on public.eventos_proprios
  for each row execute function public.push_t_evento();

-- venda fechada: uma vez por orçamento (a tabela é regravada pela sincronização, por isso a chave)
create or replace function public.push_chave_orcamento(o public.orcamentos) returns text
language sql immutable as $$
  select 'venda:' || coalesce(nullif(btrim(o.clinicorp_id), ''),
    o.paciente_id::text || ':' || coalesce(o.fechamento_data::text, o.data::text, '') || ':' || coalesce(o.valor::text, ''));
$$;

create or replace function public.push_t_orcamento() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_nome text; v_valor numeric; v_recente boolean;
begin
  if new.status is distinct from 'Aprovado' then return null; end if;
  select nome into v_nome from public.pacientes where id = new.paciente_id;
  v_valor := coalesce(nullif(new.fechamento_valor, 0), new.valor, 0);
  v_recente := coalesce(new.fechamento_data, new.data, current_date) >= (now() at time zone 'America/Sao_Paulo')::date - 3;
  insert into public.push_fila (tipo, chave, titulo, corpo, pagina, status, detalhe)
  values ('venda', public.push_chave_orcamento(new),
          'Venda fechada 🎉 R$ ' || replace(to_char(v_valor, 'FM999G999G990'), ',', '.'),
          left(coalesce(nullif(btrim(v_nome), ''), 'Paciente') || coalesce(' · ' || nullif(btrim(new.tratamento), ''), ''), 300),
          'clientes',
          case when v_recente then 'pendente' else 'ignorado' end,
          case when v_recente then null else 'fechamento antigo' end)
  on conflict (chave) do nothing;
  return null;
exception when others then
  insert into public.espelho_erros (origem, erro, detalhe) values ('push_t_orcamento', sqlerrm, new.id::text);
  return null;
end $$;
drop trigger if exists t_push_orcamento on public.orcamentos;
create trigger t_push_orcamento after insert or update of status on public.orcamentos
  for each row execute function public.push_t_orcamento();

-- o que já está aprovado hoje não vira aviso
insert into public.push_fila (tipo, chave, titulo, corpo, status, detalhe)
select 'venda', public.push_chave_orcamento(o), 'Venda (já existente)', '-', 'ignorado', 'já aprovado antes das notificações'
from public.orcamentos o where o.status = 'Aprovado'
on conflict (chave) do nothing;

select (select count(*) from public.push_fila) as fila, public.push_chave_publica() is not null as chave_pronta;
