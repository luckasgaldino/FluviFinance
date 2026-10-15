-- Fluvi — Marco B — RPCs (1/2): auxiliares, contas, cartões, lançamentos, compras parceladas,
-- confirmação de ciclo e fechamento de ciclo.
-- Contrato comum: security definer + search_path vazio; acesso verificado para cada titular
-- e recurso (erro único not_found_or_forbidden); idempotência por client_operation_id;
-- retorno mínimo {id, status}; ordem de travas: cartão → ciclos → compra → créditos → obrigações.

-- ---------------------------------------------------------------------------
-- 1. Auxiliares internos
-- ---------------------------------------------------------------------------
create function private.check_category(p_owner uuid, p_category uuid, p_kind public.category_kind)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.categories c
     where c.id = p_category and c.active and c.kind = p_kind
       and (c.owner_user_id is null or c.owner_user_id = p_owner)
  ) then
    raise exception 'categoria inválida' using errcode = 'check_violation';
  end if;
end;
$$;

create function private.new_txn(
  p_owner uuid, p_type public.txn_type, p_description text, p_amount bigint, p_category uuid,
  p_account uuid, p_local_date date, p_competence date, p_note text, p_reverses uuid, p_op uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare v_id uuid;
begin
  insert into public.transactions (owner_user_id, type, description, amount_cents, category_id, account_id,
    local_date, competence_month, note, reverses_transaction_id, client_operation_id, created_by)
  values (p_owner, p_type, btrim(p_description), p_amount, p_category, p_account, p_local_date,
    private.month_start(coalesce(p_competence, p_local_date)), p_note, p_reverses, p_op,
    coalesce(auth.uid(), '00000000-0000-0000-0000-000000000000'))
  returning id into v_id;
  return v_id;
end;
$$;

create function private.post(p_txn uuid, p_owner uuid, p_account uuid, p_amount bigint, p_on date,
  p_kind public.entry_kind default 'normal')
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.ledger_entries (transaction_id, owner_user_id, account_id, amount_cents, kind, posted_on)
  values (p_txn, p_owner, p_account, p_amount, p_kind, p_on);
$$;

-- Compensação da anulação: espelha os lançamentos normais com a MESMA data financeira.
create function private.compensate(p_txn uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.ledger_entries (transaction_id, owner_user_id, account_id, amount_cents, kind, posted_on)
  select transaction_id, owner_user_id, account_id, -amount_cents, 'void', posted_on
    from public.ledger_entries where transaction_id = p_txn and kind = 'normal';
  update public.transactions
     set status = 'voided', cancelled_at = now(),
         cancelled_by = coalesce(auth.uid(), '00000000-0000-0000-0000-000000000000'),
         cancel_reason = left(p_reason, 200)
   where id = p_txn;
end;
$$;

create function private.require_cash_account(p_account uuid, p_owner uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.financial_accounts a
                  where a.id = p_account and a.owner_user_id = p_owner and a.active and a.type <> 'credit_card') then
    raise exception 'não encontrado ou sem permissão' using errcode = 'no_data_found', hint = 'not_found_or_forbidden';
  end if;
end;
$$;

-- Distribui centavos: quociente para todas, resto nas primeiras (MB-05).
create function private.split_cents(p_total bigint, p_n int)
returns table (seq int, amount bigint)
language sql
immutable
set search_path = ''
as $$
  select g, (p_total / p_n) + case when g <= p_total % p_n then 1 else 0 end
    from generate_series(1, p_n) g;
$$;

create function private.result(p_id uuid, p_status text default 'ok')
returns jsonb
language sql
immutable
set search_path = ''
as $$ select jsonb_build_object('id', p_id, 'status', p_status); $$;

-- ---------------------------------------------------------------------------
-- 2. Contas e cartões
-- ---------------------------------------------------------------------------
create function public.create_account(
  p_op uuid, p_owner uuid, p_name text, p_type public.account_type,
  p_opening_date date, p_opening_balance_cents bigint default 0)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_payload jsonb := jsonb_build_object('name', p_name, 'type', p_type, 'date', p_opening_date, 'bal', p_opening_balance_cents);
  v_res jsonb;
  v_id  uuid;
begin
  perform private.require_access(p_owner, 'accounts', 'create');
  v_res := private.fin_replay(p_owner, p_op, 'create_account', v_payload);
  if v_res is not null then return v_res; end if;
  if p_type = 'credit_card' then
    raise exception 'conta de cartão é criada com o cartão' using errcode = 'check_violation';
  end if;
  insert into public.financial_accounts (owner_user_id, name, type, opening_date, opening_balance_cents)
  values (p_owner, btrim(p_name), p_type, p_opening_date, coalesce(p_opening_balance_cents, 0))
  returning id into v_id;
  return private.fin_record(p_owner, p_op, 'create_account', v_payload, private.result(v_id));
end;
$$;

create function public.create_card(
  p_op uuid, p_owner uuid, p_name text, p_closing_day int, p_due_day int,
  p_limit_cents bigint default 0, p_policy public.closing_day_policy default 'current_cycle',
  p_brand text default null, p_last_four text default null, p_opening_date date default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_payload jsonb := jsonb_build_object('name', p_name, 'close', p_closing_day, 'due', p_due_day,
    'limit', p_limit_cents, 'policy', p_policy, 'brand', p_brand, 'four', p_last_four, 'date', p_opening_date);
  v_res jsonb;
  v_acc uuid;
  v_id  uuid;
begin
  perform private.require_access(p_owner, 'cards', 'create');
  v_res := private.fin_replay(p_owner, p_op, 'create_card', v_payload);
  if v_res is not null then return v_res; end if;
  insert into public.financial_accounts (owner_user_id, name, type, opening_date, opening_balance_cents)
  values (p_owner, btrim(p_name), 'credit_card', coalesce(p_opening_date, private.today()), 0)
  returning id into v_acc;
  insert into public.credit_cards (owner_user_id, account_id, name, brand, last_four, credit_limit_cents,
    closing_day, due_day, closing_day_policy)
  values (p_owner, v_acc, btrim(p_name), p_brand, p_last_four, coalesce(p_limit_cents, 0),
    p_closing_day, p_due_day, coalesce(p_policy, 'current_cycle'))
  returning id into v_id;
  return private.fin_record(p_owner, p_op, 'create_card', v_payload,
    private.result(v_id) || jsonb_build_object('account_id', v_acc));
end;
$$;

-- Mudança de dia/política (§5.4): recalcula só ciclos abertos, estimados e com fechamento ≥ hoje.
-- Itens já atribuídos permanecem no ciclo do seu mês; ciclos fechados/confirmados ficam intactos.
create function public.update_card_rules(
  p_op uuid, p_card uuid, p_closing_day int, p_due_day int,
  p_policy public.closing_day_policy, p_limit_cents bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_card    public.credit_cards;
  v_payload jsonb := jsonb_build_object('card', p_card, 'close', p_closing_day, 'due', p_due_day,
    'policy', p_policy, 'limit', p_limit_cents);
  v_res  jsonb;
  v_c    record;
  v_prev date;
  v_next date;
  v_close date;
begin
  select * into v_card from public.credit_cards where id = p_card for update;
  perform private.require_access(v_card.owner_user_id, 'cards', 'update');
  v_res := private.fin_replay(v_card.owner_user_id, p_op, 'update_card_rules', v_payload);
  if v_res is not null then return v_res; end if;

  update public.credit_cards
     set closing_day = p_closing_day, due_day = p_due_day, closing_day_policy = p_policy,
         credit_limit_cents = p_limit_cents, rule_revision = rule_revision + 1
   where id = p_card returning * into v_card;

  for v_c in
    select * from public.billing_cycles
     where card_id = p_card and status = 'open' and date_source = 'estimated' and closes_on >= private.today()
     order by closes_on
  loop
    v_prev := (select max(closes_on) from public.billing_cycles where card_id = p_card and closes_on < v_c.closes_on);
    v_next := (select min(starts_on) from public.billing_cycles where card_id = p_card and starts_on > v_c.starts_on
                 and (status = 'closed' or date_source = 'confirmed' or closes_on < private.today()));
    v_close := private.closing_in_month(v_c.closes_on, p_closing_day);
    if v_next is not null then v_close := least(v_close, v_next - 1); end if;
    update public.billing_cycles
       set starts_on = coalesce(v_prev + 1, starts_on),
           closes_on = v_close,
           due_on = (select e.due_on from private.estimated_cycle(v_close, p_closing_day, p_due_day) e),
           rule_revision = v_card.rule_revision
     where id = v_c.id;
  end loop;

  -- novas datas não podem ficar sem cobertura nem sobrepostas (verificado ao fim pela exclusion)
  if exists (select 1 from public.billing_cycles where card_id = p_card and starts_on > closes_on) then
    raise exception 'regra nova incompatível com ciclos existentes' using errcode = 'check_violation';
  end if;
  perform private.assert_card_reconciled(p_card);
  return private.fin_record(v_card.owner_user_id, p_op, 'update_card_rules', v_payload,
    private.result(p_card) || jsonb_build_object('rule_revision', v_card.rule_revision));
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Receitas e despesas diretas
-- ---------------------------------------------------------------------------
create function public.create_transaction(
  p_op uuid, p_owner uuid, p_type public.txn_type, p_account uuid, p_amount_cents bigint,
  p_description text, p_category uuid, p_local_date date,
  p_competence_month date default null, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_payload jsonb := jsonb_build_object('type', p_type, 'acc', p_account, 'amt', p_amount_cents,
    'desc', p_description, 'cat', p_category, 'date', p_local_date, 'comp', p_competence_month, 'note', p_note);
  v_res jsonb;
  v_txn uuid;
begin
  perform private.require_access(p_owner, 'transactions', 'create');
  v_res := private.fin_replay(p_owner, p_op, 'create_transaction', v_payload);
  if v_res is not null then return v_res; end if;
  if p_type not in ('income', 'expense') then
    raise exception 'use a operação específica para este tipo' using errcode = 'check_violation';
  end if;
  perform private.require_cash_account(p_account, p_owner);
  perform private.check_category(p_owner, p_category,
    case when p_type = 'income' then 'income'::public.category_kind else 'expense' end);

  v_txn := private.new_txn(p_owner, p_type, p_description, p_amount_cents, p_category, p_account,
    p_local_date, p_competence_month, p_note, null, p_op);
  perform private.post(v_txn, p_owner, p_account,
    case when p_type = 'income' then p_amount_cents else -p_amount_cents end, p_local_date);
  return private.fin_record(p_owner, p_op, 'create_transaction', v_payload, private.result(v_txn));
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Compra no cartão (parcelada ou não)
-- ---------------------------------------------------------------------------
create function public.create_card_purchase(
  p_op uuid, p_card uuid, p_amount_cents bigint, p_installments int, p_description text,
  p_category uuid, p_local_date date, p_competence_month date default null, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_card    public.credit_cards;
  v_payload jsonb := jsonb_build_object('card', p_card, 'amt', p_amount_cents, 'n', p_installments,
    'desc', p_description, 'cat', p_category, 'date', p_local_date, 'comp', p_competence_month, 'note', p_note);
  v_res      jsonb;
  v_txn      uuid;
  v_purchase uuid;
  v_cycle    uuid;
  v_part     record;
begin
  select * into v_card from public.credit_cards where id = p_card for update;
  perform private.require_access(v_card.owner_user_id, 'transactions', 'create');
  perform private.require_access(v_card.owner_user_id, 'cards', 'read');
  v_res := private.fin_replay(v_card.owner_user_id, p_op, 'create_card_purchase', v_payload);
  if v_res is not null then return v_res; end if;
  if not v_card.active then
    raise exception 'cartão inativo' using errcode = 'check_violation';
  end if;
  if p_installments is null or p_installments not between 1 and 48 then
    raise exception 'parcelas devem ser de 1 a 48' using errcode = 'check_violation';
  end if;
  perform private.check_category(v_card.owner_user_id, p_category, 'expense');

  v_txn := private.new_txn(v_card.owner_user_id, 'card_purchase', p_description, p_amount_cents, p_category,
    v_card.account_id, p_local_date, p_competence_month, p_note, null, p_op);
  insert into public.card_purchases (transaction_id, owner_user_id, card_id, total_cents, installment_count)
  values (v_txn, v_card.owner_user_id, p_card, p_amount_cents, p_installments)
  returning id into v_purchase;

  v_cycle := private.purchase_cycle(p_card, p_local_date);
  for v_part in select * from private.split_cents(p_amount_cents, p_installments) loop
    if v_part.seq > 1 then v_cycle := private.next_cycle(v_cycle); end if;
    insert into public.installments (purchase_id, owner_user_id, revision, sequence, amount_cents, billing_cycle_id)
    values (v_purchase, v_card.owner_user_id, 1, v_part.seq, v_part.amount, v_cycle);
  end loop;

  perform private.post(v_txn, v_card.owner_user_id, v_card.account_id, -p_amount_cents, p_local_date);
  perform private.assert_card_reconciled(p_card);
  return private.fin_record(v_card.owner_user_id, p_op, 'create_card_purchase', v_payload, private.result(v_txn));
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Fechamento de ciclo (usado pelo job e pelos testes)
-- ---------------------------------------------------------------------------
create function private.close_cycle(p_cycle uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cycle public.billing_cycles;
  v_obl   uuid;
begin
  select * into v_cycle from public.billing_cycles where id = p_cycle for update;
  if v_cycle.status = 'closed' then
    select id into v_obl from public.obligations where billing_cycle_id = p_cycle;
    return v_obl;  -- idempotente
  end if;
  perform private.apply_unapplied_credits(p_cycle);
  insert into public.obligations (owner_user_id, type, description, competence_month, due_date,
    original_amount_cents, billing_cycle_id)
  values (v_cycle.owner_user_id, 'card_bill',
    'Fatura ' || to_char(v_cycle.closes_on, 'MM/YYYY'),
    private.month_start(v_cycle.closes_on), v_cycle.due_on, private.cycle_amount(p_cycle), p_cycle)
  returning id into v_obl;
  update public.billing_cycles set status = 'closed', closed_at = now() where id = p_cycle;
  return v_obl;
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Confirmação de datas pelo banco (§5.3): datas reais prevalecem
-- ---------------------------------------------------------------------------
-- Desloca toda a cadeia de parcelas válidas de uma compra em ±1 ciclo (só ciclos abertos).
create function private.shift_purchase_chain(p_purchase uuid, p_delta int)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_inst   record;
  v_target uuid;
begin
  for v_inst in
    select i.id, c.card_id, c.starts_on, c.closes_on
      from public.installments i join public.billing_cycles c on c.id = i.billing_cycle_id
     where i.purchase_id = p_purchase and i.status = 'valid'
     order by i.sequence * p_delta desc
  loop
    if p_delta > 0 then
      v_target := private.ensure_cycle(v_inst.card_id, v_inst.closes_on + 1);
    else
      v_target := private.ensure_cycle(v_inst.card_id, v_inst.starts_on - 1);
    end if;
    update public.installments set billing_cycle_id = v_target where id = v_inst.id;  -- gatilho barra ciclo fechado
  end loop;
end;
$$;

create function public.confirm_billing_cycle(
  p_op uuid, p_cycle uuid, p_closes_on date, p_due_on date, p_informed_amount_cents bigint default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cycle   public.billing_cycles;
  v_card    public.credit_cards;
  v_next    public.billing_cycles;
  v_payload jsonb := jsonb_build_object('cycle', p_cycle, 'close', p_closes_on, 'due', p_due_on, 'informed', p_informed_amount_cents);
  v_res     jsonb;
  v_p       record;
  v_computed bigint;
begin
  select * into v_cycle from public.billing_cycles where id = p_cycle;
  select * into v_card from public.credit_cards where id = v_cycle.card_id for update;
  perform private.require_access(v_card.owner_user_id, 'cards', 'update');
  v_res := private.fin_replay(v_card.owner_user_id, p_op, 'confirm_billing_cycle', v_payload);
  if v_res is not null then return v_res; end if;
  select * into v_cycle from public.billing_cycles where id = p_cycle for update;
  if v_cycle.status <> 'open' or v_cycle.date_source = 'confirmed' then
    raise exception 'só ciclo aberto e ainda estimado pode ser confirmado' using errcode = 'check_violation';
  end if;
  if p_closes_on < v_cycle.starts_on or p_due_on <= p_closes_on then
    raise exception 'datas confirmadas inválidas' using errcode = 'check_violation';
  end if;
  select * into v_next from public.billing_cycles where card_id = v_card.id and starts_on = v_cycle.closes_on + 1;

  if p_closes_on < v_cycle.closes_on then
    -- fechamento antecipado: compras cuja 1ª parcela caiu na janela removida vão para o ciclo seguinte
    for v_p in
      select distinct p.id
        from public.installments i
        join public.card_purchases p on p.id = i.purchase_id
        join public.transactions t on t.id = p.transaction_id
       where i.billing_cycle_id = p_cycle and i.status = 'valid' and i.sequence = (
               select min(i2.sequence) from public.installments i2 where i2.purchase_id = p.id and i2.status = 'valid')
         and t.local_date > p_closes_on
    loop
      perform private.shift_purchase_chain(v_p.id, 1);
    end loop;
    if v_next.id is not null then
      update public.billing_cycles set starts_on = p_closes_on + 1 where id = v_next.id;
    end if;
  elsif p_closes_on > v_cycle.closes_on and v_next.id is not null then
    -- fechamento postergado: primeiro as datas (este ciclo passa a conter a janela nova),
    -- depois compras do ciclo seguinte com data ≤ novo fechamento voltam um ciclo
    if v_next.status <> 'open' or v_next.date_source = 'confirmed' or v_next.closes_on <= p_closes_on then
      raise exception 'confirmação incompatível com o ciclo seguinte' using errcode = 'check_violation';
    end if;
    update public.billing_cycles set closes_on = p_closes_on where id = p_cycle;
    update public.billing_cycles set starts_on = p_closes_on + 1 where id = v_next.id;
    for v_p in
      select distinct p.id
        from public.installments i
        join public.card_purchases p on p.id = i.purchase_id
        join public.transactions t on t.id = p.transaction_id
       where i.billing_cycle_id = v_next.id and i.status = 'valid' and i.sequence = (
               select min(i2.sequence) from public.installments i2 where i2.purchase_id = p.id and i2.status = 'valid')
         and t.local_date <= p_closes_on
    loop
      perform private.shift_purchase_chain(v_p.id, -1);
    end loop;
  end if;

  update public.billing_cycles
     set closes_on = p_closes_on, due_on = p_due_on, date_source = 'confirmed',
         confirmed_at = now(), confirmed_by = auth.uid()
   where id = p_cycle;

  -- valor informado pelo banco é comparado; divergência é registrada, nunca compensada (MB-18)
  v_computed := private.cycle_amount(p_cycle);
  if p_informed_amount_cents is not null and p_informed_amount_cents <> v_computed then
    insert into public.cycle_discrepancies (owner_user_id, billing_cycle_id, informed_amount_cents, computed_amount_cents)
    values (v_card.owner_user_id, p_cycle, p_informed_amount_cents, v_computed);
  end if;
  perform private.assert_card_reconciled(v_card.id);
  return private.fin_record(v_card.owner_user_id, p_op, 'confirm_billing_cycle', v_payload,
    private.result(p_cycle) || jsonb_build_object('computed_cents', v_computed));
end;
$$;
