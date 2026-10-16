-- FluviFiance v2.2 — Visão geral, Parcelas e Relatórios (FF-05/06/07): números conhecidos,
-- sem dupla contagem entre consumo, caixa e compromissos; leitura exige desbloqueio.
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(26);

insert into auth.users (id, instance_id, aud, role, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'a@fluvi.test', '{"display_name":"Pessoa A"}'),
  ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'b@fluvi.test', '{"display_name":"Pessoa B"}'),
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'c@fluvi.test', '{"display_name":"Pessoa C"}');
update public.profiles set provisioned_at = now()
 where user_id in ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000c1');
update auth.users set email_confirmed_at = now(), encrypted_password = 'x' where email like '%@fluvi.test';
insert into public.households (id, name) values
  ('00000000-0000-0000-0000-0000000000f1', 'Família 1'), ('00000000-0000-0000-0000-0000000000f2', 'Família 2');
insert into public.household_members (household_id, user_id) values
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000a1'),
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000b1'),
  ('00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-0000000000c1');
insert into auth.sessions (id, user_id) values
  ('00000000-0000-0000-0000-00000000005a', '00000000-0000-0000-0000-0000000000a1'),
  ('00000000-0000-0000-0000-00000000005b', '00000000-0000-0000-0000-0000000000b1'),
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
create function pg_temp.ov() returns jsonb language sql as $$
  select public.family_overview('00000000-0000-0000-0000-0000000000f1', '2026-10-01') $$;
select set_config('fluvi.today', '2026-10-15', true);

-- Movimento da Família 1 (A lança sem desbloqueio: lançamento rápido)
select pg_temp.a();
select pg_temp.put('acc', (public.create_account(gen_random_uuid(), '00000000-0000-0000-0000-0000000000f1',
  'Banco', 'checking', '2026-10-01', 200000) ->> 'id')::uuid);
select public.create_transaction(gen_random_uuid(), '00000000-0000-0000-0000-0000000000f1', 'expense',
  pg_temp.id('acc'), 15000, 'Farmácia', pg_temp.cat('Saúde'), '2026-10-02');
select public.create_transaction(gen_random_uuid(), '00000000-0000-0000-0000-0000000000f1', 'income',
  pg_temp.id('acc'), 100000, 'Salário', pg_temp.cat('Salário', 'income'), '2026-10-05');
select pg_temp.put('card', (public.create_card(gen_random_uuid(), '00000000-0000-0000-0000-0000000000f1',
  'Cartão', 5, 15, 500000, 'current_cycle', 'Visa', '1234', '2026-01-01') ->> 'id')::uuid);
select pg_temp.put('p600', (public.create_card_purchase(gen_random_uuid(), pg_temp.id('card'), 60000, 6,
  'Geladeira', pg_temp.cat('Moradia'), '2026-10-10') ->> 'id')::uuid);

-- Sem desbloqueio: nada é lido
select throws_ok($$ select pg_temp.ov() $$, 'P0002', null, 'Visão geral exige o desbloqueio financeiro');
select throws_ok($$ select public.family_installments('00000000-0000-0000-0000-0000000000f1') $$, 'P0002', null,
  'Parcelas exigem o desbloqueio financeiro');
select throws_ok($$ select public.family_report('00000000-0000-0000-0000-0000000000f1', '2026-10-01', '2026-10-01') $$,
  'P0002', null, 'Relatórios exigem o desbloqueio financeiro');

select public.unlock_finance('00000000-0000-0000-0000-0000000000f1');

-- ---------------------------------------------------------------------------
-- Visão geral (FF-06)
-- ---------------------------------------------------------------------------
select is((pg_temp.ov() ->> 'balance_cents')::bigint, 285000::bigint, 'caixa: 2.000 − 150 + 1.000 (a compra no cartão não sai do caixa)');
select is((pg_temp.ov() ->> 'income_cents')::bigint, 100000::bigint, 'receitas do mês: R$ 1.000');
select is((pg_temp.ov() ->> 'consumption_cents')::bigint, 75000::bigint,
  'consumo do mês: 150 + 600 da compra inteira (as parcelas não somam de novo)');
select is(pg_temp.ov() -> 'categories', '[{"name": "Moradia", "cents": 60000}, {"name": "Saúde", "cents": 15000}]'::jsonb,
  'consumo por categoria, maior primeiro');
