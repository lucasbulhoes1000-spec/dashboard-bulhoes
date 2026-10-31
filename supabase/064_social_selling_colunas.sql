-- 064: colunas do Kanban de Social Selling editáveis (31/10/2026)
-- As colunas ficam em configuracoes.ss_colunas: [{k, nome, cor, tipo}], na ordem do quadro.
--   tipo: normal (em andamento) | perdido (não tem interesse) | fora (fica guardado, fora das contas)
--         | resultado (agendou, compareceu, venda)
-- A gestão renomeia, muda cor, reordena, cria e apaga coluna (só vazia). Entrada, Não tem interesse,
-- Agendou, Compareceu e Venda têm regra automática: podem mudar de nome e lugar, não podem sumir.

alter table public.social_selling drop constraint if exists social_selling_etapa_ck;
alter table public.social_selling add constraint social_selling_etapa_ck check (etapa ~ '^[a-z0-9_]{1,40}$');

insert into public.configuracoes (chave, valor) values ('ss_colunas', $j$[
  {"k":"entrada","nome":"Leads de entrada","cor":"#8C98B1","tipo":"normal"},
  {"k":"conversa","nome":"Conversa em andamento","cor":"#6FA8FF","tipo":"normal"},
  {"k":"material_1","nome":"Envio de material 1","cor":"#B79CFF","tipo":"normal"},
  {"k":"material_2","nome":"Envio de material 2","cor":"#B79CFF","tipo":"normal"},
  {"k":"sem_interesse","nome":"Não tem interesse","cor":"#E08A7E","tipo":"perdido"},
  {"k":"amigo_lari","nome":"Amigo Lari","cor":"#66738F","tipo":"fora"},
  {"k":"dentista","nome":"Dentista","cor":"#66738F","tipo":"fora"},
  {"k":"faltou_horario","nome":"Faltou horário","cor":"#E2BE6A","tipo":"normal"},
  {"k":"agendou","nome":"Agendou","cor":"#D4AF5A","tipo":"resultado"},
  {"k":"compareceu","nome":"Compareceu","cor":"#7FD3A0","tipo":"resultado"},
  {"k":"venda","nome":"Venda","cor":"#7FD3A0","tipo":"resultado"}
]$j$::jsonb) on conflict (chave) do nothing;

create or replace function public.ss_tipo(p text) returns text
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(
    (select e->>'tipo' from public.configuracoes c, jsonb_array_elements(c.valor) e
      where c.chave = 'ss_colunas' and jsonb_typeof(c.valor) = 'array' and e->>'k' = p limit 1),
    case when p in ('agendou', 'compareceu', 'venda') then 'resultado' when p = 'sem_interesse' then 'perdido'
         when p in ('amigo_lari', 'dentista') then 'fora' else 'normal' end);
$$;
grant execute on function public.ss_tipo(text) to authenticated;

create or replace function public.social_selling_tocar()
returns trigger language plpgsql as $$
declare v_tipo text;
begin
  new.atualizado_em := now();
  new.atualizado_por := coalesce(public.email_atual(), new.atualizado_por);
  new.instagram := lower(btrim(new.instagram));
  new.telefone := nullif(regexp_replace(coalesce(new.telefone, ''), '\D', '', 'g'), '');
  if tg_op = 'UPDATE' and new.etapa is not distinct from old.etapa and new.status is distinct from old.status then
    -- mudou só o status (tela de abordagens): leva a etapa junto
    v_tipo := public.ss_tipo(new.etapa);
    new.etapa := case new.status
      when 'agendou' then case when new.etapa in ('compareceu', 'venda') then new.etapa else 'agendou' end
      when 'desqualificado' then case when v_tipo in ('perdido', 'fora') then new.etapa else 'sem_interesse' end
      else case when new.etapa is not null and v_tipo <> 'normal' then 'conversa' else new.etapa end end;
  end if;
  if new.etapa is not null then
    v_tipo := public.ss_tipo(new.etapa);
    new.respondeu := true;
    new.status := case when new.etapa in ('agendou', 'compareceu', 'venda') then 'agendou'
                       when v_tipo in ('perdido', 'fora') then 'desqualificado' else 'em_andamento' end;
    if tg_op = 'INSERT' or new.etapa is distinct from old.etapa then new.etapa_em := now(); end if;
  end if;
  if new.respondeu and new.respondeu_em is null then new.respondeu_em := (now() at time zone 'America/Sao_Paulo')::date; end if;
  if not new.respondeu then new.respondeu_em := null; end if;
  return new;
end $$;

-- resultados do Clinicorp: não mexe em quem está numa coluna "fora das contas"
create or replace function public.ss_resultados() returns integer
language plpgsql security definer set search_path = public, pg_temp as $$
declare l record; v_comp boolean; v_qtd integer; v_valor numeric; n integer := 0;
begin
  for l in select s.* from public.social_selling s
            where s.telefone is not null and length(s.telefone) >= 10
              and coalesce(s.etapa, '') <> 'venda' and public.ss_tipo(coalesce(s.etapa, '')) <> 'fora' loop
    select count(*), sum(coalesce(nullif(o.fechamento_valor, 0), o.valor, 0)) into v_qtd, v_valor
      from public.orcamentos o join public.pacientes p on p.id = o.paciente_id
     where right(p.telefone, 8) = right(l.telefone, 8) and o.status = 'Aprovado'
       and coalesce(o.fechamento_data, o.data) >= l.abordado_em;
    if v_qtd > 0 then
      update public.social_selling set etapa = 'venda', venda_valor = v_valor where id = l.id;
      n := n + 1; continue;
    end if;
    if l.etapa = 'agendou' or (l.etapa is not null and public.ss_tipo(l.etapa) = 'normal' and l.agendado_para is not null) then
      select exists (select 1 from public.pacientes p where right(p.telefone, 8) = right(l.telefone, 8)
                       and lower(coalesce(p.etapa, '')) in ('compareceu', 'ganho'))
          or exists (select 1 from public.orcamentos o join public.pacientes p on p.id = o.paciente_id
                      where right(p.telefone, 8) = right(l.telefone, 8) and coalesce(o.data, o.fechamento_data) >= l.abordado_em)
        into v_comp;
      if v_comp then update public.social_selling set etapa = 'compareceu' where id = l.id; n := n + 1; end if;
    end if;
  end loop;
  return n;
end $$;
revoke all on function public.ss_resultados() from public, anon, authenticated;

select jsonb_array_length(valor) as colunas from public.configuracoes where chave = 'ss_colunas';
