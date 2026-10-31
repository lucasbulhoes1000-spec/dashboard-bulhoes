-- ============================================================
-- 063: CRM de Social Selling em Kanban (31/10/2026)
--   • social_selling ganha a etapa do funil (colunas do Kanban):
--       entrada → conversa → material_1 → material_2 → sem_interesse → amigo_lari → dentista
--       → faltou_horario → agendou → compareceu → venda
--   • Quem RESPONDE no direct (Instagram conectado ao Lume) vira card sozinho em "Leads de entrada".
--     Se o @ já estava registrado como abordagem, o card é o mesmo (só ganha a etapa e a conversa).
--   • status antigo (em_andamento / agendou / desqualificado) segue a etapa, para o painel e o Dashboard.
--   • A cada 15 min: quem está com telefone e compareceu no Clinicorp vai para "Compareceu";
--     orçamento aprovado depois da abordagem vai para "Venda" (com o valor). Só anda para frente.
-- ============================================================

alter table public.social_selling add column if not exists etapa text;
alter table public.social_selling add column if not exists etapa_em timestamptz;
alter table public.social_selling add column if not exists conversa_id uuid references public.conversas(id) on delete set null;
alter table public.social_selling add column if not exists venda_valor numeric(12,2);
do $$ begin
  alter table public.social_selling add constraint social_selling_etapa_ck check (etapa in
    ('entrada', 'conversa', 'material_1', 'material_2', 'sem_interesse', 'amigo_lari', 'dentista',
     'faltou_horario', 'agendou', 'compareceu', 'venda'));
exception when duplicate_object then null; end $$;
create index if not exists social_selling_etapa on public.social_selling (etapa);
create unique index if not exists social_selling_conversa on public.social_selling (conversa_id) where conversa_id is not null;

-- status antigo acompanha a etapa (e vice-versa, para a tela de lista)
create or replace function public.social_selling_tocar()
returns trigger language plpgsql as $$
begin
  new.atualizado_em := now();
  new.atualizado_por := coalesce(public.email_atual(), new.atualizado_por);
  new.instagram := lower(btrim(new.instagram));
  new.telefone := nullif(regexp_replace(coalesce(new.telefone, ''), '\D', '', 'g'), '');
  if tg_op = 'UPDATE' and new.etapa is not distinct from old.etapa and new.status is distinct from old.status then
    -- mudou só o status (tela de lista): leva a etapa junto
    new.etapa := case new.status
      when 'agendou' then case when new.etapa in ('compareceu', 'venda') then new.etapa else 'agendou' end
      when 'desqualificado' then case when new.etapa in ('sem_interesse', 'amigo_lari', 'dentista') then new.etapa else 'sem_interesse' end
      else case when new.etapa in ('agendou', 'compareceu', 'venda', 'sem_interesse', 'amigo_lari', 'dentista') then 'conversa' else new.etapa end end;
  end if;
  if new.etapa is not null then
    new.respondeu := true;
    new.status := case when new.etapa in ('agendou', 'compareceu', 'venda') then 'agendou'
                       when new.etapa in ('sem_interesse', 'amigo_lari', 'dentista') then 'desqualificado'
                       else 'em_andamento' end;
    if tg_op = 'INSERT' or new.etapa is distinct from old.etapa then new.etapa_em := now(); end if;
  end if;
  if new.respondeu and new.respondeu_em is null then new.respondeu_em := (now() at time zone 'America/Sao_Paulo')::date; end if;
  if not new.respondeu then new.respondeu_em := null; end if;
  return new;
end $$;

-- quem já respondeu e não tem etapa entra no funil conforme o status atual
update public.social_selling set etapa = case status when 'agendou' then 'agendou' when 'desqualificado' then 'sem_interesse' else 'conversa' end
 where etapa is null and (respondeu or status <> 'em_andamento');

