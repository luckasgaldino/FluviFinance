-- Fase 2 — implantação na data de corte (spec v2.2 §5; F3 da v1.2).
--
-- create_card_opening_balance registra dívida que o cartão já tinha antes do corte:
-- * fatura fechada ainda não paga  → 1 parcela na fatura daquele vencimento (fechada na hora,
--   fica disponível para pagamento);
-- * parte da fatura aberta já gasta → 1 parcela na fatura aberta;
-- * parcelas restantes de compras antigas → N parcelas a partir do vencimento informado.
-- Entra na DÍVIDA do cartão e nas faturas, mas NÃO é consumo (relatórios e competência só
-- contam despesas e compras) e não mexe no caixa. Anulação desfaz as parcelas como numa compra.

create function public.create_card_opening_balance(
  p_op uuid, p_card uuid, p_description text, p_installment_cents bigint, p_installments int,
  p_first_due_month date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_card     public.credit_cards;
  v_payload  jsonb := jsonb_build_object('card', p_card, 'desc', p_description, 'parcela', p_installment_cents,
    'n', p_installments, 'due', p_first_due_month);
  v_res      jsonb;
  v_total    bigint;
  v_txn      uuid;
  v_purchase uuid;
  v_cycle    uuid;
  v_due      date := date_trunc('month', p_first_due_month)::date;
  v_guess    date;
  v_ref      date;
begin
  select * into v_card from public.credit_cards where id = p_card for update;
  perform private.require_access(v_card.family_id, 'cards', 'create');
  v_res := private.fin_replay(v_card.family_id, p_op, 'create_card_opening_balance', v_payload);
  if v_res is not null then return v_res; end if;
  if not v_card.active then
    raise exception 'cartão inativo' using errcode = 'check_violation';
  end if;
  if p_installments is null or p_installments not between 1 and 36 then
    raise exception 'parcelas devem ser de 1 a 36' using errcode = 'check_violation';
  end if;
  if p_installment_cents is null or p_installment_cents <= 0 then
    raise exception 'informe o valor da parcela' using errcode = 'check_violation';
  end if;
  if coalesce(char_length(btrim(p_description)), 0) = 0 then
    raise exception 'informe uma descrição' using errcode = 'check_violation';
  end if;
  v_total := p_installment_cents * p_installments;

  -- fatura cujo vencimento cai no mês informado: parte de dois meses antes e avança
  v_guess := private.clamp_date(extract(year from v_due - interval '2 months')::int,
                                extract(month from v_due - interval '2 months')::int, v_card.closing_day);
  v_cycle := private.ensure_cycle(p_card, v_guess);
  for i in 1 .. 4 loop
    exit when date_trunc('month', (select due_on from public.billing_cycles where id = v_cycle)) = v_due;
    v_cycle := private.next_cycle(v_cycle);
  end loop;
  if date_trunc('month', (select due_on from public.billing_cycles where id = v_cycle)) <> v_due then
    raise exception 'não foi possível localizar a fatura desse vencimento' using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.billing_cycles where id = v_cycle and status = 'closed') then
    raise exception 'essa fatura já está fechada no FluviFinance; registre a partir da próxima' using errcode = 'check_violation';
  end if;
  v_ref := (select starts_on from public.billing_cycles where id = v_cycle);

  v_txn := private.new_txn(v_card.family_id, 'card_opening_balance', p_description, v_total, null,
    v_card.account_id, v_ref, v_ref, 'Saldo anterior ao início do uso', null, p_op);
  insert into public.card_purchases (transaction_id, family_id, card_id, total_cents, installment_count)
  values (v_txn, v_card.family_id, p_card, v_total, p_installments)
  returning id into v_purchase;
  for i in 1 .. p_installments loop
    if i > 1 then v_cycle := private.next_cycle(v_cycle); end if;
    insert into public.installments (purchase_id, family_id, revision, sequence, amount_cents, billing_cycle_id)
    values (v_purchase, v_card.family_id, 1, i, p_installment_cents, v_cycle);
  end loop;
  perform private.post(v_txn, v_card.family_id, v_card.account_id, -v_total, v_ref);

  -- fatura que já fechou antes de hoje: fecha agora para ficar disponível para pagamento
  perform private.close_cycle(c.id)
     from public.billing_cycles c
    where c.card_id = p_card and c.status = 'open' and c.closes_on < private.today()
      and exists (select 1 from public.installments x where x.billing_cycle_id = c.id and x.purchase_id = v_purchase);

  perform private.assert_card_reconciled(p_card);
  return private.fin_record(v_card.family_id, p_op, 'create_card_opening_balance', v_payload, private.result(v_txn));
end;
$$;

