-- Fluvi — Marco B — Núcleo financeiro: tipos, tabelas, constraints, RLS e gatilhos.
-- Referência: docs/marco-b/proposta-tecnica.md (rev. 3; §17 prevalece).
-- Princípios: razão somente-acréscimo e bitemporal; escrita só por RPC; leitura por
-- private.can_access_owner (escopos accounts | cards | transactions); centavos bigint.

create extension if not exists btree_gist with schema extensions;

-- ---------------------------------------------------------------------------
-- 1. Tipos
-- ---------------------------------------------------------------------------
create type public.account_type        as enum ('checking', 'savings', 'cash', 'credit_card');
create type public.category_kind       as enum ('expense', 'income');
create type public.txn_type            as enum (
  'income', 'expense', 'card_purchase', 'card_bill_payment', 'bill_payment',
  'transfer_out', 'transfer_in', 'refund', 'reversal', 'installment_adjustment');
create type public.txn_status          as enum ('active', 'voided', 'reversed');
create type public.entry_kind          as enum ('normal', 'void');
create type public.closing_day_policy  as enum ('current_cycle', 'next_cycle');
create type public.cycle_status        as enum ('open', 'closed');
create type public.date_source         as enum ('estimated', 'confirmed');
create type public.installment_status  as enum ('valid', 'superseded');
create type public.application_status  as enum ('active', 'released');
create type public.obligation_type     as enum ('card_bill', 'bill', 'receivable');
create type public.obligation_status   as enum ('active', 'cancelled');
create type public.recurrence_frequency as enum ('monthly', 'yearly');
create type public.recurrence_status   as enum ('active', 'paused', 'cancelled');
create type public.refund_target       as enum ('card', 'account');

