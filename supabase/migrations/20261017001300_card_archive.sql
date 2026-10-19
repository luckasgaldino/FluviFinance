-- Excluir (arquivar) cartão: sai das listas, do lançamento rápido e da Visão geral, mas o
-- histórico de compras e faturas é preservado (nada financeiro é apagado). Só é permitido sem
-- dívida (nenhuma fatura a pagar nem parcela a faturar), para nenhuma dívida sumir das contas.
-- Reativar devolve o cartão às listas. Exige o desbloqueio (operação de alteração).

create function public.set_card_active(p_card uuid, p_active boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_card public.credit_cards;
begin
  select * into v_card from public.credit_cards where id = p_card for update;
  perform private.require_access(v_card.family_id, 'cards', 'update');
  if p_active is null then
    raise exception 'informe se o cartão fica ativo' using errcode = 'check_violation';
  end if;
  if not p_active and private.card_debt(p_card) <> 0 then
    raise exception 'cartão com dívida em aberto: pague as faturas ou anule os lançamentos antes de excluir'
      using errcode = 'check_violation';
  end if;
  update public.credit_cards set active = p_active where id = p_card;
  update public.financial_accounts set active = p_active where id = v_card.account_id;
  return private.result(p_card, case when p_active then 'active' else 'archived' end);
end;
$$;

revoke execute on function public.set_card_active(uuid, boolean) from public, anon;
grant execute on function public.set_card_active(uuid, boolean) to authenticated;
