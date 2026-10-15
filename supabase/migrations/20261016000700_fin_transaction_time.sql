-- Fluvi — Marco B — FIN-04: hora do lançamento (data/hora preenchidas pelo dispositivo, editáveis).
-- p_local_time é opcional; occurred_at = data + hora no fuso do lançamento (§7.1).
-- A data de negócio (local_date) continua sendo a informada; nada é convertido entre fusos.

drop function public.create_transaction(uuid, uuid, public.txn_type, uuid, bigint, text, uuid, date, date, text);

create function public.create_transaction(
  p_op uuid, p_owner uuid, p_type public.txn_type, p_account uuid, p_amount_cents bigint,
  p_description text, p_category uuid, p_local_date date,
  p_competence_month date default null, p_note text default null, p_local_time time default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_payload jsonb := jsonb_build_object('type', p_type, 'acc', p_account, 'amt', p_amount_cents,
    'desc', p_description, 'cat', p_category, 'date', p_local_date, 'comp', p_competence_month,
    'note', p_note, 'time', p_local_time);
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
  if p_local_time is not null then
    update public.transactions
       set occurred_at = (p_local_date + p_local_time) at time zone timezone
     where id = v_txn;
  end if;
  perform private.post(v_txn, p_owner, p_account,
    case when p_type = 'income' then p_amount_cents else -p_amount_cents end, p_local_date);
  return private.fin_record(p_owner, p_op, 'create_transaction', v_payload, private.result(v_txn));
end;
$$;

revoke execute on function public.create_transaction(uuid, uuid, public.txn_type, uuid, bigint, text, uuid, date, date, text, time)
  from public, anon;
grant execute on function public.create_transaction(uuid, uuid, public.txn_type, uuid, bigint, text, uuid, date, date, text, time)
  to authenticated;
