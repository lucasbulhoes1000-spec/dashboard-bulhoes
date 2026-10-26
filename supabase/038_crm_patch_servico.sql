-- ============================================================
-- CRM Bulhões — rotinas automáticas gravam o CRM pela mesma mesclagem (25/10/2026)
-- crm_salvar_patch passa a aceitar também o serviço (função crm-rotinas),
-- além da equipe logada.
-- ============================================================
do $$
declare d text;
begin
  d := pg_get_functiondef('public.crm_salvar_patch(jsonb,boolean,jsonb,jsonb)'::regprocedure);
  if position('service_role' in d) = 0 then
    d := replace(d, 'if not public.is_equipe_crm() then raise exception', 'if not (public.is_equipe_crm() or coalesce(auth.role(), '''') = ''service_role'') then raise exception');
    d := replace(d, 'v_por text := coalesce(public.email_atual(), ''?'');', 'v_por text := coalesce(public.email_atual(), case when auth.role() = ''service_role'' then ''rotina automática'' end, ''?'');');
    execute d;
  end if;
end $$;
grant execute on function public.crm_salvar_patch(jsonb, boolean, jsonb, jsonb) to service_role;
select position('service_role' in pg_get_functiondef('public.crm_salvar_patch(jsonb,boolean,jsonb,jsonb)'::regprocedure)) > 0 as servico_liberado;
