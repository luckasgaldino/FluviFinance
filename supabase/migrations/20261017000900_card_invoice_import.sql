-- Fase 2, parte 2 — importação de fatura de cartão (spec v2.2 §5: revisão e deduplicação).
--
-- O responsável envia a fatura fechada do banco (arquivo lido no próprio aparelho; o arquivo
-- não é guardado). Cada linha confirmada na prévia entra NA FATURA ESCOLHIDA (o banco é a fonte):
-- * compra comum              → compra no cartão (consumo na competência), 1 parcela;
-- * parcela 1/n               → compra parcelada inteira; as próximas parcelas já ficam nas
--                               faturas seguintes;
-- * parcela k/n já conhecida  → reconhecida (nada é lançado de novo);
-- * parcela k/n desconhecida  → compra anterior ao histórico: saldo anterior (dívida, não
--                               consumo) com as parcelas restantes.
-- Pagamentos e estornos não são importados (ficam com o usuário). Reimportar a mesma linha não
-- duplica (hash da linha por cartão). Ao final a fatura pode ser fechada para pagamento.

create table public.card_import_lines (
  id               uuid primary key default gen_random_uuid(),
  family_id        uuid not null references public.households (id) on delete restrict,
  card_id          uuid not null references public.credit_cards (id),
  billing_cycle_id uuid not null references public.billing_cycles (id),
  line_hash        text not null check (char_length(line_hash) between 16 and 128),
  outcome          text not null check (outcome in ('created', 'matched')),
  transaction_id   uuid references public.transactions (id),
  installment_id   uuid references public.installments (id),
  created_by       uuid,
  created_at       timestamptz not null default now(),
  unique (card_id, line_hash)
);
create index card_import_lines_cycle_idx on public.card_import_lines (billing_cycle_id);
alter table public.card_import_lines enable row level security;
grant select on public.card_import_lines to authenticated;
create policy card_import_lines_select on public.card_import_lines for select to authenticated
  using (private.can_access_family(family_id, 'cards', 'read'));
create trigger card_import_lines_no_delete before delete on public.card_import_lines
  for each row execute function private.ledger_guard();

-- Fatura (ciclo) do cartão com vencimento no mês informado.
create function private.cycle_due_in(p_card uuid, p_due_month date)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_card  public.credit_cards;
  v_due   date := date_trunc('month', p_due_month)::date;
  v_cycle uuid;
begin
  select * into v_card from public.credit_cards where id = p_card;
  v_cycle := private.ensure_cycle(p_card, private.clamp_date(
    extract(year from v_due - interval '2 months')::int, extract(month from v_due - interval '2 months')::int,
    v_card.closing_day));
  for i in 1 .. 4 loop
    exit when date_trunc('month', (select due_on from public.billing_cycles where id = v_cycle)) = v_due;
    v_cycle := private.next_cycle(v_cycle);
  end loop;
  if date_trunc('month', (select due_on from public.billing_cycles where id = v_cycle)) <> v_due then
    raise exception 'não foi possível localizar a fatura desse vencimento' using errcode = 'check_violation';
  end if;
  return v_cycle;
end;
$$;

