-- FluviFiance v2.2 — edição de lançamento com histórico (FF-02) e categorias da família (FF-08).
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(25);

insert into auth.users (id, instance_id, aud, role, email) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'a@fluvi.test'),
  ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'b@fluvi.test'),
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'c@fluvi.test');
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
select set_config('fluvi.today', '2026-10-15', true);

select pg_temp.a();
select pg_temp.put('acc', (public.create_account(gen_random_uuid(), '00000000-0000-0000-0000-0000000000f1',
  'Banco', 'checking', '2026-10-01', 100000) ->> 'id')::uuid);
select pg_temp.put('exp', (public.create_transaction(gen_random_uuid(), '00000000-0000-0000-0000-0000000000f1', 'expense',
  pg_temp.id('acc'), 7000, 'Mercado do mês', pg_temp.cat('Mercado'), '2026-10-02') ->> 'id')::uuid);

-- ---------------------------------------------------------------------------
-- Edição (FF-02)
-- ---------------------------------------------------------------------------
select throws_ok($$ select public.edit_transaction(gen_random_uuid(), pg_temp.id('exp'), 5000, 'Mercado', pg_temp.cat('Lazer'),
  pg_temp.id('acc'), '2026-10-02') $$, 'P0002', null, 'editar exige o desbloqueio financeiro');
select public.unlock_finance('00000000-0000-0000-0000-0000000000f1');
select pg_temp.put('op', gen_random_uuid());
select pg_temp.put('new', (public.edit_transaction(pg_temp.id('op'), pg_temp.id('exp'), 5000, 'Mercado (corrigido)',
  pg_temp.cat('Lazer'), pg_temp.id('acc'), '2026-10-03') ->> 'id')::uuid);
select is((select status::text from public.transactions where id = pg_temp.id('exp')), 'voided', 'o original fica anulado');
select is((select cancel_reason from public.transactions where id = pg_temp.id('exp')), 'substituído por edição', 'com motivo de edição');
select is((select replaces_transaction_id from public.transactions where id = pg_temp.id('new')), pg_temp.id('exp'),
  'o novo lançamento aponta o original (histórico)');
select is((select (amount_cents, description, local_date)::text from public.transactions where id = pg_temp.id('new')),
  '(5000,"Mercado (corrigido)",2026-10-03)', 'o novo lançamento tem os dados editados');
select is(public.account_balance(pg_temp.id('acc')), 95000::bigint, 'saldo reflete só o valor editado (1.000 − 50)');
select is((select count(*)::int from public.ledger_entries where transaction_id = pg_temp.id('exp')), 2,
  'o razão do original preserva lançamento e compensação');
select is((select direct_expenses_cents from public.competence_summary('00000000-0000-0000-0000-0000000000f1', '2026-10-01')),
  5000::bigint, 'consumo do mês conta só a versão editada');
select is((public.edit_transaction(pg_temp.id('op'), pg_temp.id('exp'), 5000, 'Mercado (corrigido)', pg_temp.cat('Lazer'),
  pg_temp.id('acc'), '2026-10-03') ->> 'id')::uuid, pg_temp.id('new'), 'idempotente: repetir a mesma edição devolve o mesmo resultado');
select is((select count(*)::int from public.transactions where family_id = '00000000-0000-0000-0000-0000000000f1'
            and type = 'expense'), 2, 'repetir não cria outro lançamento');
select throws_ok($$ select public.edit_transaction(gen_random_uuid(), pg_temp.id('exp'), 100, 'x', pg_temp.cat('Lazer'),
  pg_temp.id('acc'), '2026-10-03') $$, '23514', 'operação não está ativa', 'não se edita o que já foi anulado');

select pg_temp.put('card', (public.create_card(gen_random_uuid(), '00000000-0000-0000-0000-0000000000f1',
  'Cartão', 5, 15, 100000, 'current_cycle', null, null, '2026-01-01') ->> 'id')::uuid);
