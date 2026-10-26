-- ============================================================
-- CRM Bulhões — Lembretes: até 3 confirmações na véspera (25/10/2026)
-- Tipos novos "vespera2" e "vespera3" (2ª e 3ª confirmação). O motor só manda
-- a 2ª/3ª para quem ainda não confirmou nem respondeu depois da anterior.
-- Rodar no Supabase: SQL Editor → New query → colar tudo → Run.
-- ============================================================
do $$
declare r record;
begin
  for r in select conrelid::regclass as t, conname from pg_constraint
            where conrelid in ('public.lembretes_consulta'::regclass, 'public.lembretes_rodadas'::regclass)
              and contype = 'c' and pg_get_constraintdef(oid) ilike '%tipo%' loop
    execute format('alter table %s drop constraint %I', r.t, r.conname);
  end loop;
end $$;
alter table public.lembretes_consulta add constraint lembretes_consulta_tipo_check
  check (tipo in ('vespera', 'vespera2', 'vespera3', 'dia'));
alter table public.lembretes_rodadas add constraint lembretes_rodadas_tipo_check
  check (tipo in ('vespera', 'vespera2', 'vespera3', 'dia'));

select 'lembretes: 3 confirmações na véspera prontas' as status;
