-- FluviFiance v2.2 — cenários de aceite FIN-01..05 e FAM pela API real (RPCs), com a família
-- como titular. Tudo numa transação revertida; usuários e valores fictícios.
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(22);

-- R3: leituras exigem sessão desbloqueada. O login simulado cria a sessão e desbloqueia a
-- primeira família ativa do usuário (os cenários do desbloqueio estão em 10_v22_unlock).
create function pg_temp.sid(p_uid uuid) returns uuid language sql immutable as $$
  select md5('sessao-teste-' || p_uid)::uuid $$;
create function pg_temp.unlock(p_uid uuid) returns void language plpgsql as $$
declare v_family uuid;
begin
  insert into auth.sessions (id, user_id) values (pg_temp.sid(p_uid), p_uid) on conflict (id) do nothing;
  select m.household_id into v_family
    from public.household_members m join public.households h on h.id = m.household_id
   where m.user_id = p_uid and m.status = 'active' and h.active
   order by h.name, h.id limit 1;
  if v_family is not null then
    insert into private.financial_unlocks (session_id, user_id, family_id)
    values (pg_temp.sid(p_uid), p_uid, v_family)
    on conflict (session_id) do update set family_id = excluded.family_id, last_activity_at = now();
  end if;
end $$;

-- A e B na família F1; C na família F2
insert into auth.users (id, instance_id, aud, role, email) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'a@fluvi.test'),
  ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'b@fluvi.test'),
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'c@fluvi.test');
update public.profiles set provisioned_at = now()
 where user_id in ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000b1',
                   '00000000-0000-0000-0000-0000000000c1');
update auth.users set email_confirmed_at = now(), encrypted_password = 'x'
 where id in ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000b1',
              '00000000-0000-0000-0000-0000000000c1');
insert into public.households (id, name) values
  ('00000000-0000-0000-0000-0000000000f1', 'Família Teste 1'),
  ('00000000-0000-0000-0000-0000000000f2', 'Família Teste 2');
insert into public.household_members (household_id, user_id) values
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000a1'),
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000b1'),
  ('00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-0000000000c1');

create temp table k (name text primary key, id uuid);
grant all on k to public;
create function pg_temp.put(p text, v uuid) returns uuid language sql as $$
  insert into k (name, id) values (p, v) on conflict (name) do update set id = excluded.id returning id $$;
create function pg_temp.id(p text) returns uuid language sql as $$ select id from k where name = p $$;
create function pg_temp.cat(p text) returns uuid language sql as $$
  select id from public.categories where family_id is null and name = p and kind = 'expense' $$;
create function pg_temp.login(p_uid uuid) returns void language plpgsql as $$
begin
  execute 'reset role';
  perform pg_temp.unlock(p_uid);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', p_uid, 'role', 'authenticated', 'aal', 'aal1', 'session_id', pg_temp.sid(p_uid))::text, true);
  execute 'set local role authenticated';
end $$;
create function pg_temp.debt(p_card text) returns bigint language plpgsql as $$
declare v bigint;
begin
  execute 'reset role';
  v := private.card_debt(pg_temp.id(p_card));
  return v;
end $$;
select set_config('fluvi.today', '2026-10-15', true);

-- ---------------------------------------------------------------------------
-- FIN-01: abertura R$ 2.000 e débito R$ 150 → saldo R$ 1.850
-- ---------------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-0000000000a1');
select pg_temp.put('bank', (public.create_account(gen_random_uuid(), '00000000-0000-0000-0000-0000000000f1',
  'Banco', 'checking', '2026-10-01', 200000) ->> 'id')::uuid);
select public.create_transaction(gen_random_uuid(), '00000000-0000-0000-0000-0000000000f1',
  'expense', pg_temp.id('bank'), 15000, 'Farmácia', pg_temp.cat('Saúde'), '2026-10-02');
select is(public.account_balance(pg_temp.id('bank')), 185000::bigint, 'FIN-01: R$ 2.000 − R$ 150 = R$ 1.850');

-- ---------------------------------------------------------------------------
-- FIN-02: compra R$ 600 em 6× R$ 100 → 6 parcelas e dívida R$ 600, sem saída de caixa
-- ---------------------------------------------------------------------------
select pg_temp.put('card', (public.create_card(gen_random_uuid(), '00000000-0000-0000-0000-0000000000f1',
  'Cartão', 5, 15, 500000, 'current_cycle', 'Visa', '1234', '2026-01-01') ->> 'id')::uuid);
select pg_temp.put('p600', (public.create_card_purchase(gen_random_uuid(), pg_temp.id('card'), 60000, 6,
  'Geladeira', pg_temp.cat('Moradia'), '2026-10-10') ->> 'id')::uuid);
select is((select count(*)::int from public.installments i join public.card_purchases p on p.id = i.purchase_id
            where p.transaction_id = pg_temp.id('p600') and i.status = 'valid'), 6, 'FIN-02: 6 parcelas');
select is((select array_agg(distinct i.amount_cents) from public.installments i join public.card_purchases p on p.id = i.purchase_id
            where p.transaction_id = pg_temp.id('p600')), array[10000]::bigint[], 'FIN-02: cada parcela de R$ 100');
select is(pg_temp.debt('card'), 60000::bigint, 'FIN-02: dívida do cartão R$ 600');
select pg_temp.login('00000000-0000-0000-0000-0000000000a1');
select is(public.account_balance(pg_temp.id('bank')), 185000::bigint, 'FIN-02: a compra não sai do caixa');
select is((select card_purchases_net_cents from public.competence_summary('00000000-0000-0000-0000-0000000000f1', '2026-10-01')),
  60000::bigint, 'FIN-02: consumo de outubro inclui a compra inteira (competência)');

