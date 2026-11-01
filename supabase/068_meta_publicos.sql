-- 068 (01/11/2026) Público e posicionamento do Meta, para o especialista sugerir testes de público
-- meta_estrutura.publico: segmentação do conjunto (idade, gênero, locais, interesses, públicos, Advantage+)
-- meta_quebras_dia: números por conjunto, por dia, quebrados por idade+gênero e por posicionamento
alter table public.meta_estrutura add column if not exists publico jsonb;

create table if not exists public.meta_quebras_dia (
  dia            date not null,
  adset_id       text not null,
  quebra         text not null,   -- idade_genero | posicionamento
  chave          text not null,   -- ex.: "25-34|female" ou "instagram|reels"
  gasto          numeric not null default 0,
  impressoes     integer not null default 0,
  cliques        integer,
  conversas      integer,
  visitas_perfil integer,
  atualizado_em  timestamptz not null default now(),
  primary key (dia, adset_id, quebra, chave)
);
create index if not exists meta_quebras_dia_dia on public.meta_quebras_dia (dia);
alter table public.meta_quebras_dia enable row level security;
revoke all on public.meta_quebras_dia from anon;
grant select on public.meta_quebras_dia to authenticated;
drop policy if exists meta_quebras_dia_ver on public.meta_quebras_dia;
create policy meta_quebras_dia_ver on public.meta_quebras_dia for select to authenticated using (public.tem_papel('gestao', 'avaliacao', 'comercial'));
select 'meta_publicos pronto' as status;