-- Compra (ou saldo anterior) com parcelas a partir de uma fatura específica.
create function private.add_card_items(
  p_card uuid, p_type public.txn_type, p_description text, p_parcel_cents bigint, p_n int,
  p_category uuid, p_local_date date, p_first_cycle uuid, p_op uuid, p_note text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_card     public.credit_cards;
  v_total    bigint := p_parcel_cents * p_n;
  v_txn      uuid;
  v_purchase uuid;
  v_cycle    uuid := p_first_cycle;
begin
  select * into v_card from public.credit_cards where id = p_card;
  v_txn := private.new_txn(v_card.family_id, p_type, p_description, v_total, p_category, v_card.account_id,
    p_local_date, p_local_date, p_note, null, p_op);
  insert into public.card_purchases (transaction_id, family_id, card_id, total_cents, installment_count)
  values (v_txn, v_card.family_id, p_card, v_total, p_n)
  returning id into v_purchase;
  for i in 1 .. p_n loop
    if i > 1 then v_cycle := private.next_cycle(v_cycle); end if;
    insert into public.installments (purchase_id, family_id, revision, sequence, amount_cents, billing_cycle_id)
    values (v_purchase, v_card.family_id, 1, i, p_parcel_cents, v_cycle);
  end loop;
  perform private.post(v_txn, v_card.family_id, v_card.account_id, -v_total, p_local_date);
  return v_txn;
end;
$$;

-- p_lines: [{hash, date, description, kind: 'purchase'|'installment', k, n, amount_cents, category}]
create function public.import_card_invoice(
  p_op uuid, p_card uuid, p_due_month date, p_lines jsonb, p_close boolean default true)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_card     public.credit_cards;
  v_payload  jsonb := jsonb_build_object('card', p_card, 'due', p_due_month, 'lines', p_lines, 'close', p_close);
  v_res      jsonb;
  v_cycle    uuid;
  v_line     jsonb;
  v_desc     text;
  v_amount   bigint;
  v_k        int;
  v_n        int;
  v_date     date;
  v_txn      uuid;
  v_inst     uuid;
  v_created  int := 0;
  v_matched  int := 0;
  v_skipped  int := 0;
  v_out      jsonb := '[]'::jsonb;
  v_outcome  text;
begin
  select * into v_card from public.credit_cards where id = p_card for update;
  perform private.require_access(v_card.family_id, 'cards', 'update');   -- importar exige o desbloqueio
  v_res := private.fin_replay(v_card.family_id, p_op, 'import_card_invoice', v_payload);
  if v_res is not null then return v_res; end if;
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) > 500 then
    raise exception 'informe até 500 linhas' using errcode = 'check_violation';
  end if;
  v_cycle := private.cycle_due_in(p_card, p_due_month);

  for v_line in select * from jsonb_array_elements(p_lines) loop
    if exists (select 1 from public.card_import_lines where card_id = p_card and line_hash = v_line ->> 'hash') then
      v_skipped := v_skipped + 1;
      v_out := v_out || jsonb_build_object('hash', v_line ->> 'hash', 'outcome', 'skipped');
      continue;
    end if;
    if exists (select 1 from public.billing_cycles where id = v_cycle and status = 'closed') then
      raise exception 'essa fatura já está fechada no FluviFinance; só linhas já importadas podem ser reenviadas'
        using errcode = 'check_violation';
    end if;
    v_desc   := btrim(coalesce(v_line ->> 'description', ''));
    v_amount := (v_line ->> 'amount_cents')::bigint;
    v_date   := (v_line ->> 'date')::date;
    v_k      := coalesce((v_line ->> 'k')::int, 1);
    v_n      := coalesce((v_line ->> 'n')::int, 1);
    if char_length(v_desc) = 0 or v_amount is null or v_amount <= 0 or v_date is null
       or v_k < 1 or v_n < 1 or v_n > 36 or v_k > v_n then
      raise exception 'linha inválida: %', left(v_desc, 60) using errcode = 'check_violation';
    end if;
    v_txn := null; v_inst := null;

    if v_line ->> 'kind' = 'installment' then
      -- parcela já prevista (compra/saldo anterior conhecidos): reconhece, não lança de novo
      select i.id, t.id into v_inst, v_txn
        from public.installments i
        join public.card_purchases p on p.id = i.purchase_id and p.card_id = p_card
        join public.transactions t on t.id = p.transaction_id and t.status = 'active'
       where i.billing_cycle_id = v_cycle and i.status = 'valid' and i.amount_cents = v_amount
         and lower(t.description) = lower(v_desc)
         and not exists (select 1 from public.card_import_lines l where l.installment_id = i.id)
       order by i.id limit 1;
    end if;

    if v_inst is not null then
      v_outcome := 'matched';
      v_matched := v_matched + 1;
    else
      v_outcome := 'created';
      v_created := v_created + 1;
      if v_line ->> 'kind' = 'installment' and v_k > 1 then
        -- compra anterior ao histórico: só as parcelas restantes, como dívida (não consumo)
        v_txn := private.add_card_items(p_card, 'card_opening_balance', v_desc, v_amount, v_n - v_k + 1, null,
          (select starts_on from public.billing_cycles where id = v_cycle),
          v_cycle, md5(p_op::text || (v_line ->> 'hash'))::uuid,
          format('Parcelas %s a %s de %s, importadas da fatura', v_k, v_n, v_n));
      else
        perform private.check_category(v_card.family_id, (v_line ->> 'category')::uuid, 'expense');
        v_txn := private.add_card_items(p_card, 'card_purchase', v_desc, v_amount, v_n, (v_line ->> 'category')::uuid,
          v_date, v_cycle, md5(p_op::text || (v_line ->> 'hash'))::uuid,
          case when v_n > 1 then format('Compra em %s parcelas, importada da fatura', v_n) else 'Importada da fatura' end);
      end if;
      select i.id into v_inst from public.installments i join public.card_purchases p on p.id = i.purchase_id
       where p.transaction_id = v_txn and i.billing_cycle_id = v_cycle;
    end if;

    insert into public.card_import_lines (family_id, card_id, billing_cycle_id, line_hash, outcome, transaction_id, installment_id, created_by)
    values (v_card.family_id, p_card, v_cycle, v_line ->> 'hash', v_outcome, v_txn, v_inst, auth.uid());
    v_out := v_out || jsonb_build_object('hash', v_line ->> 'hash', 'outcome', v_outcome, 'transaction_id', v_txn);
  end loop;

  if p_close and exists (select 1 from public.billing_cycles where id = v_cycle and status = 'open') then
    perform private.close_cycle(v_cycle);
  end if;
  perform private.assert_card_reconciled(p_card);

  return private.fin_record(v_card.family_id, p_op, 'import_card_invoice', v_payload, jsonb_build_object(
    'cycle_id', v_cycle, 'created', v_created, 'matched', v_matched, 'skipped', v_skipped,
    'invoice_cents', private.cycle_amount(v_cycle),
    'closed', (select status = 'closed' from public.billing_cycles where id = v_cycle),
    'lines', v_out));
end;
$$;

revoke execute on function private.cycle_due_in(uuid, date),
  private.add_card_items(uuid, public.txn_type, text, bigint, int, uuid, date, uuid, uuid, text)
  from public, anon, authenticated;
revoke execute on function public.import_card_invoice(uuid, uuid, date, jsonb, boolean) from public, anon;
grant execute on function public.import_card_invoice(uuid, uuid, date, jsonb, boolean) to authenticated;
