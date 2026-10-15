-- Fluvi — Marco B — Contas, lançamentos, transferências, permissões e bitemporalidade.
-- Oráculos: O1, O2, O8, O14, O15, O16, O19, O19b, O31, O35, O37.
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(34);

-- ---------------------------------------------------------------------------
-- Fixtures: Admin (a), Luck (1c) e Bia (b) no núcleo F1; Carol (c) noutro núcleo
-- ---------------------------------------------------------------------------
delete from public.administrators;
insert into auth.users (id, instance_id, aud, role, email) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'admin@fluvi.test'),
  ('00000000-0000-0000-0000-00000000001c', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'luck@fluvi.test'),
  ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'bia@fluvi.test'),
  ('00000000-0000-0000-0000-00000000000c', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'carol@fluvi.test');
select private.bootstrap_first_admin('admin@fluvi.test');
update public.profiles set provisioned_at = now(), display_name = split_part(user_id::text, '-', 5)
 where user_id in ('00000000-0000-0000-0000-00000000001c', '00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-00000000000c');
update auth.users set email_confirmed_at = now(), encrypted_password = 'x' where email like '%@fluvi.test';
insert into public.households (id, name) values ('00000000-0000-0000-0000-0000000000f1', 'F1'), ('00000000-0000-0000-0000-0000000000f2', 'F2');
insert into public.household_members (household_id, user_id) values
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000001c'),
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000000b'),
  ('00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-00000000000c');
select set_config('fluvi.today', '2026-10-15', true);

create temp table k (name text primary key, id uuid, ts timestamptz);
grant all on k to public;
create function pg_temp.put(p text, v uuid) returns uuid language sql as $$
  insert into k (name, id) values (p, v) on conflict (name) do update set id = excluded.id returning id $$;
create function pg_temp.mark(p text) returns timestamptz language sql as $$
  insert into k (name, ts) values (p, clock_timestamp()) returning ts $$;
create function pg_temp.id(p text) returns uuid language sql as $$ select id from k where name = p $$;
create function pg_temp.ts(p text) returns timestamptz language sql as $$ select ts from k where name = p $$;
create function pg_temp.cat(p text, kind public.category_kind default 'expense') returns uuid language sql as $$
  select id from public.categories where owner_user_id is null and name = p and kind = kind $$;
create function pg_temp.login(p_uid uuid, p_aal text default 'aal1') returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', p_uid, 'role', 'authenticated', 'aal', p_aal)::text, true);
  execute 'set local role authenticated';
end $$;
create function pg_temp.grant_(p_owner uuid, p_grantee uuid, p_scope public.grant_scope,
  r boolean, c boolean, u boolean, x boolean) returns void language plpgsql as $$
begin
  perform pg_temp.login('00000000-0000-0000-0000-00000000000a', 'aal2');
  perform public.admin_set_data_grant(gen_random_uuid(), '00000000-0000-0000-0000-0000000000f1', p_owner, p_grantee, p_scope, r, c, u, x);
  execute 'reset role';
end $$;

-- ---------------------------------------------------------------------------
-- O1 / O2: saldo inicial e corte
-- ---------------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-00000000001c');
select pg_temp.put('acc', (public.create_account(gen_random_uuid(), '00000000-0000-0000-0000-00000000001c',
  'Banco', 'checking', '2026-10-01', 100000) ->> 'id')::uuid);
select pg_temp.put('exp', (public.create_transaction(gen_random_uuid(), '00000000-0000-0000-0000-00000000001c',
  'expense', pg_temp.id('acc'), 7000, 'Mercado', pg_temp.cat('Mercado'), '2026-10-02') ->> 'id')::uuid);
select is(public.account_balance(pg_temp.id('acc')), 93000::bigint, 'O1: abertura R$ 1.000 − despesa R$ 70 = R$ 930');
select is((select count(*)::int from public.transactions where type = 'income'), 0, 'O1: abertura não é receita');

select public.create_transaction(gen_random_uuid(), '00000000-0000-0000-0000-00000000001c',
  'expense', pg_temp.id('acc'), 5000, 'Histórico', pg_temp.cat('Mercado'), '2026-09-25');
select is(public.account_balance(pg_temp.id('acc')), 93000::bigint, 'O2: movimento anterior ao corte não altera o saldo');
select is((select direct_expenses_cents from public.competence_summary('00000000-0000-0000-0000-00000000001c', '2026-09-01')),
  5000::bigint, 'O2: o movimento anterior entra no consumo da sua competência');
select is((select balance_cents from public.v_account_balances where account_id = pg_temp.id('acc')), 93000::bigint,
  'view de saldos confere com account_balance');

-- validações
select throws_ok($$ select public.create_transaction(gen_random_uuid(), '00000000-0000-0000-0000-00000000001c',
  'expense', pg_temp.id('acc'), 100, 'x', pg_temp.cat('Salário', 'income'), '2026-10-03') $$,
  '23514', null, 'categoria de receita em despesa é recusada');