-- card a partir da conversa do Instagram (quando a pessoa responde)
create or replace function public.ss_da_conversa(p_conversa uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare c public.conversas; v_user text; v_card public.social_selling; v_outro public.social_selling; v_perfil text; v_ab date;
begin
  select * into c from public.conversas where id = p_conversa;
  if c.id is null or c.canal <> 'instagram' or c.ultima_recebida_em is null then return; end if;
  v_user := nullif(lower(btrim(regexp_replace(coalesce(c.ig_usuario, ''), '^@+', ''))), '');
  select case when apelido ilike '%larissa%' then 'Dra. Larissa' when apelido ilike '%cl%nica%' then 'Clínica' else apelido end
    into v_perfil from public.instagram_contas where ig_id = c.numero_clinica_id;

  select * into v_card from public.social_selling where conversa_id = c.id;
  if v_card.id is not null then
    -- já tem card: troca o id provisório pelo @ quando ele chega
    if v_user is not null and v_card.instagram like 'id:%' then
      select * into v_outro from public.social_selling where instagram = v_user and id <> v_card.id;
      if v_outro.id is not null then
        delete from public.social_selling where id = v_card.id;
        update public.social_selling set conversa_id = c.id, etapa = coalesce(etapa, 'entrada'),
               nome = coalesce(nome, c.nome_perfil), perfil = coalesce(perfil, v_perfil) where id = v_outro.id;
      else
        update public.social_selling set instagram = v_user, nome = coalesce(nome, c.nome_perfil) where id = v_card.id;
      end if;
    elsif v_card.nome is null and c.nome_perfil is not null then
      update public.social_selling set nome = c.nome_perfil where id = v_card.id;
    end if;
    return;
  end if;

  if v_user is not null then
    select * into v_card from public.social_selling where instagram = v_user;
    if v_card.id is not null then   -- abordagem registrada antes: o mesmo card entra no funil
      update public.social_selling set conversa_id = c.id, etapa = coalesce(etapa, 'entrada'),
             nome = coalesce(nome, c.nome_perfil), perfil = coalesce(perfil, v_perfil) where id = v_card.id;
      return;
    end if;
  end if;

  select (min(m.enviada_em) at time zone 'America/Sao_Paulo')::date into v_ab from public.mensagens m where m.conversa_id = c.id;
  insert into public.social_selling (instagram, perfil, tipo, abordado_em, respondeu, etapa, conversa_id, nome, criado_por, atualizado_por)
  values (coalesce(v_user, 'id:' || c.wa_id), v_perfil, null, coalesce(v_ab, (now() at time zone 'America/Sao_Paulo')::date),
          true, 'entrada', c.id, c.nome_perfil, 'instagram', 'instagram')
  on conflict (instagram) do update set conversa_id = coalesce(public.social_selling.conversa_id, excluded.conversa_id),
          etapa = coalesce(public.social_selling.etapa, 'entrada');
exception when others then
  insert into public.espelho_erros (origem, erro, detalhe) values ('ss_da_conversa', sqlerrm, p_conversa::text);
end $$;
revoke all on function public.ss_da_conversa(uuid) from public, anon, authenticated;

create or replace function public.ss_t_conversa() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.canal = 'instagram' and new.ultima_recebida_em is not null then
    perform public.ss_da_conversa(new.id);
  end if;
  return null;
end $$;
drop trigger if exists t_ss_conversa on public.conversas;
create trigger t_ss_conversa after insert or update of ultima_recebida_em, ig_usuario, nome_perfil on public.conversas
  for each row execute function public.ss_t_conversa();

-- conversas do Instagram que já responderam (se houver) entram agora
do $$ declare r record; begin
  for r in select id from public.conversas where canal = 'instagram' and ultima_recebida_em is not null loop
    perform public.ss_da_conversa(r.id);
  end loop;
end $$;

-- comparecimento e venda pelo Clinicorp (só anda para frente)
create or replace function public.ss_resultados() returns integer
language plpgsql security definer set search_path = public, pg_temp as $$
declare l record; v_comp boolean; v_qtd integer; v_valor numeric; n integer := 0;
begin
  for l in select s.* from public.social_selling s
            where s.telefone is not null and length(s.telefone) >= 10
              and coalesce(s.etapa, '') not in ('amigo_lari', 'dentista', 'venda') loop
    select count(*), sum(coalesce(nullif(o.fechamento_valor, 0), o.valor, 0)) into v_qtd, v_valor
      from public.orcamentos o join public.pacientes p on p.id = o.paciente_id
     where right(p.telefone, 8) = right(l.telefone, 8) and o.status = 'Aprovado'
       and coalesce(o.fechamento_data, o.data) >= l.abordado_em;
    if v_qtd > 0 then
      update public.social_selling set etapa = 'venda', venda_valor = v_valor where id = l.id;
      n := n + 1; continue;
    end if;
    if l.etapa in ('agendou', 'faltou_horario') then
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
do $$ begin perform cron.unschedule('ss-resultados'); exception when others then null; end $$;
select cron.schedule('ss-resultados', '*/15 * * * *', $cron$ select public.ss_resultados(); $cron$);

select (select count(*) from public.social_selling) as cards,
       (select count(*) from public.social_selling where etapa is not null) as no_funil,
       public.ss_resultados() as atualizados;
