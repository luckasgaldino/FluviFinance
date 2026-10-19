-- FluviFinance — saldo inicial no início do dia de abertura e "Atualizar saldo" (FF-03).
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
create function pg_temp.cat(p text, kind public.category_kind default 'expense') returns uuid language sql as $$
  select id from public.categories where family_id is null and name = p and kind = kind $$;
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
create function pg_temp.adjust(p_target bigint, p_on date, p_op uuid default gen_random_uuid()) returns jsonb language sql as $$
  select public.adjust_account_balance(p_op, pg_temp.id('acc'), p_target, p_on) $$;
create function pg_temp.bal(p_on date default null) returns bigint language sql as $$
  select public.account_balance(pg_temp.id('acc'), p_on) $$;

select set_config('fluvi.today', '2026-11-05', true);
select pg_temp.a();
select pg_temp.put('acc', (public.create_account(gen_random_uuid(), '00000000-0000-0000-0000-0000000000f1',
  'Conta', 'checking', '2026-11-01', 100000) ->> 'id')::uuid);
select public.create_transaction(gen_random_uuid(), '00000000-0000-0000-0000-0000000000f1', 'expense',
  pg_temp.id('acc'), 5000, 'No dia da abertura', pg_temp.cat('Mercado'), '2026-11-01');
select public.create_transaction(gen_random_uuid(), '00000000-0000-0000-0000-0000000000f1', 'expense',
  pg_temp.id('acc'), 7000, 'Antes da abertura', pg_temp.cat('Mercado'), '2026-10-30');
select public.unlock_finance('00000000-0000-0000-0000-0000000000f1');

-- saldo inicial no início do dia
select is(pg_temp.bal(), 95000::bigint, 'lançamento do próprio dia de abertura conta no saldo (1.000 − 50)');
select is(pg_temp.bal('2026-10-31'), 100000::bigint, 'antes da abertura, o saldo é o inicial; o lançamento anterior ao corte não entra');

-- atualizar saldo
select pg_temp.put('op1', gen_random_uuid());
select is((pg_temp.adjust(120000, '2026-11-03', pg_temp.id('op1')) ->> 'difference_cents')::bigint, 25000::bigint,
  'atualizar para R$ 1.200: ajuste de +R$ 250');
select is(pg_temp.bal(), 120000::bigint, 'saldo passa a ser o informado');
select is((select type::text from public.transactions where description = 'Ajuste de saldo' and status = 'active'),
  'adjustment_in', 'ajuste para mais é um lançamento identificado');
select is((pg_temp.adjust(120000, '2026-11-03', pg_temp.id('op1')) ->> 'difference_cents')::bigint, 25000::bigint,
  'idempotente: repetir a mesma operação devolve o mesmo resultado');
select is((select count(*)::int from public.transactions where description = 'Ajuste de saldo'), 1, 'repetir não cria outro ajuste');

select is((pg_temp.adjust(100000, '2026-11-04') ->> 'difference_cents')::bigint, -20000::bigint, 'atualizar para menos: −R$ 200');
select is(pg_temp.bal(), 100000::bigint, 'saldo agora R$ 1.000');
select is(pg_temp.bal('2026-11-03'), 120000::bigint, 'o saldo do dia 03 continua o informado naquele dia');
select is((pg_temp.adjust(100000, '2026-11-05') ->> 'status'), 'unchanged', 'mesmo saldo: nada é lançado');

-- não é receita nem consumo
select is((public.family_overview('00000000-0000-0000-0000-0000000000f1', '2026-11-01') ->> 'income_cents')::bigint, 0::bigint,
  'ajuste não é receita');
select is((public.family_overview('00000000-0000-0000-0000-0000000000f1', '2026-11-01') ->> 'consumption_cents')::bigint, 5000::bigint,
  'ajuste não é consumo (só a despesa de R$ 50 do mês)');

-- anular volta o saldo
select public.void_transaction(gen_random_uuid(),
  (select id from public.transactions where type = 'adjustment_out' and status = 'active'), 'ajuste errado');
select is(pg_temp.bal(), 120000::bigint, 'anular o ajuste devolve o saldo anterior');

-- validações e segurança
select throws_ok($$ select pg_temp.adjust(1, '2026-10-31') $$, '23514', null, 'data antes da abertura é recusada');
select throws_ok($$ select pg_temp.adjust(1, '2026-11-06') $$, '23514', null, 'data futura é recusada');
select pg_temp.put('card', (public.create_card(gen_random_uuid(), '00000000-0000-0000-0000-0000000000f1',
  'Cartão', 5, 15, 100000, 'current_cycle', null, null, '2026-11-01') ->> 'id')::uuid);
select throws_ok($$ select public.adjust_account_balance(gen_random_uuid(),
  (select account_id from public.credit_cards where id = pg_temp.id('card')), 0, '2026-11-05') $$,
  'P0002', null, 'conta de cartão não recebe ajuste de saldo');
select public.lock_finance();
select throws_ok($$ select pg_temp.adjust(1, '2026-11-05') $$, 'P0002', null, 'atualizar saldo exige o desbloqueio');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-00000000005c');
select public.unlock_finance('00000000-0000-0000-0000-0000000000f2');
select throws_ok($$ select pg_temp.adjust(1, '2026-11-05') $$, 'P0002', null, 'outra família não ajusta a conta');
select pg_temp.a();
select public.unlock_finance('00000000-0000-0000-0000-0000000000f1');
select is((select count(*)::int from public.ledger_entries e join public.transactions t on t.id = e.transaction_id
            where t.type in ('adjustment_in', 'adjustment_out')), 3, 'histórico preservado: 2 ajustes + 1 compensação');

select * from finish();
rollback;