select throws_ok($$ select public.create_transaction(gen_random_uuid(), '00000000-0000-0000-0000-00000000001c',
  'expense', pg_temp.id('acc'), 0, 'x', pg_temp.cat('Mercado'), '2026-10-03') $$,
  '23514', null, 'valor deve ser positivo');

-- FIN-04: hora do lançamento no fuso do lançamento (data de negócio inalterada)
select pg_temp.put('hora', (public.create_transaction(gen_random_uuid(), '00000000-0000-0000-0000-00000000001c',
  'expense', pg_temp.id('acc'), 100, 'Café', pg_temp.cat('Alimentação fora'), '2026-10-03', null, null, '23:30') ->> 'id')::uuid);
select is((select occurred_at from public.transactions where id = pg_temp.id('hora')), '2026-10-04 02:30:00+00'::timestamptz,
  'FIN-04: 03/10 23:30 em São Paulo = 04/10 02:30 UTC');
select is((select local_date from public.transactions where id = pg_temp.id('hora')), '2026-10-03'::date,
  'FIN-04: a data de negócio continua 03/10 (sem conversão de fuso)');
select public.void_transaction(gen_random_uuid(), pg_temp.id('hora'), 'teste de hora');

-- ---------------------------------------------------------------------------
-- O16: idempotência
-- ---------------------------------------------------------------------------
select pg_temp.put('op', gen_random_uuid());
select public.create_transaction(pg_temp.id('op'), '00000000-0000-0000-0000-00000000001c',
  'expense', pg_temp.id('acc'), 1234, 'Repetida', pg_temp.cat('Mercado'), '2026-10-04')
  from generate_series(1, 10);
select is((select count(*)::int from public.transactions where description = 'Repetida'), 1,
  'O16: mesma client_operation_id 10× gera uma operação');
select throws_ok($$ select public.create_transaction(pg_temp.id('op'), '00000000-0000-0000-0000-00000000001c',
  'expense', pg_temp.id('acc'), 9999, 'Outra', pg_temp.cat('Mercado'), '2026-10-04') $$,
  '23505', null, 'mesma chave com outro conteúdo é conflito');

-- ---------------------------------------------------------------------------
-- O37: bitemporalidade (data financeira × instante de conhecimento)
-- ---------------------------------------------------------------------------
select pg_temp.put('acc2', (public.create_account(gen_random_uuid(), '00000000-0000-0000-0000-00000000001c',
  'Reserva', 'savings', '2026-10-01', 100000) ->> 'id')::uuid);
select pg_temp.mark('t0');
select pg_temp.put('e37', (public.create_transaction(gen_random_uuid(), '00000000-0000-0000-0000-00000000001c',
  'expense', pg_temp.id('acc2'), 7000, 'Lançada por engano', pg_temp.cat('Lazer'), '2026-10-02') ->> 'id')::uuid);
select pg_temp.mark('t1');
select public.void_transaction(gen_random_uuid(), pg_temp.id('e37'), 'lançada por engano');
select pg_temp.mark('t2');
select is(public.account_balance(pg_temp.id('acc2'), '2026-10-05', pg_temp.ts('t0')), 100000::bigint,
  'O37: data 05/10 conhecida em t0 = R$ 1.000');
select is(public.account_balance(pg_temp.id('acc2'), '2026-10-05', pg_temp.ts('t1')), 93000::bigint,
  'O37: data 05/10 conhecida em t1 = R$ 930');
select is(public.account_balance(pg_temp.id('acc2'), '2026-10-05', pg_temp.ts('t2')), 100000::bigint,
  'O37: data 05/10 conhecida em t2 (após anulação) = R$ 1.000');
select is((select count(*)::int from public.ledger_entries where transaction_id = pg_temp.id('e37')), 2,
  'O37: anulação preserva o histórico (lançamento + compensação)');
select is((select array_agg(posted_on order by id) from public.ledger_entries where transaction_id = pg_temp.id('e37')),
  array['2026-10-02', '2026-10-02']::date[], 'O37: compensação com a mesma data financeira');

-- ---------------------------------------------------------------------------
-- O8: transferência interna
-- ---------------------------------------------------------------------------
select public.transfer_funds(gen_random_uuid(), pg_temp.id('acc'), pg_temp.id('acc2'), 10000, '2026-10-06');
select is(public.account_balance(pg_temp.id('acc')), 81766::bigint, 'O8: origem −R$ 100 (1.000 − 70 − 12,34 − 100)');
select is(public.account_balance(pg_temp.id('acc2')), 110000::bigint, 'O8: destino +R$ 100');
select is((select direct_expenses_cents from public.competence_summary('00000000-0000-0000-0000-00000000001c', '2026-10-01')),
  8234::bigint, 'O8: transferência não é despesa (consumo de outubro inalterado)');

-- ---------------------------------------------------------------------------
-- Contas de Bia e Carol
-- ---------------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-00000000000b');
select pg_temp.put('bia_acc', (public.create_account(gen_random_uuid(), '00000000-0000-0000-0000-00000000000b',
  'Conta Bia', 'checking', '2026-10-01', 50000) ->> 'id')::uuid);
