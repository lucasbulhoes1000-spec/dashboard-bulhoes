-- ============================================================
-- CRM Bulhões — Agente de IA marca avaliação no Clinicorp (22/10/2026)
-- Configuração em agente_ia.agendamento (tela Agente de IA → Agendamento):
--   profissional e categoria do Clinicorp, procedimento, duração, horários
--   de semana e de sábado, janela de almoço (sempre sobra 1 h livre),
--   antecedência mínima e quantos dias à frente procurar.
-- O agente consulta os horários livres da agenda e marca direto; o contato
-- vai para a etapa "Agendou" no CRM.
-- Rodar no Supabase: SQL Editor → New query → colar tudo → Run.
-- ============================================================
alter table public.agente_ia add column if not exists agendamento jsonb not null default jsonb_build_object(
  'ligado', false,
  'profissional_id', null, 'profissional_nome', null,
  'clinica_id', null,
  'categoria_id', null, 'categoria_nome', 'Avaliação',
  'procedimento', 'Avaliação',
  'duracao_min', 60, 'passo_min', 30,
  'semana_inicio', '09:00', 'semana_ultimo', '18:00',
  'sabado_inicio', '09:00', 'sabado_ultimo', '13:00',
  'almoco_inicio', '12:00', 'almoco_fim', '14:00', 'almoco_min', 60,
  'antecedencia_horas', 2, 'dias_busca', 14);
grant update (agendamento) on public.agente_ia to authenticated;

alter table public.agente_registros drop constraint if exists agente_registros_tipo_check;
alter table public.agente_registros add constraint agente_registros_tipo_check
  check (tipo in ('resposta', 'transferencia', 'sugestao', 'resumo', 'teste', 'erro', 'agendamento'));

select 'agendamento pelo agente pronto (desligado até configurar)' as status;