select is((pg_temp.ov() -> 'cards' -> 0 ->> 'debt_cents')::bigint, 60000::bigint, 'dívida do cartão R$ 600');
select is((pg_temp.ov() -> 'cards' -> 0 ->> 'current_cents')::bigint, 10000::bigint, 'fatura atual (aberta): R$ 100');
select is((select sum((f ->> 'cents')::bigint)::bigint from jsonb_array_elements(pg_temp.ov() -> 'future') f), 60000::bigint,
  'parcelas a faturar somam os R$ 600 da compra');
select is(jsonb_array_length(pg_temp.ov() -> 'future'), 6, 'seis meses com parcela');
select is(jsonb_array_length(pg_temp.ov() -> 'evolution'), 6, 'evolução: seis meses');
select is((pg_temp.ov() -> 'evolution' -> 5 ->> 'consumption_cents')::bigint, 75000::bigint, 'evolução: o mês atual bate com o consumo');

-- ---------------------------------------------------------------------------
-- Parcelas (FF-05)
-- ---------------------------------------------------------------------------
select is((select jsonb_array_length(public.family_installments('00000000-0000-0000-0000-0000000000f1') -> 'purchases')), 1,
  'uma compra parcelada com saldo a faturar');
select is((select (p ->> 'remaining_cents')::bigint from jsonb_array_elements(
             public.family_installments('00000000-0000-0000-0000-0000000000f1') -> 'purchases') p), 60000::bigint,
  'a faturar: R$ 600');
select is((select (p ->> 'next_cents')::bigint from jsonb_array_elements(
             public.family_installments('00000000-0000-0000-0000-0000000000f1') -> 'purchases') p), 10000::bigint,
  'próxima parcela: R$ 100');

-- ---------------------------------------------------------------------------
-- Pagar a fatura (FIN-03) não muda consumo; reduz caixa e dívida
-- ---------------------------------------------------------------------------
select set_config('fluvi.today', '2026-11-10', true);
reset role;
select pg_temp.put('bill', private.close_cycle((select id from public.billing_cycles
  where card_id = pg_temp.id('card') and closes_on = '2026-11-05')));
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-00000000005b');
select public.unlock_finance('00000000-0000-0000-0000-0000000000f1');
select public.settle_obligation(gen_random_uuid(), pg_temp.id('bill'), pg_temp.id('acc'), 10000, '2026-11-10');
select is((pg_temp.ov() ->> 'consumption_cents')::bigint, 75000::bigint, 'FIN-03: pagar a fatura não altera o consumo de outubro');
select is((pg_temp.ov() ->> 'balance_cents')::bigint, 275000::bigint, 'FIN-03: caixa −R$ 100');
select is((pg_temp.ov() -> 'cards' -> 0 ->> 'debt_cents')::bigint, 50000::bigint, 'FIN-03: dívida −R$ 100');
select is((public.family_overview('00000000-0000-0000-0000-0000000000f1', '2026-11-01') ->> 'consumption_cents')::bigint,
  0::bigint, 'FIN-03: o pagamento em novembro não vira consumo de novembro');

-- ---------------------------------------------------------------------------
-- Relatórios (FF-07)
-- ---------------------------------------------------------------------------
select is((select sum((c ->> 'cents')::bigint)::bigint from jsonb_array_elements(
             public.family_report('00000000-0000-0000-0000-0000000000f1', '2026-09-01', '2026-11-01') -> 'categories') c),
  75000::bigint, 'relatório do período: consumo total por categoria');
select is(jsonb_array_length(public.family_report('00000000-0000-0000-0000-0000000000f1', '2026-09-01', '2026-11-01') -> 'months'), 3,
  'relatório: um item por mês do período');
select is(public.family_report('00000000-0000-0000-0000-0000000000f1', '2026-10-01', '2026-10-01') -> 'by_author',
  '[{"name": "Pessoa A", "cents": 75000}]'::jsonb, 'relatório por autoria (created_by é só autoria)');
select throws_ok($$ select public.family_report('00000000-0000-0000-0000-0000000000f1', '2026-01-01', '2029-01-01') $$,
  '23514', null, 'período limitado a 36 meses');

-- ---------------------------------------------------------------------------
-- Isolamento (FAM-02)
-- ---------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-00000000005c');
select public.unlock_finance('00000000-0000-0000-0000-0000000000f2');
select throws_ok($$ select pg_temp.ov() $$, 'P0002', null, 'FAM-02: outra família não vê a Visão geral da Família 1');
select is((public.family_overview('00000000-0000-0000-0000-0000000000f2', '2026-10-01') ->> 'balance_cents')::bigint, 0::bigint,
  'FAM-02: a Família 2 vê só os próprios números');

select * from finish();
rollback;