select pg_temp.login('00000000-0000-0000-0000-00000000000c');
select pg_temp.put('carol_acc', (public.create_account(gen_random_uuid(), '00000000-0000-0000-0000-00000000000c',
  'Conta Carol', 'checking', '2026-10-01', 50000) ->> 'id')::uuid);

-- ---------------------------------------------------------------------------
-- O19 / O19b: transferência entre titulares exige create nas duas pontas
-- ---------------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-00000000001c');
select throws_ok($$ select public.transfer_funds(gen_random_uuid(), pg_temp.id('acc'), pg_temp.id('bia_acc'), 5000, '2026-10-07') $$,
  'P0002', null, 'O19: sem accounts/create em Bia a transferência é recusada');
select is((select count(*)::int from public.transactions where description = 'Transferência' and local_date = '2026-10-07'), 0,
  'O19: nada foi gravado em nenhuma ponta');

select pg_temp.grant_('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-00000000001c', 'accounts', false, true, false, false);
select pg_temp.login('00000000-0000-0000-0000-00000000001c');
select lives_ok($$ select public.transfer_funds(gen_random_uuid(), pg_temp.id('acc'), pg_temp.id('bia_acc'), 5000, '2026-10-07') $$,
  'O19b: com create nas duas pontas a transferência é gravada');
select pg_temp.login('00000000-0000-0000-0000-00000000000b');
select is(public.account_balance(pg_temp.id('bia_acc')), 55000::bigint, 'O19b: Bia recebe');
select is((select count(*)::int from public.financial_accounts where id = pg_temp.id('acc')), 0,
  'O19b: Bia não vê a conta de origem de Luck');

-- ---------------------------------------------------------------------------
-- O15: só create (sem read) recebe apenas {id, status}
-- ---------------------------------------------------------------------------
select pg_temp.grant_('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-00000000001c', 'transactions', false, true, false, false);
select pg_temp.login('00000000-0000-0000-0000-00000000001c');
select is(
  (select array_agg(k order by k) from jsonb_object_keys(public.create_transaction(gen_random_uuid(),
     '00000000-0000-0000-0000-00000000000b', 'expense', pg_temp.id('bia_acc'), 3000, 'Lançada por Luck',
     pg_temp.cat('Mercado'), '2026-10-08')) k),
  array['id', 'status'], 'O15: retorno mínimo {id, status}');
select is((select count(*)::int from public.transactions where owner_user_id = '00000000-0000-0000-0000-00000000000b'), 0,
  'O15: create sem read não revela lançamentos de Bia');

-- ---------------------------------------------------------------------------
-- O14: transactions/read sem accounts/read
-- ---------------------------------------------------------------------------
select pg_temp.grant_('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-00000000001c', 'transactions', true, true, false, false);
select pg_temp.login('00000000-0000-0000-0000-00000000001c');
select ok((select count(*) from public.transactions where owner_user_id = '00000000-0000-0000-0000-00000000000b') >= 2,
  'O14: Luck vê os lançamentos de Bia');
select is((select count(*)::int from public.v_account_balances where owner_user_id = '00000000-0000-0000-0000-00000000000b'), 0,
  'O14: Luck não vê saldo de Bia sem accounts/read');
select is(public.account_balance(pg_temp.id('bia_acc')), null::bigint, 'O14: account_balance também não revela');

-- ---------------------------------------------------------------------------
-- O31: inexistente e sem permissão dão o mesmo erro
-- ---------------------------------------------------------------------------
select throws_ok($$ select public.create_transaction(gen_random_uuid(), '00000000-0000-0000-0000-00000000001c',
  'expense', gen_random_uuid(), 100, 'x', pg_temp.cat('Mercado'), '2026-10-09') $$,
  'P0002', 'não encontrado ou sem permissão', 'O31: conta inexistente');
select throws_ok($$ select public.create_transaction(gen_random_uuid(), '00000000-0000-0000-0000-00000000001c',
  'expense', pg_temp.id('carol_acc'), 100, 'x', pg_temp.cat('Mercado'), '2026-10-09') $$,
  'P0002', 'não encontrado ou sem permissão', 'O31: conta de outro titular — mesmo erro');
select throws_ok($$ select public.create_transaction(gen_random_uuid(), '00000000-0000-0000-0000-00000000000c',
  'expense', pg_temp.id('carol_acc'), 100, 'x', pg_temp.cat('Mercado'), '2026-10-09') $$,
  'P0002', 'não encontrado ou sem permissão', 'O31: titular sem permissão — mesmo erro');

-- ---------------------------------------------------------------------------
-- O35: Admin não opera finanças
-- ---------------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-00000000000a', 'aal2');
select throws_ok($$ select public.create_account(gen_random_uuid(), '00000000-0000-0000-0000-00000000001c',
  'X', 'checking', '2026-10-01', 0) $$, 'P0002', null, 'O35: Admin não cria conta para Luck');
select is((select count(*)::int from public.transactions) + (select count(*)::int from public.ledger_entries)
          + (select count(*)::int from public.financial_accounts), 0, 'O35: Admin não lê nada financeiro');

select * from finish();
rollback;
