-- Fase 2 — implantação na data de corte: tipo de lançamento para a dívida que o cartão já
-- tinha antes de a família começar a usar o FluviFinance (fatura fechada a pagar, saldo da
-- fatura aberta e parcelas de compras antigas). Em migration própria: valor novo de enum não
-- pode ser usado na mesma transação.
alter type public.txn_type add value if not exists 'card_opening_balance';
