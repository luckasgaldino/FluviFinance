-- Remodelagem v2.2 — R2: a FAMÍLIA é a única titular dos dados financeiros (§2, §6.2–6.3).
--
-- * households / household_members passam a ser a família e seus membros (nome físico mantido).
-- * owner_user_id → family_id em todas as tabelas financeiras (transfers: from_/to_family_id).
--   Dados existentes (somente fictícios — confirmado em 15/10/2026) migram 1:1: cada antigo
--   titular vira uma família própria "Família de <nome>", com ele como membro ativo.
--   Reversão possível enquanto cada família tiver um membro (ver docs/remodelagem/etapa-0-plano.md).
-- * Acesso: membro ativo de família ativa vê e registra tudo da família (sem permissão por
--   pessoa). private.can_access_family(família, escopo, operação) substitui can_access_owner;
--   o escopo é ignorado e a operação ('read' × escrita) é o ponto onde a R3 exigirá o desbloqueio.
-- * data_grants deixa de conceder acesso; a tabela e o histórico permanecem (sem DROP).
-- * Funções são recriadas a partir das definições vigentes, só com a troca de nomes
--   (owner_user_id → family_id, p_owner → p_family); as que mudam de assinatura são recriadas.
-- * Compras parceladas: 1 a 36 parcelas (FF-05).