-- ---------------------------------------------------------------------------
-- 2. Categorias (owner null = padrão do sistema, só leitura)
-- ---------------------------------------------------------------------------
create table public.categories (
  id            uuid primary key default gen_random_uuid(),
  owner_user_id uuid references public.profiles (user_id) on delete cascade,
  parent_id     uuid references public.categories (id),
  name          text not null check (char_length(btrim(name)) between 1 and 60),
  kind          public.category_kind not null,
  active        boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create unique index categories_unique_name on public.categories
  (coalesce(owner_user_id, '00000000-0000-0000-0000-000000000000'::uuid), kind,
   coalesce(parent_id, '00000000-0000-0000-0000-000000000000'::uuid), lower(btrim(name)));

insert into public.categories (name, kind) values
  ('Moradia', 'expense'), ('Mercado', 'expense'), ('Alimentação fora', 'expense'),
  ('Transporte', 'expense'), ('Saúde', 'expense'), ('Educação', 'expense'),
  ('Lazer', 'expense'), ('Vestuário', 'expense'), ('Assinaturas', 'expense'),
  ('Contas e serviços', 'expense'), ('Impostos e taxas', 'expense'), ('Pets', 'expense'),
  ('Presentes e doações', 'expense'), ('Outros', 'expense'),
  ('Salário', 'income'), ('Renda extra', 'income'), ('Rendimentos', 'income'), ('Outros', 'income');

-- ---------------------------------------------------------------------------
-- 3. Contas
-- ---------------------------------------------------------------------------
create table public.financial_accounts (
  id                    uuid primary key default gen_random_uuid(),
  owner_user_id         uuid not null references public.profiles (user_id) on delete cascade,
  name                  text not null check (char_length(btrim(name)) between 1 and 60),
  type                  public.account_type not null,
  currency              char(3) not null default 'BRL' check (currency = 'BRL'),
  opening_date          date not null,
  opening_balance_cents bigint not null default 0,
  active                boolean not null default true,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  -- dívida pré-existente de cartão entra como compras (limitação documentada do B)
  constraint card_account_opens_at_zero check (type <> 'credit_card' or opening_balance_cents = 0),
  unique (id, owner_user_id)
);
create index financial_accounts_owner_idx on public.financial_accounts (owner_user_id);

-- ---------------------------------------------------------------------------
-- 4. Cartões e ciclos
-- ---------------------------------------------------------------------------
create table public.credit_cards (
  id                 uuid primary key default gen_random_uuid(),
  owner_user_id      uuid not null references public.profiles (user_id) on delete cascade,
  account_id         uuid not null unique,
  name               text not null check (char_length(btrim(name)) between 1 and 60),
  brand              text check (brand is null or char_length(brand) <= 30),
  last_four          char(4) check (last_four is null or last_four ~ '^[0-9]{4}$'),
  credit_limit_cents bigint not null default 0 check (credit_limit_cents >= 0),
  closing_day        smallint not null check (closing_day between 1 and 31),
  due_day            smallint not null check (due_day between 1 and 31),
  closing_day_policy public.closing_day_policy not null default 'current_cycle',
  rule_revision      integer not null default 1 check (rule_revision >= 1),
  active             boolean not null default true,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  foreign key (account_id, owner_user_id) references public.financial_accounts (id, owner_user_id),
  unique (id, owner_user_id)
);

create table public.billing_cycles (
  id            uuid primary key default gen_random_uuid(),
  card_id       uuid not null,
  owner_user_id uuid not null,
  starts_on     date not null,
  closes_on     date not null,
  due_on        date not null,
  status        public.cycle_status not null default 'open',
  date_source   public.date_source not null default 'estimated',
  rule_revision integer not null,
  closed_at     timestamptz,
  confirmed_at  timestamptz,
  confirmed_by  uuid,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  foreign key (card_id, owner_user_id) references public.credit_cards (id, owner_user_id) on delete cascade,
  check (starts_on <= closes_on and closes_on < due_on),
  unique (card_id, closes_on),
  -- ciclos do mesmo cartão nunca se sobrepõem (INV-C2); deferível para recálculos em lote
  constraint billing_cycles_no_overlap exclude using gist
    (card_id with =, daterange(starts_on, closes_on, '[]') with &&) deferrable initially deferred
);
create index billing_cycles_card_idx on public.billing_cycles (card_id, starts_on);

-- ---------------------------------------------------------------------------
-- 5. Operações e razão
-- ---------------------------------------------------------------------------
create table public.transactions (
  id                     uuid primary key default gen_random_uuid(),
  owner_user_id          uuid not null references public.profiles (user_id) on delete cascade,
  type                   public.txn_type not null,
  status                 public.txn_status not null default 'active',
  description            text not null check (char_length(btrim(description)) between 1 and 140),
  amount_cents           bigint not null check (amount_cents > 0),
  category_id            uuid references public.categories (id),
  account_id             uuid not null,
  local_date             date not null,
  occurred_at            timestamptz,
  timezone               text not null default 'America/Sao_Paulo',
  competence_month       date not null check (extract(day from competence_month) = 1),
  note                   text check (note is null or char_length(note) <= 500),
  reverses_transaction_id uuid references public.transactions (id),
  client_operation_id    uuid,
  cancelled_at           timestamptz,
  cancelled_by           uuid,
  cancel_reason          text check (cancel_reason is null or char_length(cancel_reason) <= 200),
  created_by             uuid not null,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  foreign key (account_id, owner_user_id) references public.financial_accounts (id, owner_user_id),
  unique (id, owner_user_id),
  check (type not in ('income', 'expense', 'card_purchase') or category_id is not null),
  check ((status = 'active') = (cancelled_at is null))
);
create unique index transactions_client_op_idx on public.transactions (owner_user_id, client_operation_id)
  where client_operation_id is not null;
create index transactions_owner_date_idx on public.transactions (owner_user_id, local_date);
create index transactions_competence_idx on public.transactions (owner_user_id, competence_month);

-- Razão: somente-acréscimo, bitemporal (posted_on = data financeira; recorded_at = conhecimento).
create table public.ledger_entries (
  id             bigint generated always as identity primary key,
  transaction_id uuid not null,
  owner_user_id  uuid not null,
  account_id     uuid not null,
  amount_cents   bigint not null check (amount_cents <> 0),
  kind           public.entry_kind not null default 'normal',
  posted_on      date not null,
  recorded_at    timestamptz not null default clock_timestamp(),
  foreign key (transaction_id, owner_user_id) references public.transactions (id, owner_user_id),
  -- conta do MESMO titular da operação (INV-L2)
  foreign key (account_id, owner_user_id) references public.financial_accounts (id, owner_user_id)
);
create index ledger_entries_account_idx on public.ledger_entries (account_id, posted_on, recorded_at);
create index ledger_entries_txn_idx on public.ledger_entries (transaction_id);

-- ---------------------------------------------------------------------------
-- 6. Compras, parcelas, créditos
-- ---------------------------------------------------------------------------
create table public.card_purchases (
  id                uuid primary key default gen_random_uuid(),
  transaction_id    uuid not null unique,
  owner_user_id     uuid not null,
  card_id           uuid not null,
  total_cents       bigint not null check (total_cents > 0),
  installment_count smallint not null check (installment_count between 1 and 48),
  revision          integer not null default 1 check (revision >= 1),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  foreign key (transaction_id, owner_user_id) references public.transactions (id, owner_user_id),
  foreign key (card_id, owner_user_id) references public.credit_cards (id, owner_user_id),
  unique (id, owner_user_id)
);

create table public.installments (
  id               uuid primary key default gen_random_uuid(),
  purchase_id      uuid not null,
  owner_user_id    uuid not null,
  revision         integer not null,
  sequence         smallint not null check (sequence between 1 and 48),
  amount_cents     bigint not null check (amount_cents > 0),
  billing_cycle_id uuid not null references public.billing_cycles (id),
  status           public.installment_status not null default 'valid',
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  foreign key (purchase_id, owner_user_id) references public.card_purchases (id, owner_user_id),
  unique (purchase_id, revision, sequence)
);
create index installments_cycle_idx on public.installments (billing_cycle_id) where status = 'valid';

create table public.card_credits (
  id                         uuid primary key default gen_random_uuid(),
  owner_user_id              uuid not null,
  card_id                    uuid not null,
  transaction_id             uuid not null unique,
  amount_cents               bigint not null check (amount_cents > 0),
  status                     public.txn_status not null default 'active',
  absorbed_unapplied_cents   bigint not null default 0 check (absorbed_unapplied_cents >= 0),
  created_at                 timestamptz not null default now(),
  updated_at                 timestamptz not null default now(),
  foreign key (transaction_id, owner_user_id) references public.transactions (id, owner_user_id),
  foreign key (card_id, owner_user_id) references public.credit_cards (id, owner_user_id),
  check (absorbed_unapplied_cents <= amount_cents)
);

create table public.credit_applications (
  id               uuid primary key default gen_random_uuid(),
  credit_id        uuid not null references public.card_credits (id),
  owner_user_id    uuid not null,
  billing_cycle_id uuid not null references public.billing_cycles (id),
  amount_cents     bigint not null check (amount_cents > 0),
  status           public.application_status not null default 'active',
  released_at      timestamptz,
  created_at       timestamptz not null default now(),
  check ((status = 'released') = (released_at is not null))
);
create index credit_applications_cycle_idx on public.credit_applications (billing_cycle_id) where status = 'active';

-- encargo de reversão de crédito (§17.3)
create table public.cycle_charges (
  id               uuid primary key default gen_random_uuid(),
  owner_user_id    uuid not null,
  billing_cycle_id uuid not null references public.billing_cycles (id),
  credit_id        uuid not null references public.card_credits (id),
  transaction_id   uuid not null references public.transactions (id),
  amount_cents     bigint not null check (amount_cents > 0),
  created_at       timestamptz not null default now()
);

create table public.cycle_discrepancies (
  id                    uuid primary key default gen_random_uuid(),
  owner_user_id         uuid not null,
  billing_cycle_id      uuid not null references public.billing_cycles (id),
  informed_amount_cents bigint not null check (informed_amount_cents >= 0),
  computed_amount_cents bigint not null,
  difference_cents      bigint generated always as (informed_amount_cents - computed_amount_cents) stored,
  created_at            timestamptz not null default now(),
  resolved_at           timestamptz
);

-- ---------------------------------------------------------------------------
-- 7. Recorrências, obrigações, pagamentos, estornos, transferências
-- ---------------------------------------------------------------------------
create table public.recurrence_rules (
  id            uuid primary key default gen_random_uuid(),
  owner_user_id uuid not null references public.profiles (user_id) on delete cascade,
  kind          public.obligation_type not null check (kind in ('bill', 'receivable')),
  description   text not null check (char_length(btrim(description)) between 1 and 140),
  category_id   uuid not null references public.categories (id),
  amount_cents  bigint not null check (amount_cents > 0),
  frequency     public.recurrence_frequency not null,
  day_of_month  smallint not null check (day_of_month between 1 and 31),
  month_of_year smallint check (month_of_year between 1 and 12),
  start_date    date not null,
  end_date      date,
  status        public.recurrence_status not null default 'active',
  revision      integer not null default 1,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  check ((frequency = 'yearly') = (month_of_year is not null)),
  check (end_date is null or end_date >= start_date)
);

create table public.recurrence_occurrences (
  id            uuid primary key default gen_random_uuid(),
  rule_id       uuid not null references public.recurrence_rules (id),
  owner_user_id uuid not null,
  period_key    text not null check (period_key ~ '^[0-9]{4}-[0-9]{2}$'),
  revision      integer not null,
  created_at    timestamptz not null default now(),
  unique (rule_id, period_key)
);

create table public.obligations (
  id                    uuid primary key default gen_random_uuid(),
  owner_user_id         uuid not null references public.profiles (user_id) on delete cascade,
  type                  public.obligation_type not null,
  status                public.obligation_status not null default 'active',
  description           text not null check (char_length(btrim(description)) between 1 and 140),
  category_id           uuid references public.categories (id),
  competence_month      date not null check (extract(day from competence_month) = 1),
  due_date              date not null,
  original_amount_cents bigint not null check (original_amount_cents >= 0),
  adjustments_cents     bigint not null default 0,
  billing_cycle_id      uuid unique references public.billing_cycles (id),
  occurrence_id         uuid unique references public.recurrence_occurrences (id),
  client_operation_id   uuid,
  cancelled_at          timestamptz,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  check ((type = 'card_bill') = (billing_cycle_id is not null)),
  check (type = 'card_bill' or original_amount_cents > 0),
  check (type = 'card_bill' or category_id is not null),
  check (original_amount_cents + adjustments_cents >= 0),
  check ((status = 'cancelled') = (cancelled_at is not null))
);
create unique index obligations_client_op_idx on public.obligations (owner_user_id, client_operation_id)
  where client_operation_id is not null;
create index obligations_owner_due_idx on public.obligations (owner_user_id, due_date);

create table public.payments (
  id             uuid primary key default gen_random_uuid(),
  owner_user_id  uuid not null,
  obligation_id  uuid not null references public.obligations (id),
  account_id     uuid not null,
  transaction_id uuid not null unique,
  amount_cents   bigint not null check (amount_cents > 0),
  paid_on        date not null,
  status         public.txn_status not null default 'active',
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  foreign key (transaction_id, owner_user_id) references public.transactions (id, owner_user_id),
  foreign key (account_id, owner_user_id) references public.financial_accounts (id, owner_user_id)
);
create index payments_obligation_idx on public.payments (obligation_id) where status = 'active';

create table public.refunds (
  id                      uuid primary key default gen_random_uuid(),
  owner_user_id           uuid not null,
  original_transaction_id uuid not null,
  refund_transaction_id   uuid not null unique,
  target                  public.refund_target not null,
  amount_cents            bigint not null check (amount_cents > 0),
  refunded_on             date not null,
  status                  public.txn_status not null default 'active',
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),
  foreign key (original_transaction_id, owner_user_id) references public.transactions (id, owner_user_id),
  foreign key (refund_transaction_id, owner_user_id) references public.transactions (id, owner_user_id)
);
create index refunds_original_idx on public.refunds (original_transaction_id) where status = 'active';

