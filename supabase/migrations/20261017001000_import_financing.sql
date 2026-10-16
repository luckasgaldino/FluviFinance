-- Fase 2 — importação de fatura: "Parcelamento de Fatura" (a fatura anterior parcelada) é dívida
-- rolada, nunca consumo novo — as compras originais já contaram no mês delas. A linha chega com
-- debt_only = true e entra sempre como saldo anterior (dívida), inclusive na parcela 1.
-- Idem para qualquer parcela k > 1 de compra desconhecida (anterior ao histórico).

-- p_lines: [{hash, date, description, kind: 'purchase'|'installment', k, n, amount_cents, category, debt_only?}]
create or replace function public.import_card_invoice(
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
      if v_line ->> 'kind' = 'installment' and (v_k > 1 or coalesce((v_line ->> 'debt_only')::boolean, false)) then
        -- compra anterior ao histórico ou parcelamento de fatura: só as parcelas restantes, como dívida
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
