-- Fluvi — Marco B — Funções de domínio: tempo, acesso, idempotência, ciclos, conciliação,
-- saldo bitemporal, competência e views (security_invoker).

-- ---------------------------------------------------------------------------
-- 1. Tempo de negócio e acesso
-- ---------------------------------------------------------------------------
-- "Hoje" em America/Sao_Paulo. fluvi.today só pode ser definido em sessão SQL direta
-- (testes e jobs); a API (PostgREST) não permite definir parâmetros arbitrários.
create function private.today()
returns date
language sql
stable
set search_path = ''
as $$
  select coalesce(nullif(current_setting('fluvi.today', true), '')::date,
                  (now() at time zone 'America/Sao_Paulo')::date);
$$;

create function private.month_start(p_date date)
returns date
language sql
immutable
set search_path = ''
as $$ select date_trunc('month', p_date)::date; $$;

-- Mesma resposta para "não existe" e "sem permissão" (INV-P6).
create function private.require_access(p_owner uuid, p_scope public.grant_scope, p_op public.grant_operation)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if p_owner is null or not private.can_access_owner(p_owner, p_scope, p_op) then
    raise exception 'não encontrado ou sem permissão' using errcode = 'no_data_found', hint = 'not_found_or_forbidden';
  end if;
end;
$$;

create function private.account_owner(p_account uuid, p_scope public.grant_scope, p_op public.grant_operation)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v_owner uuid;
begin
  select owner_user_id into v_owner from public.financial_accounts where id = p_account;
  perform private.require_access(v_owner, p_scope, p_op);
  return v_owner;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Idempotência (financial_operations)
