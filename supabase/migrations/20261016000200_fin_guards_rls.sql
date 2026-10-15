-- Fluvi — Marco B — Guardas (gatilhos), RLS, privilégios e auditoria do núcleo financeiro.

-- ---------------------------------------------------------------------------
-- 1. Razão somente-acréscimo; recorded_at definido pelo banco (INV-L1, INV-L7)
-- ---------------------------------------------------------------------------
create function private.ledger_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.recorded_at := clock_timestamp();  -- o cliente nunca define o instante de conhecimento
    return new;
  end if;
  raise exception 'ledger_entries é somente-acréscimo' using errcode = 'insufficient_privilege';
end;
$$;

create trigger ledger_entries_insert before insert on public.ledger_entries
  for each row execute function private.ledger_guard();
create trigger ledger_entries_no_update_delete before update or delete on public.ledger_entries
  for each row execute function private.ledger_guard();

-- ---------------------------------------------------------------------------
-- 2. Ciclos fechados/confirmados e seus itens são imutáveis (INV-C4, INV-C5, INV-C9)
-- ---------------------------------------------------------------------------
create function private.cycle_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.status = 'closed' then
    raise exception 'ciclo fechado é imutável' using errcode = 'check_violation';
  end if;
  if new.status = 'open' and old.status = 'closed' then
    raise exception 'ciclo fechado não reabre' using errcode = 'check_violation';
  end if;
  if old.date_source = 'confirmed'
     and (new.starts_on, new.closes_on, new.due_on) is distinct from (old.starts_on, old.closes_on, old.due_on) then
    raise exception 'datas confirmadas pelo banco não mudam' using errcode = 'check_violation';
  end if;
  if new.date_source = 'estimated' and old.date_source = 'confirmed' then
    raise exception 'ciclo confirmado não volta a estimado' using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

create trigger billing_cycles_guard before update on public.billing_cycles
  for each row execute function private.cycle_guard();
create trigger billing_cycles_no_delete before delete on public.billing_cycles
  for each row execute function private.ledger_guard();

-- Itens (parcelas, aplicações de crédito, encargos) não entram nem mudam em ciclo fechado.
create function private.cycle_item_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_cycle uuid;
begin
  if tg_op = 'DELETE' then
    raise exception 'itens de ciclo não são apagados' using errcode = 'insufficient_privilege';
  end if;
  foreach v_cycle in array array[new.billing_cycle_id,
                                 case when tg_op = 'UPDATE' then old.billing_cycle_id end] loop
    if v_cycle is not null and exists (
      select 1 from public.billing_cycles c where c.id = v_cycle and c.status = 'closed'
    ) then
      raise exception 'item de ciclo fechado é imutável' using errcode = 'check_violation';
    end if;
  end loop;
  return new;
end;
$$;

create trigger installments_guard before insert or update or delete on public.installments
  for each row execute function private.cycle_item_guard();
create trigger credit_applications_guard before insert or update or delete on public.credit_applications
  for each row execute function private.cycle_item_guard();
create trigger cycle_charges_guard before insert or update or delete on public.cycle_charges
  for each row execute function private.cycle_item_guard();

-- Fatura: valor original congelado no fechamento (INV-C9).
create function private.obligation_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'obrigações não são apagadas' using errcode = 'insufficient_privilege';
  end if;
  if old.original_amount_cents <> new.original_amount_cents
     or old.type <> new.type
     or old.billing_cycle_id is distinct from new.billing_cycle_id
     or old.owner_user_id <> new.owner_user_id then
    raise exception 'valor, tipo e origem da obrigação são imutáveis; use ajuste'
      using errcode = 'check_violation';
  end if;
  if new.type = 'card_bill' and new.adjustments_cents <> 0 then
    raise exception 'fatura não recebe ajuste manual' using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

create trigger obligations_guard before update or delete on public.obligations
  for each row execute function private.obligation_guard();

-- Demais tabelas financeiras: sem DELETE físico.
do $$
declare t text;
begin
  foreach t in array array['transactions', 'card_purchases', 'card_credits', 'payments', 'refunds',
    'transfers', 'financial_accounts', 'credit_cards', 'recurrence_rules', 'recurrence_occurrences',
    'cycle_discrepancies', 'financial_operations'] loop
    execute format('create trigger %I before delete on public.%I for each row execute function private.ledger_guard()',
                   t || '_no_delete', t);
  end loop;
end $$;

-- Abertura imutável após o primeiro lançamento (§17.5).
create function private.account_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if (new.opening_date, new.opening_balance_cents, new.type, new.owner_user_id)
       is distinct from (old.opening_date, old.opening_balance_cents, old.type, old.owner_user_id)
     and exists (select 1 from public.ledger_entries e where e.account_id = old.id) then
    raise exception 'abertura, tipo e titular da conta são imutáveis após o primeiro lançamento'
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

