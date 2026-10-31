-- 059: histórico das análises de IA (31/10/2026)
-- Primeiro uso: especialista de tráfego pago na tela Tráfego Pago do Lume.
-- Quem grava é a função whatsapp-agente (ação analise_trafego); a gestão lê o histórico.
create table if not exists public.analises_ia (
  id             bigint generated always as identity primary key,
  tipo           text not null default 'trafego',
  periodo_de     date,
  periodo_ate    date,
  filtro         text,
  texto          text not null,
  modelo         text,
  tokens_entrada integer,
  tokens_saida   integer,
  criado_por     text,
  criado_em      timestamptz not null default now()
);
create index if not exists analises_ia_tipo on public.analises_ia (tipo, criado_em desc);
alter table public.analises_ia enable row level security;
revoke all on public.analises_ia from anon;
grant select on public.analises_ia to authenticated;
drop policy if exists analises_ia_ver on public.analises_ia;
create policy analises_ia_ver on public.analises_ia for select to authenticated using (public.tem_papel('gestao'));
select 'analises_ia pronta' as status;
