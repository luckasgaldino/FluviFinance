-- Ajuste de saldo (FF-03: "ajustes de saldo são lançamentos identificados"): tipos próprios,
-- para mais e para menos, que não são receita nem despesa. Em migration própria: valor novo de
-- enum não pode ser usado na mesma transação em que é criado.
alter type public.txn_type add value if not exists 'adjustment_in';
alter type public.txn_type add value if not exists 'adjustment_out';