create trigger financial_accounts_guard before update on public.financial_accounts
  for each row execute function private.account_guard();

-- ---------------------------------------------------------------------------
-- 3. Privilégios: leitura por RLS; nenhuma escrita direta (só RPC)
-- ---------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['categories', 'financial_accounts', 'credit_cards', 'billing_cycles',
    'transactions', 'ledger_entries', 'card_purchases', 'installments', 'card_credits',
    'credit_applications', 'cycle_charges', 'cycle_discrepancies', 'recurrence_rules',
    'recurrence_occurrences', 'obligations', 'payments', 'refunds', 'transfers',
    'financial_operations', 'job_runs'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
  foreach t in array array['categories', 'financial_accounts', 'credit_cards', 'billing_cycles',
    'transactions', 'ledger_entries', 'card_purchases', 'installments', 'card_credits',
    'credit_applications', 'cycle_charges', 'cycle_discrepancies', 'recurrence_rules',
    'recurrence_occurrences', 'obligations', 'payments', 'refunds', 'transfers', 'job_runs'] loop
    execute format('grant select on public.%I to authenticated', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Políticas de leitura por escopo (MB-13)
-- ---------------------------------------------------------------------------
create policy categories_select on public.categories for select to authenticated
  using ((owner_user_id is null and (select private.is_financial_user(auth.uid())))
         or private.can_access_owner(owner_user_id, 'transactions', 'read'));

-- accounts
create policy financial_accounts_select on public.financial_accounts for select to authenticated
  using (private.can_access_owner(owner_user_id, 'accounts', 'read'));
create policy ledger_entries_select on public.ledger_entries for select to authenticated
  using (private.can_access_owner(owner_user_id, 'accounts', 'read'));
create policy transfers_select on public.transfers for select to authenticated
  using (private.can_access_owner(from_owner_user_id, 'accounts', 'read')
         or private.can_access_owner(to_owner_user_id, 'accounts', 'read'));

-- cards
create policy credit_cards_select on public.credit_cards for select to authenticated
  using (private.can_access_owner(owner_user_id, 'cards', 'read'));
create policy billing_cycles_select on public.billing_cycles for select to authenticated
  using (private.can_access_owner(owner_user_id, 'cards', 'read'));
create policy card_credits_select on public.card_credits for select to authenticated
  using (private.can_access_owner(owner_user_id, 'cards', 'read'));
create policy credit_applications_select on public.credit_applications for select to authenticated
  using (private.can_access_owner(owner_user_id, 'cards', 'read'));
create policy cycle_charges_select on public.cycle_charges for select to authenticated
  using (private.can_access_owner(owner_user_id, 'cards', 'read'));
create policy cycle_discrepancies_select on public.cycle_discrepancies for select to authenticated
  using (private.can_access_owner(owner_user_id, 'cards', 'read'));

-- transactions
create policy transactions_select on public.transactions for select to authenticated
  using (private.can_access_owner(owner_user_id, 'transactions', 'read'));
create policy card_purchases_select on public.card_purchases for select to authenticated
  using (private.can_access_owner(owner_user_id, 'transactions', 'read'));
create policy installments_select on public.installments for select to authenticated
  using (private.can_access_owner(owner_user_id, 'transactions', 'read'));
create policy recurrence_rules_select on public.recurrence_rules for select to authenticated
  using (private.can_access_owner(owner_user_id, 'transactions', 'read'));
create policy recurrence_occurrences_select on public.recurrence_occurrences for select to authenticated
  using (private.can_access_owner(owner_user_id, 'transactions', 'read'));
create policy obligations_select on public.obligations for select to authenticated
  using (private.can_access_owner(owner_user_id, 'transactions', 'read'));
create policy payments_select on public.payments for select to authenticated
  using (private.can_access_owner(owner_user_id, 'transactions', 'read'));
create policy refunds_select on public.refunds for select to authenticated
  using (private.can_access_owner(owner_user_id, 'transactions', 'read'));

-- operação de jobs: só Admin com MFA (sem valores financeiros)
create policy job_runs_select on public.job_runs for select to authenticated
  using ((select private.is_admin()));
-- financial_operations: sem política → ninguém lê pela API

-- ---------------------------------------------------------------------------
-- 5. Auditoria (digests) das entidades financeiras
-- ---------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['financial_accounts', 'credit_cards', 'billing_cycles', 'transactions',
    'card_purchases', 'installments', 'card_credits', 'credit_applications', 'cycle_charges',
    'obligations', 'payments', 'refunds', 'transfers', 'recurrence_rules', 'cycle_discrepancies'] loop
    execute format('create trigger %I after insert or update on public.%I for each row execute function private.audit_row(%L)',
                   t || '_audit', t, 'id');
  end loop;
end $$;