-- ---------------------------------------------------------------------------
create function private.fin_replay(p_owner uuid, p_op uuid, p_kind text, p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v public.financial_operations;
begin
  if p_op is null then
    raise exception 'client_operation_id obrigatório' using errcode = 'invalid_parameter_value';
  end if;
  select * into v from public.financial_operations
   where owner_user_id = p_owner and client_operation_id = p_op;
  if not found then return null; end if;
  if v.kind <> p_kind or v.payload_hash <> private.row_digest(p_payload) then
    raise exception 'client_operation_id já usado com outro conteúdo' using errcode = 'unique_violation';
  end if;
  return v.result;
end;
$$;

create function private.fin_record(p_owner uuid, p_op uuid, p_kind text, p_payload jsonb, p_result jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.financial_operations (owner_user_id, client_operation_id, kind, payload_hash, result)
  values (p_owner, p_op, p_kind, private.row_digest(p_payload), p_result);
  return p_result;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Regra de ciclos (§5.2, MB-04 revisada)
-- ---------------------------------------------------------------------------
create function private.clamp_date(p_year int, p_month int, p_day int)
returns date
language sql
immutable
set search_path = ''
as $$
  select make_date(p_year, p_month,
    least(p_day, extract(day from (make_date(p_year, p_month, 1) + interval '1 month - 1 day'))::int));
$$;

create function private.closing_in_month(p_any date, p_closing_day int)
returns date
language sql
immutable
set search_path = ''
as $$
  select private.clamp_date(extract(year from p_any)::int, extract(month from p_any)::int, p_closing_day);
$$;

-- Ciclo estimado que contém p_date: (fechamento anterior + 1, fechamento) e vencimento.
create function private.estimated_cycle(p_date date, p_closing_day int, p_due_day int,
  out starts_on date, out closes_on date, out due_on date)
language plpgsql
immutable
set search_path = ''
as $$
declare v_due date;
begin
  closes_on := private.closing_in_month(p_date, p_closing_day);
  if p_date > closes_on then
    closes_on := private.closing_in_month((p_date + interval '1 month')::date, p_closing_day);
  end if;
  starts_on := private.closing_in_month((closes_on - interval '1 month')::date, p_closing_day) + 1;
  v_due := private.clamp_date(extract(year from closes_on)::int, extract(month from closes_on)::int, p_due_day);
  if v_due <= closes_on then
    v_due := private.clamp_date(extract(year from (closes_on + interval '1 month'))::int,
                                extract(month from (closes_on + interval '1 month'))::int, p_due_day);
  end if;
  due_on := v_due;
end;
$$;

-- Garante o ciclo materializado que contém p_date (respeitando ciclos vizinhos já existentes,
-- inclusive confirmados). Chamar com o cartão travado (FOR UPDATE).
create function private.ensure_cycle(p_card uuid, p_date date)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_card  public.credit_cards;
  v_id    uuid;
  v_est   record;
  v_start date;
  v_close date;
  v_due   date;
begin
  select id into v_id from public.billing_cycles
   where card_id = p_card and p_date between starts_on and closes_on;
  if found then return v_id; end if;

  select * into v_card from public.credit_cards where id = p_card;
  select * into v_est from private.estimated_cycle(p_date, v_card.closing_day, v_card.due_day);
  v_start := greatest(v_est.starts_on,
    coalesce((select max(closes_on) + 1 from public.billing_cycles where card_id = p_card and closes_on < p_date),
             v_est.starts_on));
  v_close := least(v_est.closes_on,
    coalesce((select min(starts_on) - 1 from public.billing_cycles where card_id = p_card and starts_on > p_date),
             v_est.closes_on));
  v_due := (select e.due_on from private.estimated_cycle(v_close, v_card.closing_day, v_card.due_day) e);

  insert into public.billing_cycles (card_id, owner_user_id, starts_on, closes_on, due_on, rule_revision)
  values (p_card, v_card.owner_user_id, v_start, v_close, v_due, v_card.rule_revision)
  returning id into v_id;
  return v_id;
end;
$$;

-- Primeiro ciclo de uma compra feita em p_date, conforme a política do cartão.
create function private.purchase_cycle(p_card uuid, p_date date)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cycle uuid := private.ensure_cycle(p_card, p_date);
  v_close date;
  v_policy public.closing_day_policy;
begin
  select closes_on into v_close from public.billing_cycles where id = v_cycle;
  select closing_day_policy into v_policy from public.credit_cards where id = p_card;
  if p_date = v_close and v_policy = 'next_cycle' then
    return private.ensure_cycle(p_card, p_date + 1);
  end if;
  return v_cycle;
end;
$$;

create function private.next_cycle(p_cycle uuid)
returns uuid
language sql
security definer
set search_path = ''
as $$
  select private.ensure_cycle(c.card_id, c.closes_on + 1) from public.billing_cycles c where c.id = p_cycle;
$$;

-- ---------------------------------------------------------------------------
-- 4. Valor de ciclo, créditos e conciliação EQ-1 (§17.1)
-- ---------------------------------------------------------------------------
create function private.cycle_debits(p_cycle uuid)
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select sum(amount_cents) from public.installments
                    where billing_cycle_id = p_cycle and status = 'valid'), 0)
       + coalesce((select sum(amount_cents) from public.cycle_charges where billing_cycle_id = p_cycle), 0);
$$;

create function private.cycle_credits(p_cycle uuid)
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(sum(amount_cents), 0)::bigint from public.credit_applications
   where billing_cycle_id = p_cycle and status = 'active';
$$;

create function private.cycle_amount(p_cycle uuid)
returns bigint
language sql
stable
security definer
set search_path = ''
as $$ select private.cycle_debits(p_cycle) - private.cycle_credits(p_cycle); $$;

create function private.obligation_paid(p_obligation uuid)
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(sum(amount_cents), 0)::bigint from public.payments
   where obligation_id = p_obligation and status = 'active';
$$;

create function private.credit_unapplied(p_credit uuid)
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select k.amount_cents - k.absorbed_unapplied_cents
       - coalesce((select sum(a.amount_cents) from public.credit_applications a
                    where a.credit_id = k.id and a.status = 'active'), 0)
    from public.card_credits k where k.id = p_credit;
$$;

