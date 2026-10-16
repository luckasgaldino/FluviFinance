-- Remodelagem v2.2 — R4: Visão geral (FF-06), Parcelas (FF-05) e Relatórios (FF-07) da família.
--
-- Definições únicas, sem dupla contagem (§6.10):
-- * CAIXA       = saldo das contas (abertura + movimentos); pagamento de fatura reduz o caixa.
-- * CONSUMO     = competência: despesas diretas + compras no cartão (líquidas de estorno)
--                 + contas a pagar reconhecidas (competence_summary.recognized_total_cents).
--                 A parcela que vence não é consumo novo; o pagamento da fatura também não.
-- * COMPROMISSO = dívida de cartão: faturas fechadas em aberto e parcelas ainda a faturar.
-- Todas exigem leitura da família (membro ativo + desbloqueio financeiro da sessão).

create function private.month_consumption(p_family uuid, p_month date)
returns bigint
language sql
stable
security definer
set search_path = ''
as $$ select recognized_total_cents from public.competence_summary(p_family, p_month) $$;

create function private.month_income(p_family uuid, p_month date)
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(sum(t.amount_cents), 0)::bigint
    from public.transactions t
   where t.family_id = p_family and t.type = 'income' and t.status = 'active'
     and t.competence_month = private.month_start(p_month);
$$;

-- Consumo por categoria num intervalo de competências (inclusive), líquido de estornos.
create function private.consumption_by_category(p_family uuid, p_from date, p_to date)
returns table (category text, cents bigint)
language sql
stable
security definer
set search_path = ''
as $$
  with refunded as (
    select r.original_transaction_id as id, sum(r.amount_cents) as v
      from public.refunds r where r.family_id = p_family and r.status = 'active' group by 1),
  items as (
    select t.category_id,
           case when t.type = 'card_purchase' then p.total_cents else t.amount_cents end
             - coalesce(f.v, 0) as v
      from public.transactions t
      left join public.card_purchases p on p.transaction_id = t.id
      left join refunded f on f.id = t.id
     where t.family_id = p_family and t.status = 'active' and t.type in ('expense', 'card_purchase')
       and t.competence_month between private.month_start(p_from) and private.month_start(p_to)
    union all
    select o.category_id, o.original_amount_cents + o.adjustments_cents
      from public.obligations o
     where o.family_id = p_family and o.type = 'bill' and o.status = 'active'
       and o.competence_month between private.month_start(p_from)
                                  and least(private.month_start(p_to), private.month_start(private.today())))
  select coalesce(c.name, 'Sem categoria'), sum(i.v)::bigint
    from items i left join public.categories c on c.id = i.category_id
   group by 1
  having sum(i.v) <> 0
   order by 2 desc, 1;
$$;

-- Parcelas ainda a faturar (ciclos abertos), por mês de vencimento da fatura.
create function private.future_installments_by_month(p_family uuid, p_months int)
returns table (month date, cents bigint)
language sql
stable
security definer
set search_path = ''
as $$
  select private.month_start(c.due_on), sum(i.amount_cents)::bigint
    from public.installments i
    join public.billing_cycles c on c.id = i.billing_cycle_id
    join public.card_purchases p on p.id = i.purchase_id
    join public.transactions t on t.id = p.transaction_id and t.status = 'active'
   where c.family_id = p_family and c.status = 'open' and i.status = 'valid'
     and c.due_on < (private.month_start(private.today()) + make_interval(months => p_months + 1))::date
   group by 1
   order by 1;
$$;