-- anular o saldo anterior desfaz as parcelas, como numa compra
CREATE OR REPLACE FUNCTION public.void_transaction(p_op uuid, p_transaction uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_txn    public.transactions;
  v_card   uuid;
  v_payload jsonb := jsonb_build_object('txn', p_transaction, 'reason', p_reason);
  v_res    jsonb;
  v_refund public.refunds;
  v_credit public.card_credits;
  v_transfer public.transfers;
  v_pay    public.payments;
begin
  select * into v_txn from public.transactions where id = p_transaction;
  perform private.require_access(v_txn.family_id, 'transactions', 'cancel');
  v_res := private.fin_replay(v_txn.family_id, p_op, 'void_transaction', v_payload);
  if v_res is not null then return v_res; end if;
  if coalesce(char_length(btrim(p_reason)), 0) < 3 then
    raise exception 'informe o motivo' using errcode = 'invalid_parameter_value';
  end if;

  -- trava o cartão envolvido primeiro (ordem fixa)
  v_card := coalesce(
    (select card_id from public.card_purchases where transaction_id = p_transaction),
    (select card_id from public.card_credits where transaction_id = p_transaction),
    (select k.id from public.payments p join public.obligations o on o.id = p.obligation_id
       join public.billing_cycles c on c.id = o.billing_cycle_id join public.credit_cards k on k.id = c.card_id
      where p.transaction_id = p_transaction));
  if v_card is not null then perform 1 from public.credit_cards where id = v_card for update; end if;

  select * into v_txn from public.transactions where id = p_transaction for update;
  if v_txn.status <> 'active' then
    raise exception 'operação não está ativa' using errcode = 'check_violation';
  end if;
  if v_txn.type in ('reversal', 'installment_adjustment') then
    raise exception 'esta operação não é anulável; registre a operação contrária' using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.refunds where original_transaction_id = p_transaction and status = 'active') then
    raise exception 'anule ou reverta os estornos antes' using errcode = 'check_violation';  -- INV-R3
  end if;

  if v_txn.type in ('card_purchase', 'card_opening_balance') then
    if exists (select 1 from public.installments i join public.card_purchases p on p.id = i.purchase_id
                join public.billing_cycles c on c.id = i.billing_cycle_id
               where p.transaction_id = p_transaction and i.status = 'valid' and c.status = 'closed') then
      raise exception 'compra com parcela já faturada: use estorno' using errcode = 'check_violation';
    end if;
    update public.installments i set status = 'superseded'
      from public.card_purchases p where p.id = i.purchase_id and p.transaction_id = p_transaction and i.status = 'valid';

  elsif v_txn.type = 'refund' then
    select * into v_refund from public.refunds where refund_transaction_id = p_transaction for update;
    select * into v_credit from public.card_credits where transaction_id = p_transaction for update;
    if v_credit.id is not null then
      if exists (select 1 from public.credit_applications a join public.billing_cycles c on c.id = a.billing_cycle_id
                  where a.credit_id = v_credit.id and a.status = 'active' and c.status = 'closed') then
        raise exception 'crédito já consumido por fatura fechada: use reversão' using errcode = 'check_violation';
      end if;
      update public.credit_applications set status = 'released', released_at = now()
       where credit_id = v_credit.id and status = 'active';
      update public.card_credits set status = 'voided', absorbed_unapplied_cents = amount_cents where id = v_credit.id;
    end if;
    update public.refunds set status = 'voided' where id = v_refund.id;

  elsif v_txn.type in ('transfer_out', 'transfer_in') then
    select * into v_transfer from public.transfers
     where out_transaction_id = p_transaction or in_transaction_id = p_transaction for update;
    -- a anulação vale para o par (INV-R4); exige cancel nas duas pontas
    perform private.require_access(v_transfer.from_family_id, 'transactions', 'cancel');
    perform private.require_access(v_transfer.to_family_id, 'transactions', 'cancel');
    perform private.compensate(case when p_transaction = v_transfer.out_transaction_id
                                    then v_transfer.in_transaction_id else v_transfer.out_transaction_id end, p_reason);
    update public.transfers set status = 'voided' where id = v_transfer.id;
  end if;

  select * into v_pay from public.payments where transaction_id = p_transaction for update;
  if v_pay.id is not null then
    update public.payments set status = 'voided' where id = v_pay.id;  -- reabre a obrigação (estado derivado)
  end if;

  perform private.compensate(p_transaction, p_reason);
  if v_card is not null then perform private.assert_card_reconciled(v_card); end if;
  return private.fin_record(v_txn.family_id, p_op, 'void_transaction', v_payload, private.result(p_transaction, 'voided'));
end;
$function$
;

revoke execute on function public.create_card_opening_balance(uuid, uuid, text, bigint, int, date) from public, anon;
grant execute on function public.create_card_opening_balance(uuid, uuid, text, bigint, int, date) to authenticated;