-- ---------------------------------------------------------------------------
-- FIN-03: pagar R$ 100 da fatura → caixa −R$ 100 e dívida −R$ 100, sem duplicar consumo
-- ---------------------------------------------------------------------------
select set_config('fluvi.today', '2026-11-10', true);
reset role;
select pg_temp.put('cycle', (select id from public.billing_cycles where card_id = pg_temp.id('card') and closes_on = '2026-11-05'));
select pg_temp.put('bill', private.close_cycle(pg_temp.id('cycle')));  -- como o job de fechamento faria
select is((select original_amount_cents from public.obligations where id = pg_temp.id('bill')), 10000::bigint,
  'FIN-03: a primeira fatura traz só a parcela 1 (R$ 100)');
select pg_temp.login('00000000-0000-0000-0000-0000000000b1');
select lives_ok($$ select public.settle_obligation(gen_random_uuid(), pg_temp.id('bill'), pg_temp.id('bank'), 10000, '2026-11-10') $$,
  'FIN-03: Bia (mesma família) paga a fatura com a conta criada por Luck');
select is(public.account_balance(pg_temp.id('bank')), 175000::bigint, 'FIN-03: caixa −R$ 100');
select is(pg_temp.debt('card'), 50000::bigint, 'FIN-03: dívida −R$ 100');
select pg_temp.login('00000000-0000-0000-0000-0000000000b1');
select is((select card_purchases_net_cents + direct_expenses_cents from public.competence_summary('00000000-0000-0000-0000-0000000000f1', '2026-10-01')),
  75000::bigint, 'FIN-03: consumo de outubro continua R$ 750 (o pagamento não é gasto novo)');
select is((select card_purchases_net_cents + direct_expenses_cents from public.competence_summary('00000000-0000-0000-0000-0000000000f1', '2026-11-01')),
  0::bigint, 'FIN-03: o pagamento em novembro não cria consumo em novembro');

-- ---------------------------------------------------------------------------
-- FIN-04: R$ 100,01 em 3 parcelas → soma exata R$ 100,01
-- ---------------------------------------------------------------------------
select pg_temp.put('p10001', (public.create_card_purchase(gen_random_uuid(), pg_temp.id('card'), 10001, 3,
  'Livros', pg_temp.cat('Educação'), '2026-11-10') ->> 'id')::uuid);
select is((select array_agg(i.amount_cents order by i.sequence) from public.installments i
             join public.card_purchases p on p.id = i.purchase_id where p.transaction_id = pg_temp.id('p10001')),
  array[3334, 3334, 3333]::bigint[], 'FIN-04: 33,34 + 33,34 + 33,33');
select is((select sum(i.amount_cents)::bigint from public.installments i
             join public.card_purchases p on p.id = i.purchase_id where p.transaction_id = pg_temp.id('p10001')),
  10001::bigint, 'FIN-04: soma exata R$ 100,01');

-- FF-05: de 1 a 36 parcelas
select throws_ok($$ select public.create_card_purchase(gen_random_uuid(), pg_temp.id('card'), 3700, 37,
  'x', pg_temp.cat('Outros'), '2026-11-10') $$, '23514', null, 'FF-05: 37 parcelas são recusadas');
select lives_ok($$ select public.create_card_purchase(gen_random_uuid(), pg_temp.id('card'), 3600, 36,
  'x', pg_temp.cat('Outros'), '2026-11-10') $$, 'FF-05: 36 parcelas são aceitas');

-- ---------------------------------------------------------------------------
-- FIN-05: transferência entre contas não altera o saldo total da família
-- ---------------------------------------------------------------------------
select pg_temp.put('poup', (public.create_account(gen_random_uuid(), '00000000-0000-0000-0000-0000000000f1',
  'Poupança', 'savings', '2026-10-01', 50000) ->> 'id')::uuid);
select is((select sum(balance_cents)::bigint from public.v_account_balances where type <> 'credit_card'),
  225000::bigint, 'FIN-05: total antes = R$ 1.750 + R$ 500');
select public.transfer_funds(gen_random_uuid(), pg_temp.id('bank'), pg_temp.id('poup'), 30000, '2026-11-10');
select is((select sum(balance_cents)::bigint from public.v_account_balances where type <> 'credit_card'),
  225000::bigint, 'FIN-05: total depois da transferência é o mesmo');
select is(public.account_balance(pg_temp.id('poup')), 80000::bigint, 'FIN-05: a poupança recebeu R$ 300');

-- ---------------------------------------------------------------------------
-- FAM-01 / FAM-02 pela API
-- ---------------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-0000000000a1');
select is((select count(*)::int from public.transactions where family_id = '00000000-0000-0000-0000-0000000000f1'),
  (select count(*)::int from public.transactions), 'FAM-01: Luck lê só a própria família');
select pg_temp.login('00000000-0000-0000-0000-0000000000c1');
select is((select count(*)::int from public.v_account_balances) + (select count(*)::int from public.transactions)
          + (select count(*)::int from public.credit_cards), 0, 'FAM-02: a família 2 não vê nada da família 1');
select throws_ok($$ select public.create_transaction(gen_random_uuid(), '00000000-0000-0000-0000-0000000000f1',
  'expense', pg_temp.id('bank'), 100, 'x', pg_temp.cat('Outros'), '2026-11-10') $$,
  'P0002', 'não encontrado ou sem permissão', 'FAM-02: não registra em família alheia (mesmo erro de inexistente)');

select * from finish();
rollback;