-- ---------------------------------------------------------------------------
-- Visão geral
-- ---------------------------------------------------------------------------
create function public.family_overview(p_family uuid, p_month date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_month date := private.month_start(coalesce(p_month, private.today()));
begin
  perform private.require_access(p_family, 'transactions', 'read');
  return jsonb_build_object(
    'month', v_month,
    'balance_cents', (select coalesce(sum(public.account_balance(a.id)), 0)::bigint
                        from public.financial_accounts a
                       where a.family_id = p_family and a.active and a.type <> 'credit_card'),
    'income_cents', private.month_income(p_family, v_month),
    'consumption_cents', private.month_consumption(p_family, v_month),
    'categories', coalesce((select jsonb_agg(jsonb_build_object('name', x.category, 'cents', x.cents))
                              from private.consumption_by_category(p_family, v_month, v_month) x), '[]'),
    'cards', coalesce((select jsonb_agg(jsonb_build_object(
                          'card_id', p.card_id, 'name', p.name, 'due_day', k.due_day,
                          'current_cents', coalesce(p.open_preview_cents, 0),
                          'closed_open_cents', p.closed_remaining_cents,
                          'debt_cents', p.debt_total_cents) order by p.name)
                         from public.v_card_position p join public.credit_cards k on k.id = p.card_id
                        where p.family_id = p_family and k.active), '[]'),
    'evolution', (select jsonb_agg(jsonb_build_object('month', m,
                     'income_cents', private.month_income(p_family, m),
                     'consumption_cents', private.month_consumption(p_family, m)) order by m)
                    from generate_series(v_month - interval '5 months', v_month, interval '1 month') g(m0),
                         lateral (select g.m0::date as m) mm),
    'future', coalesce((select jsonb_agg(jsonb_build_object('month', f.month, 'cents', f.cents) order by f.month)
                          from private.future_installments_by_month(p_family, 12) f), '[]'));
end;
$$;

-- ---------------------------------------------------------------------------
-- Parcelas: compras parceladas com saldo a faturar e calendário
-- ---------------------------------------------------------------------------
create function public.family_installments(p_family uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_access(p_family, 'transactions', 'read');
  return jsonb_build_object(
    'purchases', coalesce((
      select jsonb_agg(row_to_json(x)::jsonb order by x.remaining_cents desc, x.description)
        from (
          select t.id as transaction_id, t.description, k.name as card, p.total_cents,
                 count(*) filter (where i.status = 'valid') as count,
                 count(*) filter (where i.status = 'valid' and c.status = 'closed') as billed,
                 coalesce(sum(i.amount_cents) filter (where i.status = 'valid' and c.status = 'open'), 0)::bigint as remaining_cents,
                 (select i2.amount_cents from public.installments i2
                    join public.billing_cycles c2 on c2.id = i2.billing_cycle_id
                   where i2.purchase_id = p.id and i2.status = 'valid' and c2.status = 'open'
                   order by c2.closes_on limit 1) as next_cents
            from public.card_purchases p
            join public.transactions t on t.id = p.transaction_id and t.status = 'active'
            join public.credit_cards k on k.id = p.card_id
            join public.installments i on i.purchase_id = p.id
            join public.billing_cycles c on c.id = i.billing_cycle_id
           where t.family_id = p_family
           group by t.id, t.description, k.name, p.total_cents, p.id
          having count(*) filter (where i.status = 'valid' and c.status = 'open') > 0
             and count(*) filter (where i.status = 'valid') > 1) x), '[]'),
    'months', coalesce((select jsonb_agg(jsonb_build_object('month', f.month, 'cents', f.cents) order by f.month)
                          from private.future_installments_by_month(p_family, 36) f), '[]'));
end;
$$;

-- ---------------------------------------------------------------------------
-- Relatórios por período (competência)
-- ---------------------------------------------------------------------------
create function public.family_report(p_family uuid, p_from date, p_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_from date := private.month_start(p_from);
  v_to   date := private.month_start(p_to);
begin
  perform private.require_access(p_family, 'transactions', 'read');
  if v_to < v_from or v_to > v_from + interval '35 months' then
    raise exception 'período inválido (até 36 meses)' using errcode = 'check_violation';
  end if;
  return jsonb_build_object(
    'from', v_from, 'to', v_to,
    'categories', coalesce((select jsonb_agg(jsonb_build_object('name', x.category, 'cents', x.cents))
                              from private.consumption_by_category(p_family, v_from, v_to) x), '[]'),
    'months', (select jsonb_agg(jsonb_build_object('month', g.m::date,
                  'income_cents', private.month_income(p_family, g.m::date),
                  'consumption_cents', private.month_consumption(p_family, g.m::date)) order by g.m)
                 from generate_series(v_from, v_to, interval '1 month') g(m)),
    'by_author', coalesce((
      select jsonb_agg(jsonb_build_object('name', coalesce(pr.display_name, 'Outro membro'), 'cents', s.v) order by s.v desc)
        from (select t.created_by, sum(case when t.type = 'card_purchase' then p.total_cents else t.amount_cents end)::bigint as v
                from public.transactions t left join public.card_purchases p on p.transaction_id = t.id
               where t.family_id = p_family and t.status = 'active' and t.type in ('expense', 'card_purchase')
                 and t.competence_month between v_from and v_to
               group by t.created_by) s
        left join public.profiles pr on pr.user_id = s.created_by), '[]'),
    'commitments', coalesce((select jsonb_agg(jsonb_build_object('month', f.month, 'cents', f.cents) order by f.month)
                               from private.future_installments_by_month(p_family, 12) f), '[]'));
end;
$$;

-- ---------------------------------------------------------------------------
-- Execução
-- ---------------------------------------------------------------------------
revoke execute on function private.month_consumption(uuid, date), private.month_income(uuid, date),
  private.consumption_by_category(uuid, date, date), private.future_installments_by_month(uuid, int)
  from public, anon, authenticated;
do $$
declare f text;
begin
  foreach f in array array['family_overview(uuid, date)', 'family_installments(uuid)', 'family_report(uuid, date, date)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
