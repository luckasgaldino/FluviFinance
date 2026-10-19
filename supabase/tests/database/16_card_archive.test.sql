-- FluviFinance — excluir (arquivar) e reativar cartão: some das listas, preserva o histórico,
-- nunca com dívida em aberto.
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(14);

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
create function pg_temp.cards_in_quick_entry() returns int language sql as $$
  select jsonb_array_length(public.quick_entry_options('00000000-0000-0000-0000-0000000000f1') -> 'cards') $$;

select set_config('fluvi.today', '2026-11-05', true);
select pg_temp.a();
select pg_temp.put('card', (public.create_card(gen_random_uuid(), '00000000-0000-0000-0000-0000000000f1',
  'Cartão antigo', 5, 15, 100000, 'current_cycle', null, null, '2026-11-01') ->> 'id')::uuid);
select pg_temp.put('compra', (public.create_card_purchase(gen_random_uuid(), pg_temp.id('card'), 30000, 3, 'TV',
  (select id from public.categories where family_id is null and name = 'Lazer'), '2026-11-02') ->> 'id')::uuid);

select throws_ok($$ select public.set_card_active(pg_temp.id('card'), false) $$, 'P0002', null, 'excluir cartão exige o desbloqueio');
select public.unlock_finance('00000000-0000-0000-0000-0000000000f1');
select throws_ok($$ select public.set_card_active(pg_temp.id('card'), false) $$, '23514',
  'cartão com dívida em aberto: pague as faturas ou anule os lançamentos antes de excluir', 'com dívida não exclui');
select is(pg_temp.cards_in_quick_entry(), 1, 'cartão ainda aparece no lançamento rápido');

select public.void_transaction(gen_random_uuid(), pg_temp.id('compra'), 'lançada no cartão errado');
select is((public.set_card_active(pg_temp.id('card'), false) ->> 'status'), 'archived', 'sem dívida, o cartão é excluído (arquivado)');
select is((select active from public.credit_cards where id = pg_temp.id('card')), false, 'cartão inativo');
select is((select a.active from public.financial_accounts a join public.credit_cards c on c.account_id = a.id
            where c.id = pg_temp.id('card')), false, 'conta interna do cartão também inativa');
select is(pg_temp.cards_in_quick_entry(), 0, 'some do lançamento rápido');
select is(jsonb_array_length(public.family_overview('00000000-0000-0000-0000-0000000000f1', '2026-11-01') -> 'cards'), 0,
  'some da Visão geral');
select is((select count(*)::int from public.transactions where id = pg_temp.id('compra')), 1, 'o histórico da compra continua guardado');
select throws_ok($$ select public.create_card_purchase(gen_random_uuid(), pg_temp.id('card'), 100, 1, 'x',
  (select id from public.categories where family_id is null and name = 'Lazer'), '2026-11-03') $$,
  '23514', 'cartão inativo', 'cartão excluído não recebe compras');

select is((public.set_card_active(pg_temp.id('card'), true) ->> 'status'), 'active', 'reativar devolve o cartão');
select is(pg_temp.cards_in_quick_entry(), 1, 'reativado, volta ao lançamento rápido');

select pg_temp.as_user('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-00000000005c');
select public.unlock_finance('00000000-0000-0000-0000-0000000000f2');
select throws_ok($$ select public.set_card_active(pg_temp.id('card'), false) $$, 'P0002', null, 'outra família não exclui o cartão');
select throws_ok($$ select public.set_card_active(gen_random_uuid(), false) $$, 'P0002', null, 'cartão inexistente: mesmo erro');

select * from finish();
rollback;
