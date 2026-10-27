-- CRM Bulhões — foto enviada por link (IA, automações) aparece na Central (27/10/2026)
create or replace function public.wa_t_midia_link() returns trigger
language plpgsql as $$
begin
  if new.direcao = 'enviada' and new.tipo in ('image', 'video', 'document') and new.midia_caminho is null
     and new.midia_url is null and coalesce(new.bruto->>'link', '') like 'http%' then
    new.midia_url := new.bruto->>'link';
  end if;
  return new;
end $$;
drop trigger if exists wa_t_midia_link on public.mensagens;
create trigger wa_t_midia_link before insert on public.mensagens for each row execute function public.wa_t_midia_link();
update public.mensagens set midia_url = bruto->>'link'
 where direcao = 'enviada' and tipo in ('image', 'video', 'document') and midia_caminho is null and midia_url is null
   and coalesce(bruto->>'link', '') like 'http%';
select count(*) as fotos_por_link from public.mensagens where direcao = 'enviada' and midia_url is not null and midia_caminho is null;