-- Aplica créditos não aplicados (mais antigos primeiro) a um ciclo aberto, até zerar seus débitos.
create function private.apply_unapplied_credits(p_cycle uuid)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_room    bigint := private.cycle_amount(p_cycle);
  v_credit  record;
  v_take    bigint;
  v_applied bigint := 0;
begin
  for v_credit in
    select k.id, k.owner_user_id, private.credit_unapplied(k.id) as unapplied
      from public.card_credits k
      join public.billing_cycles c on c.id = p_cycle and c.card_id = k.card_id
     where k.status = 'active'
     order by k.created_at, k.id
     for update of k
  loop
    exit when v_room <= 0;
    continue when v_credit.unapplied <= 0;
    v_take := least(v_room, v_credit.unapplied);
    insert into public.credit_applications (credit_id, owner_user_id, billing_cycle_id, amount_cents)
    values (v_credit.id, v_credit.owner_user_id, p_cycle, v_take);
    v_room := v_room - v_take;
    v_applied := v_applied + v_take;
  end loop;
  return v_applied;
end;
$$;

create function private.card_reconciliation(p_card uuid,
  out ledger_debt_cents bigint, out decomposed_cents bigint, out difference_cents bigint,
  out closed_remaining_cents bigint, out open_and_future_cents bigint, out unapplied_cents bigint)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v_account uuid;
begin
  select account_id into v_account from public.credit_cards where id = p_card;
  ledger_debt_cents := -coalesce((select sum(amount_cents) from public.ledger_entries where account_id = v_account), 0);
  closed_remaining_cents := coalesce((
    select sum(private.cycle_amount(c.id) - coalesce(private.obligation_paid(o.id), 0))
      from public.billing_cycles c left join public.obligations o on o.billing_cycle_id = c.id
     where c.card_id = p_card and c.status = 'closed'), 0);
  open_and_future_cents := coalesce((
    select sum(private.cycle_amount(c.id)) from public.billing_cycles c
     where c.card_id = p_card and c.status = 'open'), 0);
  unapplied_cents := coalesce((
    select sum(private.credit_unapplied(k.id)) from public.card_credits k where k.card_id = p_card), 0);
  decomposed_cents := closed_remaining_cents + open_and_future_cents - unapplied_cents;
  difference_cents := ledger_debt_cents - decomposed_cents;
end;
$$;

-- Dívida do cartão pelo razão (exposta na posição do cartão ao escopo cards; MB-13).
create function private.card_debt(p_card uuid)
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select -coalesce(sum(e.amount_cents), 0)::bigint
    from public.credit_cards k join public.ledger_entries e on e.account_id = k.account_id
   where k.id = p_card;
$$;

-- Verificação usada ao fim das RPCs de cartão: qualquer divergência aborta a operação.
create function private.assert_card_reconciled(p_card uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v record;
begin
  select * into v from private.card_reconciliation(p_card);
  if v.difference_cents <> 0 then
    raise exception 'conciliação do cartão falhou (diferença %)', v.difference_cents using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.billing_cycles c where c.card_id = p_card and private.cycle_amount(c.id) < 0) then
    raise exception 'ciclo com créditos maiores que débitos' using errcode = 'check_violation';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Saldo bitemporal e competência (expostos, SECURITY INVOKER: respeitam a RLS)
-- ---------------------------------------------------------------------------
create function public.account_balance(p_account uuid, p_on date default null, p_known_at timestamptz default null)
returns bigint
language sql
stable
security invoker
set search_path = ''
as $$
  select a.opening_balance_cents + coalesce((
    select sum(e.amount_cents) from public.ledger_entries e
     where e.account_id = a.id
       and e.posted_on > a.opening_date
       and e.posted_on <= coalesce(p_on, private.today())
       -- sem instante informado = todo o conhecimento registrado (inclusive desta transação)
       and (p_known_at is null or e.recorded_at <= p_known_at)), 0)
  from public.financial_accounts a where a.id = p_account;
$$;

