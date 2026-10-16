-- FluviFinance — Fase 2: importação de fatura de cartão (revisão + deduplicação + parcelas).
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(24);

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
create function pg_temp.cat(p text) returns uuid language sql as $$
  select id from public.categories where family_id is null and name = p and kind = 'expense' $$;
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
  perform private.assert_card_reconciled(pg_temp.id('card'));
  perform pg_temp.a();
  return v;
end $$;
create function pg_temp.line(p_hash text, p_date date, p_desc text, p_cents bigint, p_cat text,
  p_k int default null, p_n int default null) returns jsonb language sql as $$
  select jsonb_strip_nulls(jsonb_build_object('hash', p_hash, 'date', p_date, 'description', p_desc,
    'kind', case when p_n is null then 'purchase' else 'installment' end, 'k', p_k, 'n', p_n,
    'amount_cents', p_cents, 'category', pg_temp.cat(p_cat))) $$;
create function pg_temp.import(p_due date, p_lines jsonb) returns jsonb language sql as $$
  select public.import_card_invoice(gen_random_uuid(), pg_temp.id('card'), p_due, p_lines) $$;
create function pg_temp.consumo(p_month date) returns bigint language sql as $$
  select (public.family_overview('00000000-0000-0000-0000-0000000000f1', p_month) ->> 'consumption_cents')::bigint $$;

select set_config('fluvi.today', '2026-12-10', true);
select pg_temp.a();
select pg_temp.put('card', (public.create_card(gen_random_uuid(), '00000000-0000-0000-0000-0000000000f1',
  'Nubank', 28, 5, 1000000, 'current_cycle', null, null, '2026-09-01') ->> 'id')::uuid);

create temp table nov as select jsonb_build_array(
  pg_temp.line('hash-nov-mercado-0001', '2026-10-10', 'Mercado Bom Preço', 10000, 'Mercado'),
  pg_temp.line('hash-nov-tv-00000001', '2026-10-12', 'Loja TV', 20000, 'Lazer', 1, 3),
  pg_temp.line('hash-nov-notebook-01', '2026-06-20', 'Notebook', 15000, 'Outros', 4, 6)) as l;
grant all on nov to public;

select throws_ok($$ select pg_temp.import('2026-11-01', (select l from nov)) $$, 'P0002', null,
  'importar fatura exige o desbloqueio financeiro');
select public.unlock_finance('00000000-0000-0000-0000-0000000000f1');

-- fatura que venceu em 05/11 (fechou em 28/10)
select is((pg_temp.import('2026-11-01', (select l from nov)) - 'lines' - 'cycle_id'),
  '{"closed": true, "created": 3, "matched": 0, "skipped": 0, "invoice_cents": 45000}'::jsonb,
  'novembro: 3 itens criados, fatura de R$ 450 fechada');
select is((select count(*)::int from public.transactions where type = 'card_purchase'), 2, 'compra comum e compra parcelada');
select is((select count(*)::int from public.transactions where type = 'card_opening_balance'), 1,
  'parcela 4/6 de compra antiga vira saldo anterior');
select is((select installment_count::int from public.card_purchases p join public.transactions t on t.id = p.transaction_id
            where t.description = 'Notebook'), 3, 'saldo anterior só com as 3 parcelas restantes (4, 5 e 6)');
select is((select total_cents from public.card_purchases p join public.transactions t on t.id = p.transaction_id
            where t.description = 'Loja TV'), 60000::bigint, 'parcela 1/3 cria a compra inteira (3 × R$ 200)');
select is(pg_temp.consumo('2026-10-01'), 70000::bigint, 'consumo de outubro: R$ 100 + R$ 600 (parcelas não somam de novo; saldo anterior fora)');
select is(pg_temp.consumo('2026-06-01'), 0::bigint, 'a compra antiga não vira consumo retroativo');
select is((select count(*)::int from public.obligations where type = 'card_bill'), 1, 'fatura fechada fica disponível para pagamento');