-- ---------------------------------------------------------------------------
-- 1. Regra de acesso por família
-- ---------------------------------------------------------------------------
create function private.can_access_family(
  p_family    uuid,
  p_scope     public.grant_scope,
  p_operation public.grant_operation
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select auth.uid() is not null
     and p_family is not null
     and private.is_financial_user(auth.uid())
     and exists (
       select 1
         from public.household_members m
         join public.households h on h.id = m.household_id and h.active
        where m.household_id = p_family
          and m.user_id = auth.uid()
          and m.status = 'active'
     );
$$;
grant execute on function private.can_access_family(uuid, public.grant_scope, public.grant_operation)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. Dados: titular (usuário) → família, renomeação das colunas e chaves
-- ---------------------------------------------------------------------------
do $$
declare
  v_tables text[] := array[
    'billing_cycles', 'card_credits', 'card_purchases', 'categories', 'credit_applications', 'credit_cards',
    'cycle_assignment_reviews', 'cycle_charges', 'cycle_discrepancies', 'financial_accounts',
    'financial_operations', 'installments', 'ledger_entries', 'obligations', 'payments',
    'recurrence_occurrences', 'recurrence_rules', 'refunds', 'transactions'];
  t text;
  r record;
begin
  -- 2.1 uma família por antigo titular
  create temp table _owner_family (
    user_id   uuid primary key,
    family_id uuid not null default gen_random_uuid()
  ) on commit drop;
  foreach t in array v_tables loop
    execute format('insert into _owner_family (user_id) select distinct owner_user_id from public.%I
                     where owner_user_id is not null on conflict do nothing', t);
  end loop;
  insert into _owner_family (user_id)
    select from_owner_user_id from public.transfers union select to_owner_user_id from public.transfers
  on conflict do nothing;

  insert into public.households (id, name, created_by)
    select m.family_id, left('Família de ' || p.display_name, 80), m.user_id
      from _owner_family m join public.profiles p on p.user_id = m.user_id;
  insert into public.household_members (household_id, user_id, status)
    select family_id, user_id, 'active' from _owner_family;

  -- 2.2 chaves estrangeiras que envolvem o titular: guardar, remover, recriar depois
  create temp table _fk on commit drop as
    select c.conrelid::regclass as tbl, c.conname::text as conname, pg_get_constraintdef(c.oid) as def
      from pg_constraint c
     where c.contype = 'f'
       and c.connamespace = 'public'::regnamespace
       and c.conrelid <> 'public.data_grants'::regclass
       and (exists (select 1 from unnest(c.conkey) k
                      join pg_attribute a on a.attrelid = c.conrelid and a.attnum = k
                     where a.attname in ('owner_user_id', 'from_owner_user_id', 'to_owner_user_id'))
         or exists (select 1 from unnest(c.confkey) k
                      join pg_attribute a on a.attrelid = c.confrelid and a.attnum = k
                     where a.attname = 'owner_user_id'));
  for r in select * from _fk loop
    execute format('alter table %s drop constraint %I', r.tbl, r.conname);
  end loop;

  -- 2.3 valores e nomes (guardas de somente-acréscimo suspensas só nesta migração)
  foreach t in array v_tables loop
    execute format('alter table public.%I disable trigger user', t);
    execute format('update public.%I x set owner_user_id = m.family_id from _owner_family m
                     where x.owner_user_id = m.user_id', t);
    execute format('alter table public.%I enable trigger user', t);
    execute format('alter table public.%I rename column owner_user_id to family_id', t);
  end loop;
  alter table public.transfers disable trigger user;
  update public.transfers x set from_owner_user_id = m.family_id from _owner_family m where x.from_owner_user_id = m.user_id;
  update public.transfers x set to_owner_user_id = m.family_id from _owner_family m where x.to_owner_user_id = m.user_id;
  alter table public.transfers enable trigger user;
  alter table public.transfers rename column from_owner_user_id to from_family_id;
  alter table public.transfers rename column to_owner_user_id to to_family_id;

  -- 2.4 chaves de volta; a família não é apagada em cascata (histórico financeiro preservado)
  for r in select * from _fk loop
    execute format('alter table %s add constraint %I %s', r.tbl, replace(r.conname, 'owner_user_id', 'family_id'),
      regexp_replace(replace(r.def, 'owner_user_id', 'family_id'),
        'REFERENCES (public\.)?profiles\(user_id\)( ON DELETE CASCADE)?', 'REFERENCES public.households(id) ON DELETE RESTRICT'));
  end loop;

  -- 2.5 nomes de restrições e índices acompanham a coluna
  for r in select c.conrelid::regclass as tbl, c.conname::text as conname
             from pg_constraint c
            where c.connamespace = 'public'::regnamespace and c.conname ~ 'owner'
              and c.conrelid <> 'public.data_grants'::regclass loop
    execute format('alter table %s rename constraint %I to %I', r.tbl, r.conname, replace(r.conname, 'owner', 'family'));
  end loop;
  for r in select i.indexrelid::regclass::text as idx, c.relname::text as name
             from pg_index i join pg_class c on c.oid = i.indexrelid
            where c.relnamespace = 'public'::regnamespace and c.relname ~ 'owner'
              and i.indrelid <> 'public.data_grants'::regclass loop
    execute format('alter index %s rename to %I', r.idx, replace(r.name, 'owner', 'family'));
  end loop;
end;
$$;


-- ---------------------------------------------------------------------------
-- 3. Views com a coluna nova (security_invoker: respeitam a RLS de quem consulta)
-- ---------------------------------------------------------------------------
drop view public.v_card_position;
drop view public.v_card_cycles;
drop view public.v_account_balances;
drop view public.v_obligations_status;
drop view public.v_purchase_net;

create view public.v_account_balances with (security_invoker = true) as
  select a.id as account_id, a.family_id, a.name, a.type, a.active,
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
  select c.id as cycle_id, c.card_id, c.family_id, c.starts_on, c.closes_on, c.due_on,
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
  select k.id as card_id, k.family_id, k.name, k.credit_limit_cents,
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
  select t.id as transaction_id, t.family_id, t.description, t.local_date, t.competence_month, t.status,
         p.total_cents as gross_cents,
         coalesce((select sum(r.amount_cents) from public.refunds r
                    where r.original_transaction_id = t.id and r.status = 'active'), 0)::bigint as refunded_cents,
         p.total_cents - coalesce((select sum(r.amount_cents) from public.refunds r
                    where r.original_transaction_id = t.id and r.status = 'active'), 0)::bigint as net_cents
    from public.transactions t join public.card_purchases p on p.transaction_id = t.id;

grant select on public.v_account_balances, public.v_obligations_status, public.v_card_cycles,
  public.v_card_position, public.v_purchase_net to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Funções (definições vigentes com a troca de nomes; geradas do catálogo)
-- ---------------------------------------------------------------------------
-- private.account_guard
CREATE OR REPLACE FUNCTION private.account_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if (new.opening_date, new.opening_balance_cents, new.type, new.family_id)
       is distinct from (old.opening_date, old.opening_balance_cents, old.type, old.family_id)
     and exists (select 1 from public.ledger_entries e where e.account_id = old.id) then
    raise exception 'abertura, tipo e titular da conta são imutáveis após o primeiro lançamento'
      using errcode = 'check_violation';
  end if;
  return new;
end;
$function$;

-- private.account_owner
drop function private.account_owner(p_account uuid, p_scope grant_scope, p_op grant_operation);
CREATE FUNCTION private.account_family(p_account uuid, p_scope grant_scope, p_op grant_operation)
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_family uuid;
begin
  select family_id into v_family from public.financial_accounts where id = p_account;
  perform private.require_access(v_family, p_scope, p_op);
  return v_family;
end;
$function$;

-- private.apply_unapplied_credits
CREATE OR REPLACE FUNCTION private.apply_unapplied_credits(p_cycle uuid)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_room    bigint := private.cycle_amount(p_cycle);
  v_credit  record;
  v_take    bigint;
  v_applied bigint := 0;
begin
  for v_credit in
    select k.id, k.family_id, private.credit_unapplied(k.id) as unapplied
      from public.card_credits k
      join public.billing_cycles c on c.id = p_cycle and c.card_id = k.card_id
     where k.status = 'active'
     order by k.created_at, k.id
     for update of k
  loop
    exit when v_room <= 0;
    continue when v_credit.unapplied <= 0;
    v_take := least(v_room, v_credit.unapplied);
    insert into public.credit_applications (credit_id, family_id, billing_cycle_id, amount_cents)
    values (v_credit.id, v_credit.family_id, p_cycle, v_take);
    v_room := v_room - v_take;
    v_applied := v_applied + v_take;
  end loop;
  return v_applied;
end;
$function$;

-- private.check_category
drop function private.check_category(p_owner uuid, p_category uuid, p_kind category_kind);
CREATE FUNCTION private.check_category(p_family uuid, p_category uuid, p_kind category_kind)
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if not exists (
    select 1 from public.categories c
     where c.id = p_category and c.active and c.kind = p_kind
       and (c.family_id is null or c.family_id = p_family)
  ) then
    raise exception 'categoria inválida' using errcode = 'check_violation';
  end if;
end;
$function$;

-- private.close_cycle
CREATE OR REPLACE FUNCTION private.close_cycle(p_cycle uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  insert into public.obligations (family_id, type, description, competence_month, due_date,
    original_amount_cents, billing_cycle_id)
  values (v_cycle.family_id, 'card_bill',
    'Fatura ' || to_char(v_cycle.closes_on, 'MM/YYYY'),
    private.month_start(v_cycle.closes_on), v_cycle.due_on, private.cycle_amount(p_cycle), p_cycle)
  returning id into v_obl;
  update public.billing_cycles set status = 'closed', closed_at = now() where id = p_cycle;
  return v_obl;
end;
$function$;

-- private.compensate
CREATE OR REPLACE FUNCTION private.compensate(p_txn uuid, p_reason text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  insert into public.ledger_entries (transaction_id, family_id, account_id, amount_cents, kind, posted_on)
  select transaction_id, family_id, account_id, -amount_cents, 'void', posted_on
    from public.ledger_entries where transaction_id = p_txn and kind = 'normal';
  update public.transactions
     set status = 'voided', cancelled_at = now(),
         cancelled_by = coalesce(auth.uid(), '00000000-0000-0000-0000-000000000000'),
         cancel_reason = left(p_reason, 200)
   where id = p_txn;
end;
$function$;

-- private.ensure_cycle
CREATE OR REPLACE FUNCTION private.ensure_cycle(p_card uuid, p_date date)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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

  insert into public.billing_cycles (card_id, family_id, starts_on, closes_on, due_on, rule_revision)
  values (p_card, v_card.family_id, v_start, v_close, v_due, v_card.rule_revision)
  returning id into v_id;
  return v_id;
end;
$function$;

-- private.fin_record
drop function private.fin_record(p_owner uuid, p_op uuid, p_kind text, p_payload jsonb, p_result jsonb);
CREATE FUNCTION private.fin_record(p_family uuid, p_op uuid, p_kind text, p_payload jsonb, p_result jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  insert into public.financial_operations (family_id, client_operation_id, kind, payload_hash, result)
  values (p_family, p_op, p_kind, private.row_digest(p_payload), p_result);
  return p_result;
end;
$function$;

-- private.fin_replay
drop function private.fin_replay(p_owner uuid, p_op uuid, p_kind text, p_payload jsonb);
CREATE FUNCTION private.fin_replay(p_family uuid, p_op uuid, p_kind text, p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v public.financial_operations;
begin
  if p_op is null then
    raise exception 'client_operation_id obrigatório' using errcode = 'invalid_parameter_value';
  end if;
  select * into v from public.financial_operations
   where family_id = p_family and client_operation_id = p_op;
  if not found then return null; end if;
  if v.kind <> p_kind or v.payload_hash <> private.row_digest(p_payload) then
    raise exception 'client_operation_id já usado com outro conteúdo' using errcode = 'unique_violation';
  end if;
  return v.result;
end;
$function$;

-- private.generate_occurrences
CREATE OR REPLACE FUNCTION private.generate_occurrences(p_horizon date)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
          insert into public.recurrence_occurrences (rule_id, family_id, period_key, revision)
          values (v_rule.id, v_rule.family_id, to_char(v_month, 'YYYY-MM'), v_rule.revision)
          on conflict (rule_id, period_key) do nothing
          returning id into v_occ;
          if v_occ is not null then
            insert into public.obligations (family_id, type, description, category_id, competence_month,
              due_date, original_amount_cents, occurrence_id)
            values (v_rule.family_id, v_rule.kind, v_rule.description, v_rule.category_id, v_month,
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
$function$;

-- private.new_txn
drop function private.new_txn(p_owner uuid, p_type txn_type, p_description text, p_amount bigint, p_category uuid, p_account uuid, p_local_date date, p_competence date, p_note text, p_reverses uuid, p_op uuid);
CREATE FUNCTION private.new_txn(p_family uuid, p_type txn_type, p_description text, p_amount bigint, p_category uuid, p_account uuid, p_local_date date, p_competence date, p_note text, p_reverses uuid, p_op uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_id uuid;
begin
  insert into public.transactions (family_id, type, description, amount_cents, category_id, account_id,
    local_date, competence_month, note, reverses_transaction_id, client_operation_id, created_by)
  values (p_family, p_type, btrim(p_description), p_amount, p_category, p_account, p_local_date,
    private.month_start(coalesce(p_competence, p_local_date)), p_note, p_reverses, p_op,
    coalesce(auth.uid(), '00000000-0000-0000-0000-000000000000'))
  returning id into v_id;
  return v_id;
end;
$function$;

-- private.obligation_guard
CREATE OR REPLACE FUNCTION private.obligation_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if tg_op = 'DELETE' then
    raise exception 'obrigações não são apagadas' using errcode = 'insufficient_privilege';
  end if;
  if old.original_amount_cents <> new.original_amount_cents
     or old.type <> new.type
     or old.billing_cycle_id is distinct from new.billing_cycle_id
     or old.family_id <> new.family_id then
    raise exception 'valor, tipo e origem da obrigação são imutáveis; use ajuste'
      using errcode = 'check_violation';
  end if;
  if new.type = 'card_bill' and new.adjustments_cents <> 0 then
    raise exception 'fatura não recebe ajuste manual' using errcode = 'check_violation';
  end if;
  return new;
end;
$function$;

-- private.post
drop function private.post(p_txn uuid, p_owner uuid, p_account uuid, p_amount bigint, p_on date, p_kind entry_kind);
CREATE FUNCTION private.post(p_txn uuid, p_family uuid, p_account uuid, p_amount bigint, p_on date, p_kind entry_kind DEFAULT 'normal'::entry_kind)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
  insert into public.ledger_entries (transaction_id, family_id, account_id, amount_cents, kind, posted_on)
  values (p_txn, p_family, p_account, p_amount, p_kind, p_on);
$function$;

-- private.require_access
drop function private.require_access(p_owner uuid, p_scope grant_scope, p_op grant_operation);
CREATE FUNCTION private.require_access(p_family uuid, p_scope grant_scope, p_op grant_operation)
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if p_family is null or not private.can_access_family(p_family, p_scope, p_op) then
    raise exception 'não encontrado ou sem permissão' using errcode = 'no_data_found', hint = 'not_found_or_forbidden';
  end if;
end;
$function$;

-- private.require_cash_account
drop function private.require_cash_account(p_account uuid, p_owner uuid);
CREATE FUNCTION private.require_cash_account(p_account uuid, p_family uuid)
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if not exists (select 1 from public.financial_accounts a
                  where a.id = p_account and a.family_id = p_family and a.active and a.type <> 'credit_card') then
    raise exception 'não encontrado ou sem permissão' using errcode = 'no_data_found', hint = 'not_found_or_forbidden';
  end if;
end;
$function$;

-- public.adjust_installments
CREATE OR REPLACE FUNCTION public.adjust_installments(p_op uuid, p_purchase_transaction uuid, p_new_total_cents bigint, p_remaining_count integer, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  perform private.require_access(v_purchase.family_id, 'transactions', 'update');
  v_res := private.fin_replay(v_purchase.family_id, p_op, 'adjust_installments', v_payload);
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
     or v_kept_n + coalesce(p_remaining_count, 0) > 36 then
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
      insert into public.installments (purchase_id, family_id, revision, sequence, amount_cents, billing_cycle_id)
      values (v_purchase.id, v_purchase.family_id, v_purchase.revision + 1, v_kept_n + v_part.seq, v_part.amount, v_cycle);
    end loop;
  end if;

  v_delta := p_new_total_cents - v_purchase.total_cents;
  if v_delta <> 0 then
    v_adj := private.new_txn(v_purchase.family_id, 'installment_adjustment',
      'Ajuste de parcelas: ' || v_txn.description, abs(v_delta), null, v_card.account_id,
      private.today(), v_txn.competence_month, left(p_reason, 500), p_purchase_transaction, null);
    perform private.post(v_adj, v_purchase.family_id, v_card.account_id, -v_delta, private.today());
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
  return private.fin_record(v_purchase.family_id, p_op, 'adjust_installments', v_payload,
    private.result(p_purchase_transaction) || jsonb_build_object('revision', v_purchase.revision + 1));
end;
$function$;

-- public.adjust_obligation
CREATE OR REPLACE FUNCTION public.adjust_obligation(p_op uuid, p_obligation uuid, p_delta_cents bigint, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_obl public.obligations;
  v_payload jsonb := jsonb_build_object('obl', p_obligation, 'delta', p_delta_cents, 'reason', p_reason);
  v_res jsonb;
begin
  select * into v_obl from public.obligations where id = p_obligation;
  perform private.require_access(v_obl.family_id, 'transactions', 'update');
  v_res := private.fin_replay(v_obl.family_id, p_op, 'adjust_obligation', v_payload);
  if v_res is not null then return v_res; end if;
  select * into v_obl from public.obligations where id = p_obligation for update;
  if v_obl.type = 'card_bill' or v_obl.status <> 'active' then
    raise exception 'obrigação não ajustável' using errcode = 'check_violation';
  end if;
  if v_obl.original_amount_cents + v_obl.adjustments_cents + p_delta_cents < private.obligation_paid(p_obligation) then
    raise exception 'ajuste deixaria o devido abaixo do já pago' using errcode = 'check_violation';
  end if;
  update public.obligations set adjustments_cents = adjustments_cents + p_delta_cents where id = p_obligation;
  return private.fin_record(v_obl.family_id, p_op, 'adjust_obligation', v_payload, private.result(p_obligation));
end;
$function$;

-- public.cancel_obligation
CREATE OR REPLACE FUNCTION public.cancel_obligation(p_op uuid, p_obligation uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_obl public.obligations;
  v_payload jsonb := jsonb_build_object('obl', p_obligation, 'reason', p_reason);
  v_res jsonb;
begin
  select * into v_obl from public.obligations where id = p_obligation;
  perform private.require_access(v_obl.family_id, 'transactions', 'cancel');
  v_res := private.fin_replay(v_obl.family_id, p_op, 'cancel_obligation', v_payload);
  if v_res is not null then return v_res; end if;
  select * into v_obl from public.obligations where id = p_obligation for update;
  if v_obl.type = 'card_bill' or v_obl.status <> 'active' or private.obligation_paid(p_obligation) > 0 then
    raise exception 'obrigação com pagamento ou fatura não é cancelada; use reversão/ajuste' using errcode = 'check_violation';
  end if;
  update public.obligations set status = 'cancelled', cancelled_at = now() where id = p_obligation;
  return private.fin_record(v_obl.family_id, p_op, 'cancel_obligation', v_payload, private.result(p_obligation));
end;
$function$;

-- public.competence_summary
drop function public.competence_summary(p_owner uuid, p_month date);
CREATE FUNCTION public.competence_summary(p_family uuid, p_month date)
 RETURNS TABLE(direct_expenses_cents bigint, card_purchases_net_cents bigint, bills_recognized_cents bigint, bills_paid_cents bigint, bills_to_pay_cents bigint, bills_future_cents bigint, recognized_total_cents bigint, receivable_forecast_cents bigint)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  with m as (select private.month_start(p_month) as month,
                    private.month_start(private.today()) as current_month),
  refunds_by_txn as (
    select r.original_transaction_id, sum(r.amount_cents) as refunded
      from public.refunds r where r.status = 'active' and r.family_id = p_family
     group by 1),
  direct as (
    select coalesce(sum(t.amount_cents - coalesce(r.refunded, 0)), 0) as v
      from public.transactions t cross join m
      left join refunds_by_txn r on r.original_transaction_id = t.id
     where t.family_id = p_family and t.type = 'expense' and t.status = 'active'
       and t.competence_month = m.month),
  card as (
    select coalesce(sum(p.total_cents - coalesce(r.refunded, 0)), 0) as v
      from public.transactions t cross join m
      join public.card_purchases p on p.transaction_id = t.id
      left join refunds_by_txn r on r.original_transaction_id = t.id
     where t.family_id = p_family and t.type = 'card_purchase' and t.status = 'active'
       and t.competence_month = m.month),
  bills as (
    select o.competence_month,
           o.original_amount_cents + o.adjustments_cents as total,
           least(private.obligation_paid(o.id), o.original_amount_cents + o.adjustments_cents) as paid
      from public.obligations o cross join m
     where o.family_id = p_family and o.type = 'bill' and o.status = 'active'
       and o.competence_month = m.month),
  recv as (
    select coalesce(sum(o.original_amount_cents + o.adjustments_cents - private.obligation_paid(o.id)), 0) as v
      from public.obligations o cross join m
     where o.family_id = p_family and o.type = 'receivable' and o.status = 'active'
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
$function$;
grant execute on function public.competence_summary(p_family uuid, p_month date) to authenticated, service_role;

-- public.confirm_billing_cycle
CREATE OR REPLACE FUNCTION public.confirm_billing_cycle(p_op uuid, p_cycle uuid, p_closes_on date, p_due_on date, p_informed_amount_cents bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  perform private.require_access(v_card.family_id, 'cards', 'update');
  v_res := private.fin_replay(v_card.family_id, p_op, 'confirm_billing_cycle', v_payload);
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
    insert into public.cycle_discrepancies (family_id, billing_cycle_id, informed_amount_cents, computed_amount_cents)
    values (v_card.family_id, p_cycle, p_informed_amount_cents, v_computed);
  end if;
  perform private.assert_card_reconciled(v_card.id);
  return private.fin_record(v_card.family_id, p_op, 'confirm_billing_cycle', v_payload,
    private.result(p_cycle) || jsonb_build_object('computed_cents', v_computed));
end;
$function$;

-- public.create_account
drop function public.create_account(p_op uuid, p_owner uuid, p_name text, p_type account_type, p_opening_date date, p_opening_balance_cents bigint);
CREATE FUNCTION public.create_account(p_op uuid, p_family uuid, p_name text, p_type account_type, p_opening_date date, p_opening_balance_cents bigint DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_payload jsonb := jsonb_build_object('name', p_name, 'type', p_type, 'date', p_opening_date, 'bal', p_opening_balance_cents);
  v_res jsonb;
  v_id  uuid;
begin
  perform private.require_access(p_family, 'accounts', 'create');
  v_res := private.fin_replay(p_family, p_op, 'create_account', v_payload);
  if v_res is not null then return v_res; end if;
  if p_type = 'credit_card' then
    raise exception 'conta de cartão é criada com o cartão' using errcode = 'check_violation';
  end if;
  insert into public.financial_accounts (family_id, name, type, opening_date, opening_balance_cents)
  values (p_family, btrim(p_name), p_type, p_opening_date, coalesce(p_opening_balance_cents, 0))
  returning id into v_id;
  return private.fin_record(p_family, p_op, 'create_account', v_payload, private.result(v_id));
end;
$function$;
grant execute on function public.create_account(p_op uuid, p_family uuid, p_name text, p_type account_type, p_opening_date date, p_opening_balance_cents bigint) to authenticated, service_role;

-- public.create_card
drop function public.create_card(p_op uuid, p_owner uuid, p_name text, p_closing_day integer, p_due_day integer, p_limit_cents bigint, p_policy closing_day_policy, p_brand text, p_last_four text, p_opening_date date);
CREATE FUNCTION public.create_card(p_op uuid, p_family uuid, p_name text, p_closing_day integer, p_due_day integer, p_limit_cents bigint DEFAULT 0, p_policy closing_day_policy DEFAULT 'current_cycle'::closing_day_policy, p_brand text DEFAULT NULL::text, p_last_four text DEFAULT NULL::text, p_opening_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_payload jsonb := jsonb_build_object('name', p_name, 'close', p_closing_day, 'due', p_due_day,
    'limit', p_limit_cents, 'policy', p_policy, 'brand', p_brand, 'four', p_last_four, 'date', p_opening_date);
  v_res jsonb;
  v_acc uuid;
  v_id  uuid;
begin
  perform private.require_access(p_family, 'cards', 'create');
  v_res := private.fin_replay(p_family, p_op, 'create_card', v_payload);
  if v_res is not null then return v_res; end if;
  insert into public.financial_accounts (family_id, name, type, opening_date, opening_balance_cents)
  values (p_family, btrim(p_name), 'credit_card', coalesce(p_opening_date, private.today()), 0)
  returning id into v_acc;
  insert into public.credit_cards (family_id, account_id, name, brand, last_four, credit_limit_cents,
    closing_day, due_day, closing_day_policy)
  values (p_family, v_acc, btrim(p_name), p_brand, p_last_four, coalesce(p_limit_cents, 0),
    p_closing_day, p_due_day, coalesce(p_policy, 'current_cycle'))
  returning id into v_id;
  return private.fin_record(p_family, p_op, 'create_card', v_payload,
    private.result(v_id) || jsonb_build_object('account_id', v_acc));
end;
$function$;
grant execute on function public.create_card(p_op uuid, p_family uuid, p_name text, p_closing_day integer, p_due_day integer, p_limit_cents bigint, p_policy closing_day_policy, p_brand text, p_last_four text, p_opening_date date) to authenticated, service_role;

-- public.create_card_purchase
CREATE OR REPLACE FUNCTION public.create_card_purchase(p_op uuid, p_card uuid, p_amount_cents bigint, p_installments integer, p_description text, p_category uuid, p_local_date date, p_competence_month date DEFAULT NULL::date, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  perform private.require_access(v_card.family_id, 'transactions', 'create');
  perform private.require_access(v_card.family_id, 'cards', 'read');
  v_res := private.fin_replay(v_card.family_id, p_op, 'create_card_purchase', v_payload);
  if v_res is not null then return v_res; end if;
  if not v_card.active then
    raise exception 'cartão inativo' using errcode = 'check_violation';
  end if;
  if p_installments is null or p_installments not between 1 and 36 then
    raise exception 'parcelas devem ser de 1 a 36' using errcode = 'check_violation';
  end if;
  perform private.check_category(v_card.family_id, p_category, 'expense');

  v_txn := private.new_txn(v_card.family_id, 'card_purchase', p_description, p_amount_cents, p_category,
    v_card.account_id, p_local_date, p_competence_month, p_note, null, p_op);
  insert into public.card_purchases (transaction_id, family_id, card_id, total_cents, installment_count)
  values (v_txn, v_card.family_id, p_card, p_amount_cents, p_installments)
  returning id into v_purchase;

  v_cycle := private.purchase_cycle(p_card, p_local_date);
  for v_part in select * from private.split_cents(p_amount_cents, p_installments) loop
    if v_part.seq > 1 then v_cycle := private.next_cycle(v_cycle); end if;
    insert into public.installments (purchase_id, family_id, revision, sequence, amount_cents, billing_cycle_id)
    values (v_purchase, v_card.family_id, 1, v_part.seq, v_part.amount, v_cycle);
  end loop;

  perform private.post(v_txn, v_card.family_id, v_card.account_id, -p_amount_cents, p_local_date);
  perform private.assert_card_reconciled(p_card);
  return private.fin_record(v_card.family_id, p_op, 'create_card_purchase', v_payload, private.result(v_txn));
end;
$function$;

-- public.create_obligation
drop function public.create_obligation(p_op uuid, p_owner uuid, p_type obligation_type, p_description text, p_category uuid, p_amount_cents bigint, p_due_date date, p_competence_month date);
CREATE FUNCTION public.create_obligation(p_op uuid, p_family uuid, p_type obligation_type, p_description text, p_category uuid, p_amount_cents bigint, p_due_date date, p_competence_month date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_payload jsonb := jsonb_build_object('type', p_type, 'desc', p_description, 'cat', p_category,
    'amt', p_amount_cents, 'due', p_due_date, 'comp', p_competence_month);
  v_res jsonb;
  v_id  uuid;
begin
  perform private.require_access(p_family, 'transactions', 'create');
  v_res := private.fin_replay(p_family, p_op, 'create_obligation', v_payload);
  if v_res is not null then return v_res; end if;
  if p_type not in ('bill', 'receivable') then
    raise exception 'faturas são criadas pelo fechamento do ciclo' using errcode = 'check_violation';
  end if;
  perform private.check_category(p_family, p_category,
    case when p_type = 'bill' then 'expense'::public.category_kind else 'income' end);
  insert into public.obligations (family_id, type, description, category_id, competence_month,
    due_date, original_amount_cents, client_operation_id)
  values (p_family, p_type, btrim(p_description), p_category,
    private.month_start(coalesce(p_competence_month, p_due_date)), p_due_date, p_amount_cents, p_op)
  returning id into v_id;
  return private.fin_record(p_family, p_op, 'create_obligation', v_payload, private.result(v_id));
end;
$function$;
grant execute on function public.create_obligation(p_op uuid, p_family uuid, p_type obligation_type, p_description text, p_category uuid, p_amount_cents bigint, p_due_date date, p_competence_month date) to authenticated, service_role;

-- public.create_recurrence_rule
drop function public.create_recurrence_rule(p_op uuid, p_owner uuid, p_kind obligation_type, p_description text, p_category uuid, p_amount_cents bigint, p_frequency recurrence_frequency, p_day_of_month integer, p_start_date date, p_month_of_year integer, p_end_date date);
CREATE FUNCTION public.create_recurrence_rule(p_op uuid, p_family uuid, p_kind obligation_type, p_description text, p_category uuid, p_amount_cents bigint, p_frequency recurrence_frequency, p_day_of_month integer, p_start_date date, p_month_of_year integer DEFAULT NULL::integer, p_end_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_payload jsonb := jsonb_build_object('kind', p_kind, 'desc', p_description, 'cat', p_category, 'amt', p_amount_cents,
    'freq', p_frequency, 'day', p_day_of_month, 'start', p_start_date, 'month', p_month_of_year, 'end', p_end_date);
  v_res jsonb;
  v_id  uuid;
begin
  perform private.require_access(p_family, 'transactions', 'create');
  v_res := private.fin_replay(p_family, p_op, 'create_recurrence_rule', v_payload);
  if v_res is not null then return v_res; end if;
  perform private.check_category(p_family, p_category,
    case when p_kind = 'bill' then 'expense'::public.category_kind else 'income' end);
  insert into public.recurrence_rules (family_id, kind, description, category_id, amount_cents, frequency,
    day_of_month, month_of_year, start_date, end_date)
  values (p_family, p_kind, btrim(p_description), p_category, p_amount_cents, p_frequency,
    p_day_of_month, p_month_of_year, p_start_date, p_end_date)
  returning id into v_id;
  return private.fin_record(p_family, p_op, 'create_recurrence_rule', v_payload, private.result(v_id));
end;
$function$;
grant execute on function public.create_recurrence_rule(p_op uuid, p_family uuid, p_kind obligation_type, p_description text, p_category uuid, p_amount_cents bigint, p_frequency recurrence_frequency, p_day_of_month integer, p_start_date date, p_month_of_year integer, p_end_date date) to authenticated, service_role;

-- public.create_transaction
drop function public.create_transaction(p_op uuid, p_owner uuid, p_type txn_type, p_account uuid, p_amount_cents bigint, p_description text, p_category uuid, p_local_date date, p_competence_month date, p_note text, p_local_time time without time zone);
CREATE FUNCTION public.create_transaction(p_op uuid, p_family uuid, p_type txn_type, p_account uuid, p_amount_cents bigint, p_description text, p_category uuid, p_local_date date, p_competence_month date DEFAULT NULL::date, p_note text DEFAULT NULL::text, p_local_time time without time zone DEFAULT NULL::time without time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_payload jsonb := jsonb_build_object('type', p_type, 'acc', p_account, 'amt', p_amount_cents,
    'desc', p_description, 'cat', p_category, 'date', p_local_date, 'comp', p_competence_month,
    'note', p_note, 'time', p_local_time);
  v_res jsonb;
  v_txn uuid;
begin
  perform private.require_access(p_family, 'transactions', 'create');
  v_res := private.fin_replay(p_family, p_op, 'create_transaction', v_payload);
  if v_res is not null then return v_res; end if;
  if p_type not in ('income', 'expense') then
    raise exception 'use a operação específica para este tipo' using errcode = 'check_violation';
  end if;
  perform private.require_cash_account(p_account, p_family);
  perform private.check_category(p_family, p_category,
    case when p_type = 'income' then 'income'::public.category_kind else 'expense' end);

  v_txn := private.new_txn(p_family, p_type, p_description, p_amount_cents, p_category, p_account,
    p_local_date, p_competence_month, p_note, null, p_op);
  if p_local_time is not null then
    update public.transactions
       set occurred_at = (p_local_date + p_local_time) at time zone timezone
     where id = v_txn;
  end if;
  perform private.post(v_txn, p_family, p_account,
    case when p_type = 'income' then p_amount_cents else -p_amount_cents end, p_local_date);
  return private.fin_record(p_family, p_op, 'create_transaction', v_payload, private.result(v_txn));
end;
$function$;
grant execute on function public.create_transaction(p_op uuid, p_family uuid, p_type txn_type, p_account uuid, p_amount_cents bigint, p_description text, p_category uuid, p_local_date date, p_competence_month date, p_note text, p_local_time time without time zone) to authenticated, service_role;

-- public.refund_transaction
CREATE OR REPLACE FUNCTION public.refund_transaction(p_op uuid, p_transaction uuid, p_amount_cents bigint, p_refunded_on date, p_description text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  perform private.require_access(v_txn.family_id, 'transactions', 'create');
  v_res := private.fin_replay(v_txn.family_id, p_op, 'refund_transaction', v_payload);
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

  v_ref := private.new_txn(v_txn.family_id, 'refund', coalesce(p_description, 'Estorno: ' || v_txn.description),
    p_amount_cents, v_txn.category_id, v_txn.account_id, p_refunded_on, v_txn.competence_month, null, p_transaction, p_op);
  perform private.post(v_ref, v_txn.family_id, v_txn.account_id, p_amount_cents, p_refunded_on);
  insert into public.refunds (family_id, original_transaction_id, refund_transaction_id, target, amount_cents, refunded_on)
  values (v_txn.family_id, p_transaction, v_ref,
    case when v_card.id is not null then 'card'::public.refund_target else 'account' end, p_amount_cents, p_refunded_on);

  if v_card.id is not null then
    insert into public.card_credits (family_id, card_id, transaction_id, amount_cents)
    values (v_txn.family_id, v_card.id, v_ref, p_amount_cents) returning id into v_credit;
    -- aplica ao ciclo aberto da data do estorno; excedente fica não aplicado (§5.6)
    v_cycle := private.first_open_cycle_from(v_card.id, p_refunded_on);
    v_take := least(private.cycle_amount(v_cycle), p_amount_cents);
    if v_take > 0 then
      insert into public.credit_applications (credit_id, family_id, billing_cycle_id, amount_cents)
      values (v_credit, v_txn.family_id, v_cycle, v_take);
    end if;
    perform private.assert_card_reconciled(v_card.id);
  end if;
  return private.fin_record(v_txn.family_id, p_op, 'refund_transaction', v_payload, private.result(v_ref));
end;
$function$;

-- public.reverse_transaction
CREATE OR REPLACE FUNCTION public.reverse_transaction(p_op uuid, p_transaction uuid, p_reversed_on date, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  perform private.require_access(v_txn.family_id, 'transactions', 'cancel');
  v_res := private.fin_replay(v_txn.family_id, p_op, 'reverse_transaction', v_payload);
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
  v_rev := private.new_txn(v_txn.family_id, 'reversal', 'Reversão: ' || v_txn.description, v_txn.amount_cents,
    null, v_txn.account_id, p_reversed_on, v_txn.competence_month, left(p_reason, 500), p_transaction, p_op);
  for v_e in select account_id, amount_cents from public.ledger_entries where transaction_id = p_transaction and kind = 'normal' loop
    perform private.post(v_rev, v_txn.family_id, v_e.account_id, -v_e.amount_cents, p_reversed_on);
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
          insert into public.credit_applications (credit_id, family_id, billing_cycle_id, amount_cents)
          values (v_credit.id, v_txn.family_id, v_app.billing_cycle_id, v_app.amount_cents - v_take);
        end if;
        v_left := v_left - v_take;
      end loop;
      if v_left > 0 then
        insert into public.cycle_charges (family_id, billing_cycle_id, credit_id, transaction_id, amount_cents)
        values (v_txn.family_id, private.first_open_cycle_from(v_credit.card_id, p_reversed_on),
                v_credit.id, v_rev, v_left);
      end if;
    end if;
  elsif v_txn.type in ('transfer_out', 'transfer_in') then
    select * into v_transfer from public.transfers
     where out_transaction_id = p_transaction or in_transaction_id = p_transaction for update;
    perform private.require_access(v_transfer.from_family_id, 'transactions', 'cancel');
    perform private.require_access(v_transfer.to_family_id, 'transactions', 'cancel');
    declare
      v_other public.transactions;
      v_rev2 uuid;
    begin
      select * into v_other from public.transactions
       where id = case when p_transaction = v_transfer.out_transaction_id
                       then v_transfer.in_transaction_id else v_transfer.out_transaction_id end for update;
      v_rev2 := private.new_txn(v_other.family_id, 'reversal', 'Reversão: ' || v_other.description,
        v_other.amount_cents, null, v_other.account_id, p_reversed_on, null, left(p_reason, 500), v_other.id, null);
      perform private.post(v_rev2, v_other.family_id, v_other.account_id,
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
  return private.fin_record(v_txn.family_id, p_op, 'reverse_transaction', v_payload, private.result(v_rev, 'reversed'));
end;
$function$;

-- public.set_recurrence_status
CREATE OR REPLACE FUNCTION public.set_recurrence_status(p_op uuid, p_rule uuid, p_status recurrence_status)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_rule public.recurrence_rules;
  v_payload jsonb := jsonb_build_object('rule', p_rule, 'status', p_status);
  v_res jsonb;
begin
  select * into v_rule from public.recurrence_rules where id = p_rule;
  perform private.require_access(v_rule.family_id, 'transactions', 'update');
  v_res := private.fin_replay(v_rule.family_id, p_op, 'set_recurrence_status', v_payload);
  if v_res is not null then return v_res; end if;
  if v_rule.status = 'cancelled' then
    raise exception 'regra cancelada não muda de estado' using errcode = 'check_violation';
  end if;
  update public.recurrence_rules set status = p_status where id = p_rule;
  return private.fin_record(v_rule.family_id, p_op, 'set_recurrence_status', v_payload, private.result(p_rule));
end;
$function$;

-- public.settle_obligation
CREATE OR REPLACE FUNCTION public.settle_obligation(p_op uuid, p_obligation uuid, p_account uuid, p_amount_cents bigint, p_paid_on date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_obl   public.obligations;
  v_card  public.credit_cards;
  v_payload jsonb := jsonb_build_object('obl', p_obligation, 'acc', p_account, 'amt', p_amount_cents, 'on', p_paid_on);
  v_res   jsonb;
  v_txn   uuid;
  v_type  public.txn_type;
begin
  select * into v_obl from public.obligations where id = p_obligation;
  perform private.require_access(v_obl.family_id, 'transactions', 'create');
  v_res := private.fin_replay(v_obl.family_id, p_op, 'settle_obligation', v_payload);
  if v_res is not null then return v_res; end if;
  perform private.require_cash_account(p_account, v_obl.family_id);

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
  v_txn := private.new_txn(v_obl.family_id, v_type, v_obl.description, p_amount_cents,
    case when v_obl.type = 'receivable' then v_obl.category_id end,
    p_account, p_paid_on, v_obl.competence_month, null, null, p_op);

  if v_obl.type = 'receivable' then
    perform private.post(v_txn, v_obl.family_id, p_account, p_amount_cents, p_paid_on);
  else
    perform private.post(v_txn, v_obl.family_id, p_account, -p_amount_cents, p_paid_on);
    if v_obl.type = 'card_bill' then
      perform private.post(v_txn, v_obl.family_id, v_card.account_id, p_amount_cents, p_paid_on);
    end if;
  end if;

  insert into public.payments (family_id, obligation_id, account_id, transaction_id, amount_cents, paid_on)
  values (v_obl.family_id, p_obligation, p_account, v_txn, p_amount_cents, p_paid_on);

  if v_card.id is not null then perform private.assert_card_reconciled(v_card.id); end if;
  return private.fin_record(v_obl.family_id, p_op, 'settle_obligation', v_payload, private.result(v_txn));
end;
$function$;

-- public.transfer_funds
CREATE OR REPLACE FUNCTION public.transfer_funds(p_op uuid, p_from_account uuid, p_to_account uuid, p_amount_cents bigint, p_executed_on date, p_description text DEFAULT 'Transferência'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  v_from := private.account_family(p_from_account, 'accounts', 'create');
  v_to   := private.account_family(p_to_account, 'accounts', 'create');
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
  insert into public.transfers (from_account_id, to_account_id, from_family_id, to_family_id,
    amount_cents, executed_on, out_transaction_id, in_transaction_id, created_by)
  values (p_from_account, p_to_account, v_from, v_to, p_amount_cents, p_executed_on, v_out, v_in, auth.uid())
  returning id into v_id;
  return private.fin_record(v_from, p_op, 'transfer_funds', v_payload, private.result(v_id));
end;
$function$;

-- public.update_card_rules
CREATE OR REPLACE FUNCTION public.update_card_rules(p_op uuid, p_card uuid, p_closing_day integer, p_due_day integer, p_policy closing_day_policy, p_limit_cents bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  perform private.require_access(v_card.family_id, 'cards', 'update');
  v_res := private.fin_replay(v_card.family_id, p_op, 'update_card_rules', v_payload);
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
    insert into public.cycle_assignment_reviews (family_id, card_id, transaction_id, billing_cycle_id,
      fact_date, cycle_starts_on, cycle_closes_on, rule_revision)
    select v_card.family_id, p_card, o.transaction_id, o.cycle_id, o.local_date, o.starts_on, o.closes_on,
           v_card.rule_revision
      from outside o
    returning transaction_id, billing_cycle_id)
  select coalesce(jsonb_agg(jsonb_build_object('transaction_id', transaction_id, 'cycle_id', billing_cycle_id)), '[]')
    into v_report from ins;

  return private.fin_record(v_card.family_id, p_op, 'update_card_rules', v_payload,
    private.result(p_card) || jsonb_build_object('rule_revision', v_card.rule_revision,
      'recalculated_cycles', coalesce(array_length(v_recalc, 1), 0), 'review_items', v_report));
end;
$function$;

-- public.update_recurrence_amount
CREATE OR REPLACE FUNCTION public.update_recurrence_amount(p_op uuid, p_rule uuid, p_amount_cents bigint, p_from_period text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_rule public.recurrence_rules;
  v_payload jsonb := jsonb_build_object('rule', p_rule, 'amt', p_amount_cents, 'from', p_from_period);
  v_res jsonb;
begin
  select * into v_rule from public.recurrence_rules where id = p_rule;
  perform private.require_access(v_rule.family_id, 'transactions', 'update');
  v_res := private.fin_replay(v_rule.family_id, p_op, 'update_recurrence_amount', v_payload);
  if v_res is not null then return v_res; end if;
  select * into v_rule from public.recurrence_rules where id = p_rule for update;
  update public.recurrence_rules set amount_cents = p_amount_cents, revision = revision + 1 where id = p_rule;
  update public.obligations o
     set adjustments_cents = p_amount_cents - o.original_amount_cents
    from public.recurrence_occurrences r
   where r.id = o.occurrence_id and r.rule_id = p_rule and r.period_key >= p_from_period
     and o.status = 'active' and private.obligation_paid(o.id) = 0;
  return private.fin_record(v_rule.family_id, p_op, 'update_recurrence_amount', v_payload,
    private.result(p_rule) || jsonb_build_object('revision', v_rule.revision + 1));
end;
$function$;

-- public.void_transaction
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
$function$;

-- ---------------------------------------------------------------------------
-- 5. Políticas de leitura: membro ativo da família
-- ---------------------------------------------------------------------------
do $$
declare
  t text;
  v_scope text;
begin
  for t, v_scope in values
    ('financial_accounts', 'accounts'), ('ledger_entries', 'accounts'),
    ('credit_cards', 'cards'), ('billing_cycles', 'cards'), ('card_credits', 'cards'),
    ('credit_applications', 'cards'), ('cycle_charges', 'cards'), ('cycle_discrepancies', 'cards'),
    ('cycle_assignment_reviews', 'cards'),
    ('transactions', 'transactions'), ('card_purchases', 'transactions'), ('installments', 'transactions'),
    ('recurrence_rules', 'transactions'), ('recurrence_occurrences', 'transactions'),
    ('obligations', 'transactions'), ('payments', 'transactions'), ('refunds', 'transactions')
  loop
    execute format('drop policy %I on public.%I', t || '_select', t);
    execute format('create policy %I on public.%I for select to authenticated
                      using (private.can_access_family(family_id, %L, ''read''))', t || '_select', t, v_scope);
  end loop;
end;
$$;

drop policy categories_select on public.categories;
create policy categories_select on public.categories for select to authenticated
  using ((family_id is null and (select private.is_financial_user(auth.uid())))
         or private.can_access_family(family_id, 'transactions', 'read'));

drop policy transfers_select on public.transfers;
create policy transfers_select on public.transfers for select to authenticated
  using (private.can_access_family(from_family_id, 'accounts', 'read')
         or private.can_access_family(to_family_id, 'accounts', 'read'));

-- ---------------------------------------------------------------------------
-- 6. Famílias do usuário; fim das permissões por pessoa
-- ---------------------------------------------------------------------------
drop function public.accessible_owners(public.grant_scope, public.grant_operation);
drop function private.can_access_owner(uuid, public.grant_scope, public.grant_operation);

-- Famílias em que o usuário é membro ativo (seleção explícita da família ativa no cliente).
create function public.my_families()
returns table (family_id uuid, name text)
language sql
stable
security definer
set search_path = ''
as $$
  select h.id, h.name
    from public.households h
    join public.household_members m on m.household_id = h.id
   where m.user_id = auth.uid()
     and m.status = 'active'
     and h.active
     and private.is_financial_user(auth.uid())
   order by h.name, h.id;
$$;
grant execute on function public.my_families() to authenticated, service_role;

-- Permissões individuais não concedem mais acesso; o histórico de data_grants é mantido.
revoke execute on function public.admin_set_data_grant(uuid, uuid, uuid, uuid, public.grant_scope,
  boolean, boolean, boolean, boolean, integer) from authenticated;

-- ---------------------------------------------------------------------------
-- 7. Execução (funções recriadas nascem com EXECUTE para PUBLIC: fechar de novo)
-- ---------------------------------------------------------------------------
revoke execute on all functions in schema private from public, anon, authenticated;
revoke execute on procedure private.run_job(text) from public, anon, authenticated;

grant execute on function
  private.current_aal(), private.is_active_profile(uuid), private.is_admin_identity(uuid),
  private.is_admin(), private.is_financial_user(uuid),
  private.can_access_family(uuid, public.grant_scope, public.grant_operation),
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
    'create_transaction(uuid, uuid, public.txn_type, uuid, bigint, text, uuid, date, date, text, time)',
    'create_obligation(uuid, uuid, public.obligation_type, text, uuid, bigint, date, date)',
    'create_recurrence_rule(uuid, uuid, public.obligation_type, text, uuid, bigint, public.recurrence_frequency, int, date, int, date)',
    'competence_summary(uuid, date)',
    'my_families()'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
