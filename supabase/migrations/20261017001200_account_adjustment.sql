-- Atualizar saldo da conta e saldo inicial no INÍCIO do dia de abertura.
--
-- * Saldo inicial: passa a valer para o início do dia de abertura — lançamentos do próprio dia
--   contam (antes, o dia de abertura era considerado já incluído e eles eram ignorados, o que
--   confundia quem abre a conta e lança no mesmo dia). O que é anterior à abertura continua fora.
-- * adjust_account_balance: o usuário informa o saldo real numa data; a diferença para o saldo
--   calculado vira um lançamento de ajuste (adjustment_in / adjustment_out) — não é receita nem
--   despesa, fica no histórico e pode ser anulado. Exige o desbloqueio (operação de alteração).

create or replace function public.account_balance(p_account uuid, p_on date default null, p_known_at timestamptz default null)
returns bigint
language sql
stable
security invoker
set search_path = ''
as $$
  select a.opening_balance_cents + coalesce((
    select sum(e.amount_cents) from public.ledger_entries e
     where e.account_id = a.id
       and e.posted_on >= a.opening_date
       and e.posted_on <= coalesce(p_on, private.today())
       -- sem instante informado = todo o conhecimento registrado (inclusive desta transação)
       and (p_known_at is null or e.recorded_at <= p_known_at)), 0)
  from public.financial_accounts a where a.id = p_account;
$$;

create function public.adjust_account_balance(
  p_op uuid, p_account uuid, p_target_cents bigint, p_on date, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_family  uuid := private.account_family(p_account, 'accounts', 'update');
  v_acc     public.financial_accounts;
  v_payload jsonb := jsonb_build_object('acc', p_account, 'target', p_target_cents, 'on', p_on, 'note', p_note);
  v_res     jsonb;
  v_current bigint;
  v_diff    bigint;
  v_txn     uuid;
begin
  v_res := private.fin_replay(v_family, p_op, 'adjust_account_balance', v_payload);
  if v_res is not null then return v_res; end if;
  perform private.require_cash_account(p_account, v_family);
  select * into v_acc from public.financial_accounts where id = p_account for update;
  if p_target_cents is null or p_on is null then
    raise exception 'informe o saldo e a data' using errcode = 'check_violation';
  end if;
  if p_on < v_acc.opening_date then
    raise exception 'informe uma data a partir da abertura da conta (%)', to_char(v_acc.opening_date, 'DD/MM/YYYY')
      using errcode = 'check_violation';
  end if;
  if p_on > private.today() then
    raise exception 'informe uma data até hoje' using errcode = 'check_violation';
  end if;

  v_current := public.account_balance(p_account, p_on);
  v_diff := p_target_cents - v_current;
  if v_diff = 0 then
    return private.fin_record(v_family, p_op, 'adjust_account_balance', v_payload,
      jsonb_build_object('id', null, 'status', 'unchanged', 'difference_cents', 0));
  end if;

  v_txn := private.new_txn(v_family, case when v_diff > 0 then 'adjustment_in' else 'adjustment_out' end::public.txn_type,
    'Ajuste de saldo', abs(v_diff), null, p_account, p_on, p_on, nullif(btrim(coalesce(p_note, '')), ''), null, p_op);
  perform private.post(v_txn, v_family, p_account, v_diff, p_on);
  return private.fin_record(v_family, p_op, 'adjust_account_balance', v_payload,
    private.result(v_txn) || jsonb_build_object('difference_cents', v_diff));
end;
$$;

revoke execute on function public.adjust_account_balance(uuid, uuid, bigint, date, text) from public, anon;
grant execute on function public.adjust_account_balance(uuid, uuid, bigint, date, text) to authenticated;
