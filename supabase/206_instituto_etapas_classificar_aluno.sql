-- 206 (Instituto, 17/11/2026): duas etapas novas no funil do Instituto
--   classificar: coluna temporária com as conversas antigas do WhatsApp para o Lucas classificar 1 a 1
--   aluno: quem já é aluno (grupos das turmas Vivendo de Lentes, Universo das Lentes e Mentoria VIP)
-- Só mexe na tabela instituto_leads. Nada da clínica.
alter table public.instituto_leads drop constraint if exists instituto_leads_etapa_check;
alter table public.instituto_leads add constraint instituto_leads_etapa_check check (etapa in
  ('classificar', 'lead', 'aplicacao', 'qualificado', 'call_agendada', 'call_realizada', 'proposta', 'venda', 'perdido',
   'aluno', 'estudante', 'descarte'));

select etapa, count(*) as cards from public.instituto_leads group by etapa order by etapa;