select pg_temp.put('cp', (public.create_card_purchase(gen_random_uuid(), pg_temp.id('card'), 3000, 1, 'Livro',
  pg_temp.cat('Educação'), '2026-10-05') ->> 'id')::uuid);
select throws_ok($$ select public.edit_transaction(gen_random_uuid(), pg_temp.id('cp'), 100, 'x', pg_temp.cat('Lazer'),
  pg_temp.id('acc'), '2026-10-05') $$, '23514', null, 'compra no cartão não é editada aqui (ajuste, estorno ou anulação)');

select pg_temp.as_user('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-00000000005b');
select public.unlock_finance('00000000-0000-0000-0000-0000000000f1');
select lives_ok($$ select public.edit_transaction(gen_random_uuid(), pg_temp.id('new'), 4000, 'Mercado', pg_temp.cat('Mercado'),
  pg_temp.id('acc'), '2026-10-03') $$, 'outro membro da família edita (visão e gestão compartilhadas)');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-00000000005c');
select public.unlock_finance('00000000-0000-0000-0000-0000000000f2');
select throws_ok($$ select public.edit_transaction(gen_random_uuid(), pg_temp.id('new'), 1, 'x', pg_temp.cat('Mercado'),
  pg_temp.id('acc'), '2026-10-03') $$, 'P0002', null, 'outra família não edita (mesmo erro de inexistente)');

-- ---------------------------------------------------------------------------
-- Categorias da família (FF-08)
-- ---------------------------------------------------------------------------
select pg_temp.a();
select pg_temp.put('pets', (public.create_category('00000000-0000-0000-0000-0000000000f1', 'Ração e veterinário', 'expense') ->> 'id')::uuid);
select is((select array_agg(name) from public.family_categories('00000000-0000-0000-0000-0000000000f1')),
  array['Ração e veterinário'], 'categoria da família criada');
select ok((public.quick_entry_options('00000000-0000-0000-0000-0000000000f1') -> 'categories') @> jsonb_build_array(jsonb_build_object('name', 'Ração e veterinário')),
  'aparece no lançamento rápido');
select throws_ok($$ select public.create_category('00000000-0000-0000-0000-0000000000f1', 'mercado', 'expense') $$,
  '23514', 'categoria já existe', 'não duplica categoria (inclusive as padrão, sem diferenciar maiúsculas)');
select pg_temp.put('ex2', (public.create_transaction(gen_random_uuid(), '00000000-0000-0000-0000-0000000000f1', 'expense',
  pg_temp.id('acc'), 2000, 'Vacina', pg_temp.id('pets'), '2026-10-06') ->> 'id')::uuid);
select isnt(pg_temp.id('ex2'), null::uuid, 'lança com a categoria da família');

select lives_ok($$ select public.set_category_active(pg_temp.id('pets'), false) $$, 'arquivar categoria');
select ok(not ((public.quick_entry_options('00000000-0000-0000-0000-0000000000f1') -> 'categories') @> jsonb_build_array(jsonb_build_object('name', 'Ração e veterinário'))),
  'arquivada some do lançamento rápido');
select throws_ok($$ select public.create_transaction(gen_random_uuid(), '00000000-0000-0000-0000-0000000000f1', 'expense',
  pg_temp.id('acc'), 100, 'x', pg_temp.id('pets'), '2026-10-07') $$, '23514', 'categoria inválida', 'arquivada não aceita lançamentos novos');
select is((select category_id from public.transactions where id = pg_temp.id('ex2')), pg_temp.id('pets'),
  'o histórico mantém a categoria arquivada');

select pg_temp.as_user('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-00000000005c');
select throws_ok($$ select * from public.family_categories('00000000-0000-0000-0000-0000000000f1') $$, 'P0002', null,
  'outra família não lista as categorias');
select throws_ok($$ select public.set_category_active(pg_temp.id('pets'), true) $$, 'P0002', null,
  'outra família não reativa a categoria');
select throws_ok($$ select public.set_category_active(pg_temp.cat('Mercado'), false) $$, 'P0002', null,
  'categorias padrão não são arquivadas por uma família');

select * from finish();
rollback;