-- reenviar a mesma fatura não duplica
select is((pg_temp.import('2026-11-01', (select l from nov)) ->> 'skipped')::int, 3, 'reimportar: as 3 linhas são ignoradas');
select is((select count(*)::int from public.transactions where family_id = '00000000-0000-0000-0000-0000000000f1'), 3,
  'nenhum lançamento a mais');

-- fatura seguinte (venceu em 05/12): parcelas reconhecidas, compra nova criada
create temp table dez as select jsonb_build_array(
  pg_temp.line('hash-dez-tv-00000002', '2026-10-12', 'Loja TV', 20000, 'Lazer', 2, 3),
  pg_temp.line('hash-dez-notebook-05', '2026-06-20', 'Notebook', 15000, 'Outros', 5, 6),
  pg_temp.line('hash-dez-uber-000001', '2026-11-15', 'Uber', 3000, 'Transporte')) as l;
grant all on dez to public;
select is((pg_temp.import('2026-12-01', (select l from dez)) - 'lines' - 'cycle_id'),
  '{"closed": true, "created": 1, "matched": 2, "skipped": 0, "invoice_cents": 38000}'::jsonb,
  'dezembro: 2 parcelas reconhecidas, 1 compra nova, fatura de R$ 380 fechada');
select is(pg_temp.consumo('2026-11-01'), 3000::bigint, 'consumo de novembro: só o Uber (parcelas reconhecidas não somam)');
select is(pg_temp.debt(), 118000::bigint, 'dívida: 450 + 380 + janeiro (200 + 150); EQ-1 conciliado');
select is((select count(*)::int from public.card_import_lines where outcome = 'matched'), 2, 'linhas reconhecidas registradas');

-- validações
select throws_ok($$ select pg_temp.import('2026-12-01', jsonb_build_array(
  pg_temp.line('hash-dez-extra-00001', '2026-11-20', 'Extra', 100, 'Outros'))) $$,
  '23514', null, 'fatura já fechada no app não recebe linha nova');
select lives_ok($$ select pg_temp.import('2026-12-01', (select l from dez)) $$, 'mas reenviar as mesmas linhas é aceito (ignoradas)');
select throws_ok($$ select pg_temp.import('2027-01-01', jsonb_build_array(
  jsonb_build_object('hash', 'hash-jan-ruim-000001', 'date', '2026-12-20', 'description', 'X', 'kind', 'purchase',
    'amount_cents', 100, 'category', pg_temp.cat('Salário')))) $$, '23514', null, 'categoria inválida é recusada');
select throws_ok($$ select pg_temp.import('2027-01-01', jsonb_build_array(
  pg_temp.line('hash-jan-ruim-000002', '2026-12-20', 'X', 100, 'Outros', 3, 2))) $$, '23514', null, 'parcela 3/2 é recusada');
select throws_ok($$ select pg_temp.import('2027-01-01', jsonb_build_array(
  pg_temp.line('hash-jan-ruim-000003', '2026-12-20', 'X', 0, 'Outros'))) $$, '23514', null, 'valor zero é recusado');
select is((select count(*)::int from public.transactions where family_id = '00000000-0000-0000-0000-0000000000f1'), 4,
  'importação recusada não deixa nada pela metade');

-- isolamento
select pg_temp.as_user('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-00000000005c');
select public.unlock_finance('00000000-0000-0000-0000-0000000000f2');
select throws_ok($$ select pg_temp.import('2027-01-01', jsonb_build_array(
  pg_temp.line('hash-jan-outra-00001', '2026-12-20', 'X', 100, 'Outros'))) $$, 'P0002', null, 'outra família não importa no cartão');
select is((select count(*)::int from public.card_import_lines), 0, 'outra família não vê as linhas importadas');
select throws_ok($$ insert into public.card_import_lines (family_id, card_id, billing_cycle_id, line_hash, outcome)
  values ('00000000-0000-0000-0000-0000000000f2', pg_temp.id('card'), gen_random_uuid(), 'hash-forjado-000001', 'created') $$,
  '42501', null, 'ninguém grava linha de importação diretamente');

select * from finish();
rollback;
