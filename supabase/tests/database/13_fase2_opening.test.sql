-- FluviFinance — Fase 2: implantação na data de corte. Dívida anterior do cartão entra nas
-- faturas e na dívida, mas não é consumo nem caixa.
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(20);

insert into auth.users (id, instance_id, aud, role, email) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'a@fluvi.test'),
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'c@fluvi.test');
update public.profiles set provisioned_at = now()
 where user_id in ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000c1');
update auth.users set email_confirmed_at = now(), encrypted_password = 'x' where email like '%@fluvi.test';
insert into public.households (id, name) values
  ('00000000-0000-0000-0000-0000000000f1', 'Família 1'), ('00000000-0000-0000-0000-0000000000f2', 'Família 2');
insert into public.household_members (household_id, user_id) values
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000a1'),
  ('00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-0000000000c1');
insert into auth.sessions (id, user_id) values
  ('00000000-0000-0000-0000-00000000005a', '00000000-0000-0000-0000-0000000000a1'),
  ('00000000-0000-0000-0000-00000000005c', '00000000-0000-0000-0000-0000000000c1');

create temp table k (name text primary key, id uuid);
grant all on k to public;
create function pg_temp.put(p text, v uuid) returns uuid language sql as $$
  insert into k (name, id) values (p, v) on conflict (name) do update set id = excluded.id returning id $$;
create function pg_temp.id(p text) returns uuid language sql as $$ select id from k where name = p $$;
create function pg_temp.as_user(p_uid uuid, p_session uuid) returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', p_uid, 'role', 'authenticated', 'aal', 'aal1',
    'session_id', p_session, 'amr', jsonb_build_array(jsonb_build_object('method', 'password',
    'timestamp', floor(extract(epoch from now())) - 5)))::text, true);
  execute 'set local role authenticated';
end $$;
create function pg_temp.a() returns void language sql as $$
  select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000005a') $$;
create function pg_temp.debt() returns bigint language plpgsql as $$
declare v bigint;
begin
  execute 'reset role';
  v := private.card_debt(pg_temp.id('card'));
  perform pg_temp.a();
  return v;
end $$;
create function pg_temp.reconciled() returns boolean language plpgsql as $$
begin
  execute 'reset role';
  perform private.assert_card_reconciled(pg_temp.id('card'));
  perform pg_temp.a();
  return true;
end $$;
create function pg_temp.opening(p_desc text, p_cents bigint, p_n int, p_due date) returns uuid language sql as $$
  select (public.create_card_opening_balance(gen_random_uuid(), pg_temp.id('card'), p_desc, p_cents, p_n, p_due) ->> 'id')::uuid $$;

-- a família começa a usar em 01/11; hoje é 03/11. Cartão fecha dia 28 e vence dia 5.
select set_config('fluvi.today', '2026-11-03', true);
select pg_temp.a();
select pg_temp.put('bank', (public.create_account(gen_random_uuid(), '00000000-0000-0000-0000-0000000000f1',
  'Conta', 'checking', '2026-11-01', 500000) ->> 'id')::uuid);
select pg_temp.put('card', (public.create_card(gen_random_uuid(), '00000000-0000-0000-0000-0000000000f1',
  'Cartão', 28, 5, 1000000, 'current_cycle', null, null, '2026-11-01') ->> 'id')::uuid);

-- sem desbloqueio: implantar é criação (não lê nada)
select pg_temp.put('fechada', pg_temp.opening('Fatura de outubro (fechada)', 150000, 1, '2026-11-01'));
select pg_temp.put('aberta', pg_temp.opening('Fatura de novembro até o corte', 30000, 1, '2026-12-01'));
select pg_temp.put('antiga', pg_temp.opening('Notebook (parcelas restantes)', 20000, 5, '2026-12-01'));

select is(pg_temp.debt(), 280000::bigint, 'dívida do cartão = 1.500 + 300 + 5 × 200');
select ok(pg_temp.reconciled(), 'EQ-1: faturas e razão conciliados');

select public.unlock_finance('00000000-0000-0000-0000-0000000000f1');
select is((select c.status::text from public.billing_cycles c join public.installments i on i.billing_cycle_id = c.id
            join public.card_purchases p on p.id = i.purchase_id where p.transaction_id = pg_temp.id('fechada')), 'closed',
  'fatura que já fechou (28/10) fica fechada na hora');