create table public.transfers (
  id                 uuid primary key default gen_random_uuid(),
  from_account_id    uuid not null references public.financial_accounts (id),
  to_account_id      uuid not null references public.financial_accounts (id),
  from_owner_user_id uuid not null,
  to_owner_user_id   uuid not null,
  amount_cents       bigint not null check (amount_cents > 0),
  executed_on        date not null,
  out_transaction_id uuid not null unique references public.transactions (id),
  in_transaction_id  uuid not null unique references public.transactions (id),
  status             public.txn_status not null default 'active',
  created_by         uuid not null,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  check (from_account_id <> to_account_id)
);

-- Idempotência das operações financeiras (base também do sync offline do Marco C)
create table public.financial_operations (
  owner_user_id       uuid not null,
  client_operation_id uuid not null,
  kind                text not null,
  payload_hash        text not null,
  result              jsonb not null,
  created_at          timestamptz not null default now(),
  primary key (owner_user_id, client_operation_id)
);

-- Registro de execução de jobs (§17.2)
create table public.job_runs (
  id          uuid primary key default gen_random_uuid(),
  job         text not null,
  status      text not null check (status in ('running', 'succeeded', 'failed', 'abandoned', 'skipped')),
  started_at  timestamptz not null default clock_timestamp(),
  finished_at timestamptz,
  items       integer not null default 0,
  error       text,
  check ((status = 'running') = (finished_at is null))
);
create index job_runs_job_idx on public.job_runs (job, started_at desc);

-- updated_at
do $$
declare t text;
begin
  foreach t in array array['categories', 'financial_accounts', 'credit_cards', 'billing_cycles',
    'transactions', 'card_purchases', 'installments', 'card_credits', 'recurrence_rules',
    'obligations', 'payments', 'refunds', 'transfers'] loop
    execute format('create trigger %I before update on public.%I for each row execute function private.touch_updated_at()',
                   t || '_touch', t);
  end loop;
end $$;
