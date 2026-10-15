-- Fluvi — Marco B — RPCs (2/2): obrigações, pagamentos, estornos, transferências,
-- anulação × reversão, ajuste de parcelas, recorrências e jobs.

-- ---------------------------------------------------------------------------
-- 1. Obrigações (contas a pagar e previsões de receita)
-- ---------------------------------------------------------------------------
create function public.create_obligation(
  p_op uuid, p_owner uuid, p_type public.obligation_type, p_description text, p_category uuid,
  p_amount_cents bigint, p_due_date date, p_competence_month date default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_payload jsonb := jsonb_build_object('type', p_type, 'desc', p_description, 'cat', p_category,
    'amt', p_amount_cents, 'due', p_due_date, 'comp', p_competence_month);
  v_res jsonb;
  v_id  uuid;
begin
  perform private.require_access(p_owner, 'transactions', 'create');
  v_res := private.fin_replay(p_owner, p_op, 'create_obligation', v_payload);
  if v_res is not null then return v_res; end if;
  if p_type not in ('bill', 'receivable') then
    raise exception 'faturas são criadas pelo fechamento do ciclo' using errcode = 'check_violation';
  end if;
  perform private.check_category(p_owner, p_category,
    case when p_type = 'bill' then 'expense'::public.category_kind else 'income' end);
  insert into public.obligations (owner_user_id, type, description, category_id, competence_month,
    due_date, original_amount_cents, client_operation_id)
  values (p_owner, p_type, btrim(p_description), p_category,
    private.month_start(coalesce(p_competence_month, p_due_date)), p_due_date, p_amount_cents, p_op)
  returning id into v_id;
  return private.fin_record(p_owner, p_op, 'create_obligation', v_payload, private.result(v_id));
end;
$$;

create function public.adjust_obligation(p_op uuid, p_obligation uuid, p_delta_cents bigint, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_obl public.obligations;
  v_payload jsonb := jsonb_build_object('obl', p_obligation, 'delta', p_delta_cents, 'reason', p_reason);
  v_res jsonb;
begin
  select * into v_obl from public.obligations where id = p_obligation;
  perform private.require_access(v_obl.owner_user_id, 'transactions', 'update');
  v_res := private.fin_replay(v_obl.owner_user_id, p_op, 'adjust_obligation', v_payload);
  if v_res is not null then return v_res; end if;
  select * into v_obl from public.obligations where id = p_obligation for update;
  if v_obl.type = 'card_bill' or v_obl.status <> 'active' then
    raise exception 'obrigação não ajustável' using errcode = 'check_violation';
  end if;
  if v_obl.original_amount_cents + v_obl.adjustments_cents + p_delta_cents < private.obligation_paid(p_obligation) then
    raise exception 'ajuste deixaria o devido abaixo do já pago' using errcode = 'check_violation';
  end if;
  update public.obligations set adjustments_cents = adjustments_cents + p_delta_cents where id = p_obligation;
  return private.fin_record(v_obl.owner_user_id, p_op, 'adjust_obligation', v_payload, private.result(p_obligation));
end;
$$;

create function public.cancel_obligation(p_op uuid, p_obligation uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_obl public.obligations;
  v_payload jsonb := jsonb_build_object('obl', p_obligation, 'reason', p_reason);
  v_res jsonb;
begin
  select * into v_obl from public.obligations where id = p_obligation;
  perform private.require_access(v_obl.owner_user_id, 'transactions', 'cancel');
  v_res := private.fin_replay(v_obl.owner_user_id, p_op, 'cancel_obligation', v_payload);
  if v_res is not null then return v_res; end if;
  select * into v_obl from public.obligations where id = p_obligation for update;
  if v_obl.type = 'card_bill' or v_obl.status <> 'active' or private.obligation_paid(p_obligation) > 0 then
    raise exception 'obrigação com pagamento ou fatura não é cancelada; use reversão/ajuste' using errcode = 'check_violation';
  end if;
  update public.obligations set status = 'cancelled', cancelled_at = now() where id = p_obligation;
  return private.fin_record(v_obl.owner_user_id, p_op, 'cancel_obligation', v_payload, private.result(p_obligation));
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Pagamento (parcial ou total) — sem dupla contagem (§17.6)
-- ---------------------------------------------------------------------------
create function public.settle_obligation(
  p_op uuid, p_obligation uuid, p_account uuid, p_amount_cents bigint, p_paid_on date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_obl   public.obligations;
  v_card  public.credit_cards;
  v_payload jsonb := jsonb_build_object('obl', p_obligation, 'acc', p_account, 'amt', p_amount_cents, 'on', p_paid_on);
  v_res   jsonb;
  v_txn   uuid;
  v_type  public.txn_type;
begin
  select * into v_obl from public.obligations where id = p_obligation;
  perform private.require_access(v_obl.owner_user_id, 'transactions', 'create');
  v_res := private.fin_replay(v_obl.owner_user_id, p_op, 'settle_obligation', v_payload);
  if v_res is not null then return v_res; end if;
  perform private.require_cash_account(p_account, v_obl.owner_user_id);

  if v_obl.type = 'card_bill' then  -- ordem de travas: cartão → obrigação
    select k.* into v_card from public.credit_cards k
      join public.billing_cycles c on c.card_id = k.id where c.id = v_obl.billing_cycle_id
     for update of k;
  end if;
  select * into v_obl from public.obligations where id = p_obligation for update;
  if v_obl.status <> 'active' then
    raise exception 'obrigação cancelada' using errcode = 'check_violation';
  end if;
  if p_amount_cents is null or p_amount_cents <= 0
     or p_amount_cents > v_obl.original_amount_cents + v_obl.adjustments_cents - private.obligation_paid(p_obligation) then
    raise exception 'valor acima do devido' using errcode = 'check_violation';  -- MB-06; INV-O1
  end if;

  v_type := (case v_obl.type when 'card_bill' then 'card_bill_payment'
                             when 'bill' then 'bill_payment' else 'income' end)::public.txn_type;
  v_txn := private.new_txn(v_obl.owner_user_id, v_type, v_obl.description, p_amount_cents,
    case when v_obl.type = 'receivable' then v_obl.category_id end,
    p_account, p_paid_on, v_obl.competence_month, null, null, p_op);

  if v_obl.type = 'receivable' then
    perform private.post(v_txn, v_obl.owner_user_id, p_account, p_amount_cents, p_paid_on);
  else
    perform private.post(v_txn, v_obl.owner_user_id, p_account, -p_amount_cents, p_paid_on);
    if v_obl.type = 'card_bill' then
      perform private.post(v_txn, v_obl.owner_user_id, v_card.account_id, p_amount_cents, p_paid_on);
    end if;
  end if;

  insert into public.payments (owner_user_id, obligation_id, account_id, transaction_id, amount_cents, paid_on)
  values (v_obl.owner_user_id, p_obligation, p_account, v_txn, p_amount_cents, p_paid_on);

  if v_card.id is not null then perform private.assert_card_reconciled(v_card.id); end if;
  return private.fin_record(v_obl.owner_user_id, p_op, 'settle_obligation', v_payload, private.result(v_txn));
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Estorno (§7 e §17.1): no cartão gera crédito; em conta é recuperação de gasto
-- ---------------------------------------------------------------------------
create function private.first_open_cycle_from(p_card uuid, p_date date)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cycle uuid := private.ensure_cycle(p_card, p_date);
begin
  while (select status from public.billing_cycles where id = v_cycle) = 'closed' loop
    v_cycle := private.next_cycle(v_cycle);
  end loop;
  return v_cycle;
end;
$$;

create function public.refund_transaction(
  p_op uuid, p_transaction uuid, p_amount_cents bigint, p_refunded_on date, p_description text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_txn   public.transactions;
  v_card  public.credit_cards;
  v_payload jsonb := jsonb_build_object('txn', p_transaction, 'amt', p_amount_cents, 'on', p_refunded_on, 'desc', p_description);
  v_res   jsonb;
  v_base  bigint;
  v_ref   uuid;
  v_credit uuid;
  v_cycle uuid;
  v_take  bigint;
begin
  select * into v_txn from public.transactions where id = p_transaction;
  perform private.require_access(v_txn.owner_user_id, 'transactions', 'create');
  v_res := private.fin_replay(v_txn.owner_user_id, p_op, 'refund_transaction', v_payload);
  if v_res is not null then return v_res; end if;
  if v_txn.type not in ('expense', 'card_purchase') then
    raise exception 'só compras e despesas recebem estorno' using errcode = 'check_violation';
  end if;
  if v_txn.type = 'card_purchase' then
    select k.* into v_card from public.credit_cards k join public.card_purchases p on p.card_id = k.id
     where p.transaction_id = p_transaction for update of k;
  end if;
  select * into v_txn from public.transactions where id = p_transaction for update;
  if v_txn.status <> 'active' then
    raise exception 'operação não está ativa' using errcode = 'check_violation';
  end if;
  v_base := case when v_txn.type = 'card_purchase'
                 then (select total_cents from public.card_purchases where transaction_id = p_transaction)
                 else v_txn.amount_cents end;
  if p_amount_cents is null or p_amount_cents <= 0 or p_amount_cents > v_base - coalesce((
       select sum(amount_cents) from public.refunds where original_transaction_id = p_transaction and status = 'active'), 0) then
    raise exception 'estorno acima do valor estornável' using errcode = 'check_violation';  -- INV-R1
  end if;

  v_ref := private.new_txn(v_txn.owner_user_id, 'refund', coalesce(p_description, 'Estorno: ' || v_txn.description),
    p_amount_cents, v_txn.category_id, v_txn.account_id, p_refunded_on, v_txn.competence_month, null, p_transaction, p_op);
  perform private.post(v_ref, v_txn.owner_user_id, v_txn.account_id, p_amount_cents, p_refunded_on);
  insert into public.refunds (owner_user_id, original_transaction_id, refund_transaction_id, target, amount_cents, refunded_on)
  values (v_txn.owner_user_id, p_transaction, v_ref,
    case when v_card.id is not null then 'card'::public.refund_target else 'account' end, p_amount_cents, p_refunded_on);

  if v_card.id is not null then
    insert into public.card_credits (owner_user_id, card_id, transaction_id, amount_cents)
    values (v_txn.owner_user_id, v_card.id, v_ref, p_amount_cents) returning id into v_credit;
    -- aplica ao ciclo aberto da data do estorno; excedente fica não aplicado (§5.6)
    v_cycle := private.first_open_cycle_from(v_card.id, p_refunded_on);
    v_take := least(private.cycle_amount(v_cycle), p_amount_cents);
    if v_take > 0 then
      insert into public.credit_applications (credit_id, owner_user_id, billing_cycle_id, amount_cents)
      values (v_credit, v_txn.owner_user_id, v_cycle, v_take);
    end if;
    perform private.assert_card_reconciled(v_card.id);
  end if;
  return private.fin_record(v_txn.owner_user_id, p_op, 'refund_transaction', v_payload, private.result(v_ref));
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Transferência (MB-07 revisada: accounts/create nas DUAS pontas)
-- ---------------------------------------------------------------------------
create function public.transfer_funds(
  p_op uuid, p_from_account uuid, p_to_account uuid, p_amount_cents bigint, p_executed_on date,
  p_description text default 'Transferência')
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_from  uuid;
  v_to    uuid;
  v_payload jsonb := jsonb_build_object('from', p_from_account, 'to', p_to_account, 'amt', p_amount_cents,
    'on', p_executed_on, 'desc', p_description);
  v_res   jsonb;
  v_out   uuid;
  v_in    uuid;
  v_id    uuid;
begin
  v_from := private.account_owner(p_from_account, 'accounts', 'create');
  v_to   := private.account_owner(p_to_account, 'accounts', 'create');
  v_res := private.fin_replay(v_from, p_op, 'transfer_funds', v_payload);
  if v_res is not null then return v_res; end if;
  perform private.require_cash_account(p_from_account, v_from);
  perform private.require_cash_account(p_to_account, v_to);
  if p_from_account = p_to_account or p_amount_cents is null or p_amount_cents <= 0 then
    raise exception 'transferência inválida' using errcode = 'check_violation';
  end if;
  v_out := private.new_txn(v_from, 'transfer_out', p_description, p_amount_cents, null, p_from_account,
    p_executed_on, null, null, null, p_op);
  v_in := private.new_txn(v_to, 'transfer_in', p_description, p_amount_cents, null, p_to_account,
    p_executed_on, null, null, null, null);
  perform private.post(v_out, v_from, p_from_account, -p_amount_cents, p_executed_on);
  perform private.post(v_in, v_to, p_to_account, p_amount_cents, p_executed_on);
  insert into public.transfers (from_account_id, to_account_id, from_owner_user_id, to_owner_user_id,
    amount_cents, executed_on, out_transaction_id, in_transaction_id, created_by)
  values (p_from_account, p_to_account, v_from, v_to, p_amount_cents, p_executed_on, v_out, v_in, auth.uid())
  returning id into v_id;
  return private.fin_record(v_from, p_op, 'transfer_funds', v_payload, private.result(v_id));
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Anulação (erro de registro; compensação na data original) — §8, §17.3
-- ---------------------------------------------------------------------------
create function public.void_transaction(p_op uuid, p_transaction uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
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
  perform private.require_access(v_txn.owner_user_id, 'transactions', 'cancel');
  v_res := private.fin_replay(v_txn.owner_user_id, p_op, 'void_transaction', v_payload);
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

  if v_txn.type = 'card_purchase' then
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
    perform private.require_access(v_transfer.from_owner_user_id, 'transactions', 'cancel');
    perform private.require_access(v_transfer.to_owner_user_id, 'transactions', 'cancel');
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
  return private.fin_record(v_txn.owner_user_id, p_op, 'void_transaction', v_payload, private.result(p_transaction, 'voided'));
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Reversão (movimento real contrário, na data do evento) — §8, §17.3
-- ---------------------------------------------------------------------------
create function public.reverse_transaction(p_op uuid, p_transaction uuid, p_reversed_on date, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_txn    public.transactions;
  v_card   uuid;
  v_payload jsonb := jsonb_build_object('txn', p_transaction, 'on', p_reversed_on, 'reason', p_reason);
  v_res    jsonb;
  v_rev    uuid;
  v_e      record;
  v_credit public.card_credits;
  v_transfer public.transfers;
  v_left   bigint;
  v_take   bigint;
  v_app    record;
begin
  select * into v_txn from public.transactions where id = p_transaction;
  perform private.require_access(v_txn.owner_user_id, 'transactions', 'cancel');
  v_res := private.fin_replay(v_txn.owner_user_id, p_op, 'reverse_transaction', v_payload);
  if v_res is not null then return v_res; end if;
  if coalesce(char_length(btrim(p_reason)), 0) < 3 then
    raise exception 'informe o motivo' using errcode = 'invalid_parameter_value';
  end if;

  v_card := coalesce(
    (select card_id from public.card_credits where transaction_id = p_transaction),
    (select k.id from public.payments p join public.obligations o on o.id = p.obligation_id
       join public.billing_cycles c on c.id = o.billing_cycle_id join public.credit_cards k on k.id = c.card_id
      where p.transaction_id = p_transaction));
  if v_card is not null then perform 1 from public.credit_cards where id = v_card for update; end if;

  select * into v_txn from public.transactions where id = p_transaction for update;
  if v_txn.status <> 'active' then
    raise exception 'operação não está ativa' using errcode = 'check_violation';
  end if;
  if v_txn.type in ('card_purchase', 'reversal', 'installment_adjustment') then
    raise exception 'compra no cartão é desfeita por estorno ou ajuste de parcelas' using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.refunds where original_transaction_id = p_transaction and status = 'active') then
    raise exception 'reverta os estornos antes' using errcode = 'check_violation';
  end if;

  -- movimento real contrário, datado no evento
  v_rev := private.new_txn(v_txn.owner_user_id, 'reversal', 'Reversão: ' || v_txn.description, v_txn.amount_cents,
    null, v_txn.account_id, p_reversed_on, v_txn.competence_month, left(p_reason, 500), p_transaction, p_op);
  for v_e in select account_id, amount_cents from public.ledger_entries where transaction_id = p_transaction and kind = 'normal' loop
    perform private.post(v_rev, v_txn.owner_user_id, v_e.account_id, -v_e.amount_cents, p_reversed_on);
  end loop;

  if v_txn.type = 'refund' then
    update public.refunds set status = 'reversed' where refund_transaction_id = p_transaction;
    select * into v_credit from public.card_credits where transaction_id = p_transaction for update;
    if v_credit.id is not null then
      -- absorção: 1) não aplicado; 2) libera aplicações em ciclos abertos (da mais futura);
      -- 3) restante (aplicado a ciclos fechados/pagos) vira encargo no ciclo aberto atual
      v_left := v_credit.amount_cents;
      v_take := least(v_left, private.credit_unapplied(v_credit.id));
      update public.card_credits set absorbed_unapplied_cents = absorbed_unapplied_cents + v_take, status = 'reversed'
       where id = v_credit.id;
      v_left := v_left - v_take;
      for v_app in
        select a.id, a.amount_cents, a.billing_cycle_id from public.credit_applications a
          join public.billing_cycles c on c.id = a.billing_cycle_id
         where a.credit_id = v_credit.id and a.status = 'active' and c.status = 'open'
         order by c.closes_on desc
      loop
        exit when v_left <= 0;
        v_take := least(v_left, v_app.amount_cents);
        update public.credit_applications set status = 'released', released_at = now() where id = v_app.id;
        -- o liberado é absorvido pela reversão (não volta a ser crédito disponível; INV-C11)
        update public.card_credits set absorbed_unapplied_cents = absorbed_unapplied_cents + v_take where id = v_credit.id;
        if v_take < v_app.amount_cents then
          insert into public.credit_applications (credit_id, owner_user_id, billing_cycle_id, amount_cents)
          values (v_credit.id, v_txn.owner_user_id, v_app.billing_cycle_id, v_app.amount_cents - v_take);
        end if;
        v_left := v_left - v_take;
      end loop;
      if v_left > 0 then
        insert into public.cycle_charges (owner_user_id, billing_cycle_id, credit_id, transaction_id, amount_cents)
        values (v_txn.owner_user_id, private.first_open_cycle_from(v_credit.card_id, p_reversed_on),
                v_credit.id, v_rev, v_left);
      end if;
    end if;
  elsif v_txn.type in ('transfer_out', 'transfer_in') then
    select * into v_transfer from public.transfers
     where out_transaction_id = p_transaction or in_transaction_id = p_transaction for update;
    perform private.require_access(v_transfer.from_owner_user_id, 'transactions', 'cancel');
    perform private.require_access(v_transfer.to_owner_user_id, 'transactions', 'cancel');
    declare
      v_other public.transactions;
      v_rev2 uuid;
    begin
      select * into v_other from public.transactions
       where id = case when p_transaction = v_transfer.out_transaction_id
                       then v_transfer.in_transaction_id else v_transfer.out_transaction_id end for update;
      v_rev2 := private.new_txn(v_other.owner_user_id, 'reversal', 'Reversão: ' || v_other.description,
        v_other.amount_cents, null, v_other.account_id, p_reversed_on, null, left(p_reason, 500), v_other.id, null);
      perform private.post(v_rev2, v_other.owner_user_id, v_other.account_id,
        -(select sum(amount_cents) from public.ledger_entries where transaction_id = v_other.id and kind = 'normal')::bigint,
        p_reversed_on);
      update public.transactions set status = 'reversed', cancelled_at = now(), cancelled_by = auth.uid(),
             cancel_reason = left(p_reason, 200) where id = v_other.id;
    end;
    update public.transfers set status = 'reversed' where id = v_transfer.id;
  end if;

  update public.payments set status = 'reversed' where transaction_id = p_transaction;  -- reabre a obrigação
  update public.transactions set status = 'reversed', cancelled_at = now(),
         cancelled_by = coalesce(auth.uid(), '00000000-0000-0000-0000-000000000000'), cancel_reason = left(p_reason, 200)
   where id = p_transaction;
  if v_card is not null then perform private.assert_card_reconciled(v_card); end if;
  return private.fin_record(v_txn.owner_user_id, p_op, 'reverse_transaction', v_payload, private.result(v_rev, 'reversed'));
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Ajuste de parcelas (§17.4)
-- ---------------------------------------------------------------------------
create function public.adjust_installments(
  p_op uuid, p_purchase_transaction uuid, p_new_total_cents bigint, p_remaining_count int, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_purchase public.card_purchases;
  v_txn      public.transactions;
  v_card     public.credit_cards;
  v_payload jsonb := jsonb_build_object('txn', p_purchase_transaction, 'total', p_new_total_cents,
    'n', p_remaining_count, 'reason', p_reason);
  v_res      jsonb;
  v_kept     bigint;
  v_kept_n   int;
  v_rest     bigint;
  v_start    uuid;
  v_cycle    uuid;
  v_part     record;
  v_delta    bigint;
  v_adj      uuid;
begin
  select * into v_purchase from public.card_purchases where transaction_id = p_purchase_transaction;
  perform private.require_access(v_purchase.owner_user_id, 'transactions', 'update');
  v_res := private.fin_replay(v_purchase.owner_user_id, p_op, 'adjust_installments', v_payload);
  if v_res is not null then return v_res; end if;
  select * into v_card from public.credit_cards where id = v_purchase.card_id for update;
  select * into v_purchase from public.card_purchases where id = v_purchase.id for update;
  select * into v_txn from public.transactions where id = p_purchase_transaction for update;
  if v_txn.status <> 'active' then
    raise exception 'compra não está ativa' using errcode = 'check_violation';
  end if;

  -- preservadas: parcelas válidas em ciclos fechados (faturadas/liquidadas)
  select coalesce(sum(i.amount_cents), 0), count(*)
    into v_kept, v_kept_n
    from public.installments i join public.billing_cycles c on c.id = i.billing_cycle_id
   where i.purchase_id = v_purchase.id and i.status = 'valid' and c.status = 'closed';
  if p_new_total_cents is null or p_new_total_cents < v_kept then
    raise exception 'novo total menor que as parcelas já faturadas' using errcode = 'check_violation';  -- O42
  end if;
  v_rest := p_new_total_cents - v_kept;
  if (v_rest > 0 and coalesce(p_remaining_count, 0) < 1) or (v_rest = 0 and coalesce(p_remaining_count, 0) <> 0)
     or v_kept_n + coalesce(p_remaining_count, 0) > 48 then
    raise exception 'quantidade de parcelas incompatível com o saldo a parcelar' using errcode = 'check_violation';
  end if;
  if coalesce((select sum(amount_cents) from public.refunds
                where original_transaction_id = p_purchase_transaction and status = 'active'), 0) > p_new_total_cents then
    raise exception 'estornos acima do novo total' using errcode = 'check_violation';
  end if;

  -- ciclo de partida: o da primeira parcela elegível; senão, o seguinte à última preservada
  select i.billing_cycle_id into v_start
    from public.installments i join public.billing_cycles c on c.id = i.billing_cycle_id
   where i.purchase_id = v_purchase.id and i.status = 'valid' and c.status = 'open'
   order by i.sequence limit 1;
  if v_start is null then
    select private.next_cycle(i.billing_cycle_id) into v_start
      from public.installments i
     where i.purchase_id = v_purchase.id and i.status = 'valid' order by i.sequence desc limit 1;
  end if;

  update public.installments i set status = 'superseded'
    from public.billing_cycles c
   where c.id = i.billing_cycle_id and i.purchase_id = v_purchase.id and i.status = 'valid' and c.status = 'open';

  if v_rest > 0 then
    v_cycle := v_start;
    for v_part in select * from private.split_cents(v_rest, p_remaining_count) loop
      if v_part.seq > 1 then v_cycle := private.next_cycle(v_cycle); end if;
      insert into public.installments (purchase_id, owner_user_id, revision, sequence, amount_cents, billing_cycle_id)
      values (v_purchase.id, v_purchase.owner_user_id, v_purchase.revision + 1, v_kept_n + v_part.seq, v_part.amount, v_cycle);
    end loop;
  end if;

  v_delta := p_new_total_cents - v_purchase.total_cents;
  if v_delta <> 0 then
    v_adj := private.new_txn(v_purchase.owner_user_id, 'installment_adjustment',
      'Ajuste de parcelas: ' || v_txn.description, abs(v_delta), null, v_card.account_id,
      private.today(), v_txn.competence_month, left(p_reason, 500), p_purchase_transaction, null);
    perform private.post(v_adj, v_purchase.owner_user_id, v_card.account_id, -v_delta, private.today());
  end if;

  update public.card_purchases
     set total_cents = p_new_total_cents, installment_count = v_kept_n + coalesce(p_remaining_count, 0),
         revision = revision + 1
   where id = v_purchase.id;

  -- INV-C1: parcelas válidas = total vigente; EQ-1 e ciclos sem crédito > débito
  if (select coalesce(sum(amount_cents), 0) from public.installments where purchase_id = v_purchase.id and status = 'valid')
     <> p_new_total_cents then
    raise exception 'parcelas não fecham com o total' using errcode = 'check_violation';
  end if;
  perform private.assert_card_reconciled(v_card.id);
  return private.fin_record(v_purchase.owner_user_id, p_op, 'adjust_installments', v_payload,
    private.result(p_purchase_transaction) || jsonb_build_object('revision', v_purchase.revision + 1));
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. Recorrências
-- ---------------------------------------------------------------------------
create function public.create_recurrence_rule(
  p_op uuid, p_owner uuid, p_kind public.obligation_type, p_description text, p_category uuid,
  p_amount_cents bigint, p_frequency public.recurrence_frequency, p_day_of_month int, p_start_date date,
  p_month_of_year int default null, p_end_date date default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_payload jsonb := jsonb_build_object('kind', p_kind, 'desc', p_description, 'cat', p_category, 'amt', p_amount_cents,
    'freq', p_frequency, 'day', p_day_of_month, 'start', p_start_date, 'month', p_month_of_year, 'end', p_end_date);
  v_res jsonb;
  v_id  uuid;
begin
  perform private.require_access(p_owner, 'transactions', 'create');
  v_res := private.fin_replay(p_owner, p_op, 'create_recurrence_rule', v_payload);
  if v_res is not null then return v_res; end if;
  perform private.check_category(p_owner, p_category,
    case when p_kind = 'bill' then 'expense'::public.category_kind else 'income' end);
  insert into public.recurrence_rules (owner_user_id, kind, description, category_id, amount_cents, frequency,
    day_of_month, month_of_year, start_date, end_date)
  values (p_owner, p_kind, btrim(p_description), p_category, p_amount_cents, p_frequency,
    p_day_of_month, p_month_of_year, p_start_date, p_end_date)
  returning id into v_id;
  return private.fin_record(p_owner, p_op, 'create_recurrence_rule', v_payload, private.result(v_id));
end;
$$;

create function public.set_recurrence_status(p_op uuid, p_rule uuid, p_status public.recurrence_status)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rule public.recurrence_rules;
  v_payload jsonb := jsonb_build_object('rule', p_rule, 'status', p_status);
  v_res jsonb;
begin
  select * into v_rule from public.recurrence_rules where id = p_rule;
  perform private.require_access(v_rule.owner_user_id, 'transactions', 'update');
  v_res := private.fin_replay(v_rule.owner_user_id, p_op, 'set_recurrence_status', v_payload);
  if v_res is not null then return v_res; end if;
  if v_rule.status = 'cancelled' then
    raise exception 'regra cancelada não muda de estado' using errcode = 'check_violation';
  end if;
  update public.recurrence_rules set status = p_status where id = p_rule;
  return private.fin_record(v_rule.owner_user_id, p_op, 'set_recurrence_status', v_payload, private.result(p_rule));
end;
$$;

-- "Esta e as futuras": nova revisão; ajusta obrigações futuras ainda sem pagamento.
create function public.update_recurrence_amount(p_op uuid, p_rule uuid, p_amount_cents bigint, p_from_period text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rule public.recurrence_rules;
  v_payload jsonb := jsonb_build_object('rule', p_rule, 'amt', p_amount_cents, 'from', p_from_period);
  v_res jsonb;
begin
  select * into v_rule from public.recurrence_rules where id = p_rule;
  perform private.require_access(v_rule.owner_user_id, 'transactions', 'update');
  v_res := private.fin_replay(v_rule.owner_user_id, p_op, 'update_recurrence_amount', v_payload);
  if v_res is not null then return v_res; end if;
  select * into v_rule from public.recurrence_rules where id = p_rule for update;
  update public.recurrence_rules set amount_cents = p_amount_cents, revision = revision + 1 where id = p_rule;
  update public.obligations o
     set adjustments_cents = p_amount_cents - o.original_amount_cents
    from public.recurrence_occurrences r
   where r.id = o.occurrence_id and r.rule_id = p_rule and r.period_key >= p_from_period
     and o.status = 'active' and private.obligation_paid(o.id) = 0;
  return private.fin_record(v_rule.owner_user_id, p_op, 'update_recurrence_amount', v_payload,
    private.result(p_rule) || jsonb_build_object('revision', v_rule.revision + 1));
end;
$$;

create function private.generate_occurrences(p_horizon date)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rule  public.recurrence_rules;
  v_month date;
  v_due   date;
  v_occ   uuid;
  v_count int := 0;
begin
  for v_rule in select * from public.recurrence_rules where status = 'active' order by id loop
    v_month := private.month_start(v_rule.start_date);
    while v_month <= private.month_start(least(p_horizon, coalesce(v_rule.end_date, p_horizon))) loop
      if v_rule.frequency = 'monthly' or extract(month from v_month) = v_rule.month_of_year then
        v_due := private.clamp_date(extract(year from v_month)::int, extract(month from v_month)::int, v_rule.day_of_month);
        if v_due between v_rule.start_date and least(p_horizon, coalesce(v_rule.end_date, p_horizon)) then
          insert into public.recurrence_occurrences (rule_id, owner_user_id, period_key, revision)
          values (v_rule.id, v_rule.owner_user_id, to_char(v_month, 'YYYY-MM'), v_rule.revision)
          on conflict (rule_id, period_key) do nothing
          returning id into v_occ;
          if v_occ is not null then
            insert into public.obligations (owner_user_id, type, description, category_id, competence_month,
              due_date, original_amount_cents, occurrence_id)
            values (v_rule.owner_user_id, v_rule.kind, v_rule.description, v_rule.category_id, v_month,
              v_due, v_rule.amount_cents, v_occ);
            v_count := v_count + 1;
          end if;
          v_occ := null;
        end if;
      end if;
      v_month := (v_month + interval '1 month')::date;
    end loop;
  end loop;
  return v_count;
end;
$$;

-- ---------------------------------------------------------------------------
-- 9. Jobs (§17.2): início commitado, trabalho em subtransação, falha commitada
-- ---------------------------------------------------------------------------
create function private.job_close_due_cycles()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_c     record;
  v_count int := 0;
begin
  for v_c in
    select c.id, c.card_id from public.billing_cycles c
     where c.status = 'open' and c.closes_on < private.today()
     order by c.card_id, c.closes_on
  loop
    perform 1 from public.credit_cards where id = v_c.card_id for update;
    perform private.close_cycle(v_c.id);
    perform private.assert_card_reconciled(v_c.card_id);
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

-- Failpoint de teste: só tem efeito para quem pode executar o job (postgres/serviço).
create function private.job_failpoint(p_job text)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if current_setting('fluvi.failpoint', true) = p_job then
    raise exception 'falha simulada' using errcode = 'P0001', hint = 'failpoint';
  end if;
end;
$$;

-- Sem SET na procedure: procedures com SET não podem executar COMMIT. Nomes qualificados.
create procedure private.run_job(p_job text)
language plpgsql
as $$
declare
  v_run   uuid;
  v_items integer := 0;
  v_state text;
  v_hint  text;
begin
  update public.job_runs set status = 'abandoned', finished_at = clock_timestamp(), error = 'execução interrompida'
   where job = p_job and status = 'running' and started_at < clock_timestamp() - interval '30 minutes';

  if not pg_catalog.pg_try_advisory_lock(pg_catalog.hashtext('fluvi.job.' || p_job)) then
    insert into public.job_runs (job, status, finished_at, error)
    values (p_job, 'skipped', clock_timestamp(), 'outra execução em andamento');
    commit;
    return;
  end if;

  insert into public.job_runs (job, status) values (p_job, 'running') returning id into v_run;
  commit;  -- o registro de início sobrevive a qualquer falha posterior

  begin
    if p_job = 'close_due_cycles' then
      v_items := private.job_close_due_cycles();
    elsif p_job = 'generate_recurrences' then
      v_items := private.generate_occurrences(private.today() + 60);
    else
      raise exception 'job desconhecido' using hint = 'unknown_job';
    end if;
    perform private.job_failpoint(p_job);
    update public.job_runs set status = 'succeeded', finished_at = clock_timestamp(), items = v_items where id = v_run;
  exception when others then
    -- a subtransação com o trabalho financeiro já foi desfeita; registra a falha sem valores
    get stacked diagnostics v_state = returned_sqlstate, v_hint = pg_exception_hint;
    update public.job_runs set status = 'failed', finished_at = clock_timestamp(),
           error = v_state || coalesce(' ' || nullif(v_hint, ''), '')
     where id = v_run;
  end;
  commit;
  perform pg_catalog.pg_advisory_unlock(pg_catalog.hashtext('fluvi.job.' || p_job));
end;
$$;

-- ---------------------------------------------------------------------------
-- 10. Execução
-- ---------------------------------------------------------------------------
revoke execute on all functions in schema private from public, anon, authenticated;
revoke execute on procedure private.run_job(text) from public, anon, authenticated;

grant execute on function
  private.current_aal(), private.is_active_profile(uuid), private.is_admin_identity(uuid),
  private.is_admin(), private.is_financial_user(uuid),
  private.can_access_owner(uuid, public.grant_scope, public.grant_operation),
  private.is_active_member(uuid), private.shares_household_with(uuid),
  private.today(), private.month_start(date),
  private.cycle_debits(uuid), private.cycle_credits(uuid), private.cycle_amount(uuid),
  private.obligation_paid(uuid), private.credit_unapplied(uuid), private.card_debt(uuid)
to authenticated, service_role;

do $$
declare f text;
begin
  foreach f in array array[
    'create_account(uuid, uuid, text, public.account_type, date, bigint)',
    'create_card(uuid, uuid, text, int, int, bigint, public.closing_day_policy, text, text, date)',
    'update_card_rules(uuid, uuid, int, int, public.closing_day_policy, bigint)',
    'create_transaction(uuid, uuid, public.txn_type, uuid, bigint, text, uuid, date, date, text)',
    'create_card_purchase(uuid, uuid, bigint, int, text, uuid, date, date, text)',
    'confirm_billing_cycle(uuid, uuid, date, date, bigint)',
    'create_obligation(uuid, uuid, public.obligation_type, text, uuid, bigint, date, date)',
    'adjust_obligation(uuid, uuid, bigint, text)',
    'cancel_obligation(uuid, uuid, text)',
    'settle_obligation(uuid, uuid, uuid, bigint, date)',
    'refund_transaction(uuid, uuid, bigint, date, text)',
    'transfer_funds(uuid, uuid, uuid, bigint, date, text)',
    'void_transaction(uuid, uuid, text)',
    'reverse_transaction(uuid, uuid, date, text)',
    'adjust_installments(uuid, uuid, bigint, int, text)',
    'create_recurrence_rule(uuid, uuid, public.obligation_type, text, uuid, bigint, public.recurrence_frequency, int, date, int, date)',
    'set_recurrence_status(uuid, uuid, public.recurrence_status)',
    'update_recurrence_amount(uuid, uuid, bigint, text)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 11. Agendamento (pg_cron): fechamento de ciclos e recorrências (horários em UTC)
-- ---------------------------------------------------------------------------
create extension if not exists pg_cron;
select cron.schedule('fluvi-close-due-cycles', '10 3 * * *', $$call private.run_job('close_due_cycles')$$);
select cron.schedule('fluvi-generate-recurrences', '20 3 * * *', $$call private.run_job('generate_recurrences')$$);