select is((select original_amount_cents from public.obligations o join public.billing_cycles c on c.id = o.billing_cycle_id
            join public.installments i on i.billing_cycle_id = c.id join public.card_purchases p on p.id = i.purchase_id
           where p.transaction_id = pg_temp.id('fechada')), 150000::bigint, 'e fica disponível para pagamento (R$ 1.500)');
select is((select date_trunc('month', c.due_on)::date from public.billing_cycles c join public.installments i on i.billing_cycle_id = c.id
            join public.card_purchases p on p.id = i.purchase_id where p.transaction_id = pg_temp.id('aberta')), '2026-12-01'::date,
  'parte da fatura aberta cai na fatura que vence em dezembro');
select is((select array_agg(to_char(c.due_on, 'YYYY-MM') order by i.sequence) from public.installments i
             join public.billing_cycles c on c.id = i.billing_cycle_id join public.card_purchases p on p.id = i.purchase_id
            where p.transaction_id = pg_temp.id('antiga')),
  array['2026-12', '2027-01', '2027-02', '2027-03', '2027-04'], 'parcelas antigas: uma por fatura a partir de dezembro');

-- não é consumo nem caixa
select is((public.family_overview('00000000-0000-0000-0000-0000000000f1', '2026-11-01') ->> 'consumption_cents')::bigint, 0::bigint,
  'saldo anterior não vira consumo de novembro');
select is((public.family_overview('00000000-0000-0000-0000-0000000000f1', '2026-10-01') ->> 'consumption_cents')::bigint, 0::bigint,
  'nem de outubro');
select is(public.account_balance(pg_temp.id('bank')), 500000::bigint, 'o caixa não muda');
select is((public.family_overview('00000000-0000-0000-0000-0000000000f1', '2026-11-01') -> 'categories'), '[]'::jsonb,
  'não aparece em consumo por categoria');
select ok((select sum((f ->> 'cents')::bigint) from jsonb_array_elements(
            public.family_overview('00000000-0000-0000-0000-0000000000f1', '2026-11-01') -> 'future') f) >= 130000,
  'aparece nos compromissos futuros (parcelas a faturar)');
select is((select (p ->> 'count')::int from jsonb_array_elements(
            public.family_installments('00000000-0000-0000-0000-0000000000f1') -> 'purchases') p
           where p ->> 'description' = 'Notebook (parcelas restantes)'), 5, 'aparece em Parcelas');

-- pagar a fatura fechada reduz caixa e dívida
select public.settle_obligation(gen_random_uuid(),
  (select o.id from public.obligations o join public.billing_cycles c on c.id = o.billing_cycle_id
     join public.installments i on i.billing_cycle_id = c.id join public.card_purchases p on p.id = i.purchase_id
    where p.transaction_id = pg_temp.id('fechada')), pg_temp.id('bank'), 150000, '2026-11-03');
select is(public.account_balance(pg_temp.id('bank')), 350000::bigint, 'pagar a fatura anterior sai do caixa');
select is(pg_temp.debt(), 130000::bigint, 'e reduz a dívida');
select is((public.family_overview('00000000-0000-0000-0000-0000000000f1', '2026-11-01') ->> 'consumption_cents')::bigint, 0::bigint,
  'e não vira consumo');

-- anular um saldo anterior lançado errado desfaz as parcelas
select public.void_transaction(gen_random_uuid(), pg_temp.id('antiga'), 'lançado errado');
select is(pg_temp.debt(), 30000::bigint, 'anulação devolve a dívida (sobra a parte da fatura aberta)');
select ok(pg_temp.reconciled(), 'EQ-1 continua conciliado');

-- validações e isolamento
select throws_ok($$ select pg_temp.opening('x', 100, 1, '2026-11-01') $$, '23514', null,
  'não registra em fatura que já está fechada no app');
select throws_ok($$ select pg_temp.opening('x', 100, 0, '2026-12-01') $$, '23514', null, 'parcelas de 1 a 36');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-00000000005c');
select throws_ok($$ select pg_temp.opening('x', 100, 1, '2026-12-01') $$, 'P0002', null, 'outra família não registra no cartão');

select * from finish();
rollback;