-- Componentes de consumo por competência (§17.6). Verificação interna; não é tela de BI.
create function public.competence_summary(p_owner uuid, p_month date)
returns table (
  direct_expenses_cents     bigint,
  card_purchases_net_cents  bigint,
  bills_recognized_cents    bigint,
  bills_paid_cents          bigint,
  bills_to_pay_cents        bigint,
  bills_future_cents        bigint,
  recognized_total_cents    bigint,
  receivable_forecast_cents bigint
)
language sql
stable
security invoker
set search_path = ''
as $$
  with m as (select private.month_start(p_month) as month,
                    private.month_start(private.today()) as current_month),
  refunds_by_txn as (
    select r.original_transaction_id, sum(r.amount_cents) as refunded
      from public.refunds r where r.status = 'active' and r.owner_user_id = p_owner
     group by 1),
  direct as (
    select coalesce(sum(t.amount_cents - coalesce(r.refunded, 0)), 0) as v
      from public.transactions t cross join m
      left join refunds_by_txn r on r.original_transaction_id = t.id
     where t.owner_user_id = p_owner and t.type = 'expense' and t.status = 'active'
       and t.competence_month = m.month),
  card as (
    select coalesce(sum(p.total_cents - coalesce(r.refunded, 0)), 0) as v
      from public.transactions t cross join m
      join public.card_purchases p on p.transaction_id = t.id
      left join refunds_by_txn r on r.original_transaction_id = t.id
     where t.owner_user_id = p_owner and t.type = 'card_purchase' and t.status = 'active'
       and t.competence_month = m.month),
  bills as (
    select o.competence_month,
           o.original_amount_cents + o.adjustments_cents as total,
           least(private.obligation_paid(o.id), o.original_amount_cents + o.adjustments_cents) as paid
      from public.obligations o cross join m
     where o.owner_user_id = p_owner and o.type = 'bill' and o.status = 'active'
       and o.competence_month = m.month),
  recv as (
    select coalesce(sum(o.original_amount_cents + o.adjustments_cents - private.obligation_paid(o.id)), 0) as v
      from public.obligations o cross join m
     where o.owner_user_id = p_owner and o.type = 'receivable' and o.status = 'active'
       and o.competence_month = m.month)
  select d.v::bigint, c.v::bigint,
         case when m.month <= m.current_month then coalesce(sum(b.total), 0) else 0 end::bigint,
         coalesce(sum(b.paid), 0)::bigint,
         case when m.month <= m.current_month then coalesce(sum(b.total - b.paid), 0) else 0 end::bigint,
         case when m.month > m.current_month then coalesce(sum(b.total), 0) else 0 end::bigint,
         (d.v + c.v + case when m.month <= m.current_month then coalesce(sum(b.total), 0) else 0 end)::bigint,
         r.v::bigint
    from m, direct d, card c, recv r left join bills b on true
   group by m.month, m.current_month, d.v, c.v, r.v;
$$;

-- ---------------------------------------------------------------------------
-- 6. Views (security_invoker: respeitam a RLS de quem consulta)
-- ---------------------------------------------------------------------------
create view public.v_account_balances with (security_invoker = true) as
  select a.id as account_id, a.owner_user_id, a.name, a.type, a.active,
         public.account_balance(a.id) as balance_cents
    from public.financial_accounts a;

create view public.v_obligations_status with (security_invoker = true) as
  select o.*,
         o.original_amount_cents + o.adjustments_cents as total_cents,
         private.obligation_paid(o.id) as paid_cents,
         o.original_amount_cents + o.adjustments_cents - private.obligation_paid(o.id) as remaining_cents,
         case when o.status = 'cancelled' then 'cancelled'
              when private.obligation_paid(o.id) = 0 and o.original_amount_cents + o.adjustments_cents > 0 then 'open'
              when o.original_amount_cents + o.adjustments_cents - private.obligation_paid(o.id) > 0 then 'partial'
              else 'paid' end as settlement_status,
         (o.status = 'active'
          and o.original_amount_cents + o.adjustments_cents - private.obligation_paid(o.id) > 0
          and o.due_date < private.today()) as is_overdue
    from public.obligations o;

