-- Fluvi — Marco B — Conformidade com a Especificação v1.2 (§20.17: C-1, C-2, C-3).
--   C-1 (§20.4): ajuste de parcelas preserva ciclos faturados, CONFIRMADOS ou liquidados;
--               parcelas novas só em ciclos abertos e estimados.
--   C-2 (§20.9): recálculo de ciclos preserva a atribuição histórica, valida lacunas e
--               relata/registra itens fora da nova janela, sem movê-los.
--   C-3 (§20.12): (re)agendamento idempotente dos jobs, com opção de criá-los desligados.

-- ---------------------------------------------------------------------------
-- C-1: ajuste de parcelas
-- ---------------------------------------------------------------------------
create function private.cycle_adjustable(p_cycle uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.billing_cycles c
                  where c.id = p_cycle and c.status = 'open' and c.date_source = 'estimated'
                    and not exists (select 1 from public.obligations o where o.billing_cycle_id = c.id));
$$;

-- Próximo ciclo apto a receber parcelas novas (pula fechados e confirmados).
create function private.next_adjustable_cycle(p_cycle uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare v uuid := private.next_cycle(p_cycle);
begin
  while not private.cycle_adjustable(v) loop
    v := private.next_cycle(v);
  end loop;
  return v;
end;
$$;

create or replace function public.adjust_installments(
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

  -- preservadas: parcelas válidas em ciclos faturados, confirmados ou liquidados (§20.4)
  select coalesce(sum(i.amount_cents), 0), count(*)
    into v_kept, v_kept_n
    from public.installments i
   where i.purchase_id = v_purchase.id and i.status = 'valid'
     and not private.cycle_adjustable(i.billing_cycle_id);
  if p_new_total_cents is null or p_new_total_cents < v_kept then
    raise exception 'novo total menor que as parcelas preservadas' using errcode = 'check_violation';
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

  -- partida: ciclo da primeira parcela elegível; senão, o próximo ciclo apto após a última parcela
  select i.billing_cycle_id into v_start
    from public.installments i
   where i.purchase_id = v_purchase.id and i.status = 'valid' and private.cycle_adjustable(i.billing_cycle_id)
   order by i.sequence limit 1;
  if v_start is null and v_rest > 0 then
    select private.next_adjustable_cycle(i.billing_cycle_id) into v_start
      from public.installments i
     where i.purchase_id = v_purchase.id and i.status = 'valid' order by i.sequence desc limit 1;
  end if;

  update public.installments i set status = 'superseded'
   where i.purchase_id = v_purchase.id and i.status = 'valid' and private.cycle_adjustable(i.billing_cycle_id);

  if v_rest > 0 then
    v_cycle := v_start;
    for v_part in select * from private.split_cents(v_rest, p_remaining_count) loop
      if v_part.seq > 1 then v_cycle := private.next_adjustable_cycle(v_cycle); end if;
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
-- C-2: recálculo com preservação, validação e relatório de consistência
-- ---------------------------------------------------------------------------
create table public.cycle_assignment_reviews (
  id               uuid primary key default gen_random_uuid(),
  owner_user_id    uuid not null,
  card_id          uuid not null references public.credit_cards (id),
  transaction_id   uuid not null references public.transactions (id),
  billing_cycle_id uuid not null references public.billing_cycles (id),
  fact_date        date not null,
  cycle_starts_on  date not null,
  cycle_closes_on  date not null,
  rule_revision    integer not null,
  created_at       timestamptz not null default now(),
  resolved_at      timestamptz
);
alter table public.cycle_assignment_reviews enable row level security;
revoke all on public.cycle_assignment_reviews from anon, authenticated;
grant select on public.cycle_assignment_reviews to authenticated;
create policy cycle_assignment_reviews_select on public.cycle_assignment_reviews for select to authenticated
  using (private.can_access_owner(owner_user_id, 'cards', 'read'));
create trigger cycle_assignment_reviews_no_delete before delete on public.cycle_assignment_reviews
  for each row execute function private.ledger_guard();

create or replace function public.update_card_rules(
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
  v_res   jsonb;
  v_c     record;
  v_prev  date;
  v_next  date;
  v_close date;
  v_recalc uuid[] := '{}'::uuid[];
  v_report jsonb;
begin
  select * into v_card from public.credit_cards where id = p_card for update;
  perform private.require_access(v_card.owner_user_id, 'cards', 'update');
  v_res := private.fin_replay(v_card.owner_user_id, p_op, 'update_card_rules', v_payload);
  if v_res is not null then return v_res; end if;

  update public.credit_cards
     set closing_day = p_closing_day, due_day = p_due_day, closing_day_policy = p_policy,
         credit_limit_cents = p_limit_cents, rule_revision = rule_revision + 1
   where id = p_card returning * into v_card;

  -- só datas de ciclos abertos, estimados e com fechamento >= hoje; nenhum item muda de ciclo
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
    v_recalc := v_recalc || v_c.id;
  end loop;

  -- validação de consistência (§20.9): datas, sem lacuna, sem sobreposição (exclusion), EQ-1
  if exists (select 1 from public.billing_cycles where card_id = p_card and (starts_on > closes_on or due_on <= closes_on)) then
    raise exception 'regra nova incompatível com ciclos existentes' using errcode = 'check_violation';
  end if;
  if exists (
    select 1 from (
      select starts_on, lag(closes_on) over (order by starts_on) as prev_close
        from public.billing_cycles where card_id = p_card) s
     where s.prev_close is not null and s.starts_on <> s.prev_close + 1
  ) then
    raise exception 'recálculo deixaria lacuna ou sobreposição entre ciclos' using errcode = 'check_violation';
  end if;
  perform private.assert_card_reconciled(p_card);

  -- relatório: compras cuja data do fato ficou fora da janela do seu ciclo (não são movidas)
  with first_inst as (
    select distinct on (p.id) p.transaction_id, i.billing_cycle_id, t.local_date
      from public.card_purchases p
      join public.installments i on i.purchase_id = p.id and i.status = 'valid'
      join public.transactions t on t.id = p.transaction_id and t.status = 'active'
     where p.card_id = p_card
     order by p.id, i.sequence),
  outside as (
    select f.transaction_id, c.id as cycle_id, f.local_date, c.starts_on, c.closes_on
      from first_inst f join public.billing_cycles c on c.id = f.billing_cycle_id
     where c.id = any (v_recalc)
       -- política next_cycle: compra no dia do fechamento anterior pertence a este ciclo
       and not (f.local_date between c.starts_on and c.closes_on)
       and not (v_card.closing_day_policy = 'next_cycle' and f.local_date = c.starts_on - 1)),
  ins as (
    insert into public.cycle_assignment_reviews (owner_user_id, card_id, transaction_id, billing_cycle_id,
      fact_date, cycle_starts_on, cycle_closes_on, rule_revision)
    select v_card.owner_user_id, p_card, o.transaction_id, o.cycle_id, o.local_date, o.starts_on, o.closes_on,
           v_card.rule_revision
      from outside o
    returning transaction_id, billing_cycle_id)
  select coalesce(jsonb_agg(jsonb_build_object('transaction_id', transaction_id, 'cycle_id', billing_cycle_id)), '[]')
    into v_report from ins;

  return private.fin_record(v_card.owner_user_id, p_op, 'update_card_rules', v_payload,
    private.result(p_card) || jsonb_build_object('rule_revision', v_card.rule_revision,
      'recalculated_cycles', coalesce(array_length(v_recalc, 1), 0), 'review_items', v_report));
end;
$$;

-- ---------------------------------------------------------------------------
-- C-3: agendamento idempotente dos jobs
-- ---------------------------------------------------------------------------
-- Remove por nome e recria; rodar várias vezes resulta numa única entrada por job.
-- p_active = false cria desligado (execução controlada após restauração, §20.12).
create function private.ensure_job_schedules(p_active boolean default true)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job record;
  v_id  bigint;
  v_n   int := 0;
begin
  for v_job in
    select * from (values
      ('fluvi-close-due-cycles', '10 3 * * *', 'call private.run_job(''close_due_cycles'')'),
      ('fluvi-generate-recurrences', '20 3 * * *', 'call private.run_job(''generate_recurrences'')')) as j(name, sched, cmd)
  loop
    perform cron.unschedule(j.jobid) from cron.job j where j.jobname = v_job.name;
    v_id := cron.schedule(v_job.name, v_job.sched, v_job.cmd);
    perform cron.alter_job(v_id, active := p_active);
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

select private.ensure_job_schedules(true);

-- ---------------------------------------------------------------------------
-- Execução
-- ---------------------------------------------------------------------------
revoke execute on function private.cycle_adjustable(uuid), private.next_adjustable_cycle(uuid),
  private.ensure_job_schedules(boolean) from public, anon, authenticated;
revoke execute on function public.adjust_installments(uuid, uuid, bigint, int, text),
  public.update_card_rules(uuid, uuid, int, int, public.closing_day_policy, bigint) from public, anon;
grant execute on function public.adjust_installments(uuid, uuid, bigint, int, text),
  public.update_card_rules(uuid, uuid, int, int, public.closing_day_policy, bigint) to authenticated;
