-- 071 (03/11/2026) Perfil "trafego" (gestor de tráfego): só a tela Tráfego Pago na Lume.
-- PARTE 1 (rodar sozinha primeiro: valor novo de enum não pode ser usado na mesma transação)
alter type public.papel_equipe add value if not exists 'trafego';