create view public.v_card_cycles with (security_invoker = true) as
  select c.id as cycle_id, c.card_id, c.owner_user_id, c.starts_on, c.closes_on, c.due_on,
         c.status, c.date_source,
         private.cycle_debits(c.id) as debits_cents,
         private.cycle_credits(c.id) as credits_cents,
         private.cycle_amount(c.id) as amount_cents,
         o.id as obligation_id,
         coalesce(private.obligation_paid(o.id), 0) as paid_cents,
         case when c.status = 'closed' then private.cycle_amount(c.id) - coalesce(private.obligation_paid(o.id), 0) end as remaining_cents,
         (c.status = 'closed' and private.cycle_amount(c.id) - coalesce(private.obligation_paid(o.id), 0) = 0) as is_paid
    from public.billing_cycles c
    left join public.obligations o on o.billing_cycle_id = c.id;

create view public.v_card_position with (security_invoker = true) as
  select k.id as card_id, k.owner_user_id, k.name, k.credit_limit_cents,
         private.card_debt(k.id) as debt_total_cents,
         (select coalesce(sum(v.remaining_cents), 0)::bigint from public.v_card_cycles v
           where v.card_id = k.id and v.status = 'closed') as closed_remaining_cents,
         (select v.amount_cents from public.v_card_cycles v
           where v.card_id = k.id and v.status = 'open' and private.today() between v.starts_on and v.closes_on) as open_preview_cents,
         (select coalesce(sum(v.amount_cents), 0)::bigint from public.v_card_cycles v
           where v.card_id = k.id and v.status = 'open' and v.starts_on > private.today()) as future_installments_cents,
         (select coalesce(sum(private.credit_unapplied(c.id)), 0)::bigint from public.card_credits c where c.card_id = k.id) as unapplied_credit_cents,
         k.credit_limit_cents - private.card_debt(k.id) as available_limit_cents
    from public.credit_cards k;

create view public.v_purchase_net with (security_invoker = true) as
  select t.id as transaction_id, t.owner_user_id, t.description, t.local_date, t.competence_month, t.status,
         p.total_cents as gross_cents,
         coalesce((select sum(r.amount_cents) from public.refunds r
                    where r.original_transaction_id = t.id and r.status = 'active'), 0)::bigint as refunded_cents,
         p.total_cents - coalesce((select sum(r.amount_cents) from public.refunds r
                    where r.original_transaction_id = t.id and r.status = 'active'), 0)::bigint as net_cents
    from public.transactions t join public.card_purchases p on p.transaction_id = t.id;

grant select on public.v_account_balances, public.v_obligations_status, public.v_card_cycles,
  public.v_card_position, public.v_purchase_net to authenticated;

-- ---------------------------------------------------------------------------
-- 7. Execução
-- ---------------------------------------------------------------------------
revoke execute on all functions in schema private from public, anon, authenticated;
revoke execute on function public.account_balance(uuid, date, timestamptz),
  public.competence_summary(uuid, date) from public, anon;
grant execute on function public.account_balance(uuid, date, timestamptz),
  public.competence_summary(uuid, date) to authenticated;

-- funções usadas por políticas e views (avaliadas como o usuário que consulta)
grant execute on function
  private.current_aal(), private.is_active_profile(uuid), private.is_admin_identity(uuid),
  private.is_admin(), private.is_financial_user(uuid),
  private.can_access_owner(uuid, public.grant_scope, public.grant_operation),
  private.is_active_member(uuid), private.shares_household_with(uuid),
  private.today(), private.month_start(date),
  private.cycle_debits(uuid), private.cycle_credits(uuid), private.cycle_amount(uuid),
  private.obligation_paid(uuid), private.credit_unapplied(uuid), private.card_debt(uuid)
to authenticated, service_role;
