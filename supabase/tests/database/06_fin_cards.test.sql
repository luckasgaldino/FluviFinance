-- Fluvi — Marco B — Cartões, ciclos, parcelas, créditos e conciliação EQ-1 (§17.1).
-- Oráculos: O3, O4, O5, O10, O12, O18, O18b, O20, O20b, O20c, O21, O21b, O22, O23, O36, O39, O39b, O41, O42.
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(65);

-- ---------------------------------------------------------------------------
-- Fixtures: Luck (titular)
-- ---------------------------------------------------------------------------
delete from public.administrators;
insert into auth.users (id, instance_id, aud, role, email) values
  ('00000000-0000-0000-0000-00000000001c', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'luck@fluvi.test');
update public.profiles set provisioned_at = now() where user_id = '00000000-0000-0000-0000-00000000001c';
update auth.users set email_confirmed_at = now(), encrypted_password = 'x' where id = '00000000-0000-0000-0000-00000000001c';
-- v2.2: a família é a titular; aqui com o mesmo UUID do Luck, para manter as fixtures legíveis.
insert into public.households (id, name) values ('00000000-0000-0000-0000-00000000001c', 'Família do Luck');
insert into public.household_members (household_id, user_id) values ('00000000-0000-0000-0000-00000000001c', '00000000-0000-0000-0000-00000000001c');

create temp table k (name text primary key, id uuid);
grant all on k to public;
create function pg_temp.put(p text, v uuid) returns uuid language sql as $$
  insert into k (name, id) values (p, v) on conflict (name) do update set id = excluded.id returning id $$;
create function pg_temp.id(p text) returns uuid language sql as $$ select id from k where name = p $$;
create function pg_temp.cat() returns uuid language sql as $$
  select id from public.categories where family_id is null and name = 'Mercado' and kind = 'expense' $$;
create function pg_temp.day(d date) returns void language sql as $$ select set_config('fluvi.today', d::text, true) $$;
create function pg_temp.luck() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000001c","role":"authenticated","aal":"aal1"}', true);
  execute 'set local role authenticated';
end $$;
create function pg_temp.su() returns void language plpgsql as $$ begin execute 'reset role'; end $$;
-- ciclo do cartão que fecha na data
create function pg_temp.cy(p_card text, p_close date) returns uuid language sql as $$
  select id from public.billing_cycles where card_id = pg_temp.id(p_card) and closes_on = p_close $$;
-- diferença da EQ-1 (rodando como dono do banco)
create function pg_temp.eq(p_card text) returns bigint language plpgsql as $$
declare v bigint;
begin
  execute 'reset role';
  select difference_cents into v from private.card_reconciliation(pg_temp.id(p_card));
  return v;
end $$;
create function pg_temp.purchase(p_card text, p_amount bigint, p_n int, p_date date, p_desc text default 'Compra')
returns uuid language plpgsql as $$
begin
  perform pg_temp.luck();
  return (public.create_card_purchase(gen_random_uuid(), pg_temp.id(p_card), p_amount, p_n, p_desc, pg_temp.cat(), p_date) ->> 'id')::uuid;
end $$;
create function pg_temp.close(p_card text, p_close date) returns uuid language plpgsql as $$
begin
  execute 'reset role';
  return private.close_cycle(pg_temp.cy(p_card, p_close));
end $$;
create function pg_temp.card(p_name text, p_close int, p_due int, p_policy public.closing_day_policy default 'current_cycle')
returns uuid language plpgsql as $$
begin
  perform pg_temp.luck();
  return (public.create_card(gen_random_uuid(), '00000000-0000-0000-0000-00000000001c', p_name, p_close, p_due,
    1000000, p_policy, 'Visa', '1234', '2026-01-01') ->> 'id')::uuid;
end $$;

select pg_temp.day('2026-10-15');
select pg_temp.luck();
select pg_temp.put('bank', (public.create_account(gen_random_uuid(), '00000000-0000-0000-0000-00000000001c',
  'Banco', 'checking', '2026-01-01', 1000000) ->> 'id')::uuid);
select pg_temp.put('c1', pg_temp.card('Cartão 1', 5, 15));

-- ---------------------------------------------------------------------------
-- O3 / O4: parcelamento e centavos
-- ---------------------------------------------------------------------------
select pg_temp.put('p3', pg_temp.purchase('c1', 120000, 6, '2026-10-10', 'TV'));
select is((select array_agg(i.amount_cents order by i.sequence) from public.installments i
             join public.card_purchases p on p.id = i.purchase_id where p.transaction_id = pg_temp.id('p3')),
  array[20000, 20000, 20000, 20000, 20000, 20000]::bigint[], 'O3: 6 parcelas de R$ 200');
select is((select array_agg(c.closes_on order by i.sequence) from public.installments i
             join public.card_purchases p on p.id = i.purchase_id join public.billing_cycles c on c.id = i.billing_cycle_id
            where p.transaction_id = pg_temp.id('p3')),
  array['2026-11-05', '2026-12-05', '2027-01-05', '2027-02-05', '2027-03-05', '2027-04-05']::date[],
  'O3: compra de 10/10 (fechamento dia 5) começa no ciclo de 05/11');
select is((select due_on from public.billing_cycles where id = pg_temp.cy('c1', '2026-11-05')), '2026-11-15'::date,
  'vencimento = primeiro dia 15 após o fechamento');
select is((select card_purchases_net_cents from public.competence_summary('00000000-0000-0000-0000-00000000001c', '2026-10-01')),
  120000::bigint, 'O3: consumo +R$ 1.200 uma única vez na competência');
select is(pg_temp.eq('c1'), 0::bigint, 'EQ-1 após compra parcelada');

select pg_temp.put('c4', pg_temp.card('Cartão centavos', 5, 15));
select pg_temp.put('p4', pg_temp.purchase('c4', 10000, 3, '2026-10-10'));
select is((select array_agg(i.amount_cents order by i.sequence) from public.installments i
             join public.card_purchases p on p.id = i.purchase_id where p.transaction_id = pg_temp.id('p4')),
  array[3334, 3333, 3333]::bigint[], 'O4: R$ 100 em 3x = 33,34 + 33,33 + 33,33');

-- ---------------------------------------------------------------------------
-- O18 / O18b / O12: política do dia do fechamento e fim de mês
-- ---------------------------------------------------------------------------
select pg_temp.put('p18', pg_temp.purchase('c1', 1000, 1, '2026-11-05'));
select is((select c.closes_on from public.installments i join public.card_purchases p on p.id = i.purchase_id
             join public.billing_cycles c on c.id = i.billing_cycle_id where p.transaction_id = pg_temp.id('p18')),
  '2026-11-05'::date, 'O18: política current_cycle — compra no dia do fechamento entra no ciclo que fecha');
select pg_temp.put('c2', pg_temp.card('Cartão next', 5, 15, 'next_cycle'));
select pg_temp.put('p18b', pg_temp.purchase('c2', 1000, 1, '2026-11-05'));
select is((select c.closes_on from public.installments i join public.card_purchases p on p.id = i.purchase_id
             join public.billing_cycles c on c.id = i.billing_cycle_id where p.transaction_id = pg_temp.id('p18b')),
  '2026-12-05'::date, 'O18b: política next_cycle — compra no dia do fechamento vai para o ciclo seguinte');

select pg_temp.put('c31', pg_temp.card('Cartão 31', 31, 10));
select pg_temp.put('p12', pg_temp.purchase('c31', 1000, 1, '2028-02-10'));
select is((select c.closes_on from public.installments i join public.card_purchases p on p.id = i.purchase_id
             join public.billing_cycles c on c.id = i.billing_cycle_id where p.transaction_id = pg_temp.id('p12')),
  '2028-02-29'::date, 'O12: fechamento dia 31 em fevereiro de 2028 (bissexto) = 29/02');
select is((select starts_on from public.billing_cycles where id = pg_temp.cy('c31', '2028-02-29')), '2028-02-01'::date,
  'O12: ciclo começa no dia seguinte ao fechamento anterior (31/01)');

-- ---------------------------------------------------------------------------
-- O5 / O10: fechamento, pagamento de fatura, mudança de regra com ciclo pago
-- ---------------------------------------------------------------------------
select pg_temp.day('2026-11-06');
select pg_temp.put('ob5', pg_temp.close('c1', '2026-11-05'));
select is((select original_amount_cents from public.obligations where id = pg_temp.id('ob5')), 21000::bigint,
  'fechamento cria a fatura com o valor do ciclo (200 + 10)');
select pg_temp.luck();
select public.settle_obligation(gen_random_uuid(), pg_temp.id('ob5'), pg_temp.id('bank'), 21000, '2026-11-06');
select is(public.account_balance(pg_temp.id('bank')), 979000::bigint, 'O5: caixa −R$ 210');
select is((select debt_total_cents from public.v_card_position where card_id = pg_temp.id('c1')), 100000::bigint,
  'O5: dívida −R$ 210 (1.210 → 1.000)');
select is((select card_purchases_net_cents from public.competence_summary('00000000-0000-0000-0000-00000000001c', '2026-10-01')),
  130000::bigint, 'O5: pagamento de fatura não altera o consumo (1.200 + 100 do cartão de centavos)');
select is((select is_paid from public.v_card_cycles where cycle_id = pg_temp.cy('c1', '2026-11-05')), true, 'O5: ciclo pago');
select is(pg_temp.eq('c1'), 0::bigint, 'EQ-1 após fechamento e pagamento');
select pg_temp.luck();
select throws_ok($$ select public.settle_obligation(gen_random_uuid(), pg_temp.id('ob5'), pg_temp.id('bank'), 1, '2026-11-11') $$,
  '23514', null, 'MB-06: pagamento acima do devido é recusado');

select public.update_card_rules(gen_random_uuid(), pg_temp.id('c1'), 5, 20, 'current_cycle', 1000000);
select is((select due_on from public.billing_cycles where id = pg_temp.cy('c1', '2026-11-05')), '2026-11-15'::date,
  'O10: ciclo pago mantém o vencimento histórico');
select is((select due_on from public.billing_cycles where id = pg_temp.cy('c1', '2026-12-05')), '2026-12-20'::date,
  'O10: ciclo aberto recalculado com o novo vencimento');
select is(pg_temp.eq('c1'), 0::bigint, 'EQ-1 após mudança de regra');

-- ---------------------------------------------------------------------------
-- O20 / O20b / O20c: datas confirmadas pelo banco
-- ---------------------------------------------------------------------------
select pg_temp.put('p20', pg_temp.purchase('c1', 5000, 1, '2026-12-05', 'Compra no dia 05/12'));
select pg_temp.su();
select pg_temp.put('n_ledger', null);
select pg_temp.luck();
select public.confirm_billing_cycle(gen_random_uuid(), pg_temp.cy('c1', '2026-12-05'), '2026-12-04', '2026-12-14', 25000);
select is((select c.closes_on from public.installments i join public.card_purchases p on p.id = i.purchase_id
             join public.billing_cycles c on c.id = i.billing_cycle_id where p.transaction_id = pg_temp.id('p20')),
  '2027-01-05'::date, 'O20: fechamento confirmado em 04/12 leva a compra de 05/12 para o ciclo seguinte');
select is((select date_source::text from public.billing_cycles where closes_on = '2026-12-04' and card_id = pg_temp.id('c1')),
  'confirmed', 'O20: ciclo marcado como confirmado');
select is((select starts_on from public.billing_cycles where id = pg_temp.cy('c1', '2027-01-05')), '2026-12-05'::date,
  'O20: ciclo seguinte começa no dia seguinte ao fechamento confirmado');
select is((select difference_cents from public.cycle_discrepancies), 5000::bigint,
  'O20c: banco informa 250, sistema calcula 200 — divergência de R$ 50 registrada');
select is((select count(*)::int from public.transactions where description like 'Ajuste%'), 0,
  'O20c: nenhuma movimentação compensatória criada');
select is(pg_temp.eq('c1'), 0::bigint, 'EQ-1 após confirmação');
select pg_temp.luck();
select throws_ok($$ select public.confirm_billing_cycle(gen_random_uuid(), pg_temp.cy('c1', '2026-11-05'), '2026-11-04', '2026-11-14') $$,
  '23514', null, 'O20b: ciclo fechado/pago não aceita confirmação');
select pg_temp.su();
select throws_ok($$ update public.billing_cycles set closes_on = '2026-12-03' where card_id = pg_temp.id('c1') and closes_on = '2026-12-04' $$,
  '23514', null, 'datas confirmadas são imutáveis');
select throws_ok($$ update public.installments set amount_cents = 1
                     where billing_cycle_id = pg_temp.cy('c1', '2026-11-05') $$,
  '23514', null, 'INV-C5: parcela de ciclo fechado é imutável');

-- ---------------------------------------------------------------------------
-- O21 / O21b / O22 / O41 / O42: ajuste de parcelas
-- ---------------------------------------------------------------------------
select pg_temp.day('2026-08-10');
select pg_temp.put('c3', pg_temp.card('Cartão ajuste', 5, 15));
select pg_temp.put('p21', pg_temp.purchase('c3', 120000, 6, '2026-08-10', 'Notebook'));
select pg_temp.day('2026-10-06');
select pg_temp.close('c3', '2026-09-05');
select pg_temp.close('c3', '2026-10-05');
select pg_temp.luck();
select public.adjust_installments(gen_random_uuid(), pg_temp.id('p21'), 120000, 3, 'renegociação com o banco');
select is((select array_agg(i.amount_cents order by i.sequence) from public.installments i
             join public.card_purchases p on p.id = i.purchase_id
            where p.transaction_id = pg_temp.id('p21') and i.status = 'valid'),
  array[20000, 20000, 26667, 26667, 26666]::bigint[], 'O21: 2 faturadas intactas + 800 em 3 (266,67 + 266,67 + 266,66)');
select is((select count(*)::int from public.installments i join public.card_purchases p on p.id = i.purchase_id
            where p.transaction_id = pg_temp.id('p21') and i.status = 'superseded'), 4,
  'O21: 4 parcelas abertas antigas preservadas como superseded (histórico)');
select is(pg_temp.eq('c3'), 0::bigint, 'EQ-1 após ajuste sem mudança de total');
select pg_temp.luck();
select throws_ok($$ select public.adjust_installments(gen_random_uuid(), pg_temp.id('p21'), 120000, 0, 'x') $$,
  '23514', null, 'O21b: ajuste que não fecha (saldo a parcelar sem parcelas) é recusado');
select throws_ok($$ select public.adjust_installments(gen_random_uuid(), pg_temp.id('p21'), 30000, 1, 'x') $$,
  '23514', null, 'O42: novo total menor que as parcelas faturadas é recusado');

select public.adjust_installments(gen_random_uuid(), pg_temp.id('p21'), 110000, 3, 'desconto confirmado pelo banco');
select is((select sum(i.amount_cents)::bigint from public.installments i join public.card_purchases p on p.id = i.purchase_id
            where p.transaction_id = pg_temp.id('p21') and i.status = 'valid'), 110000::bigint,
  'O22: parcelas válidas fecham com o novo total');
select is((select amount_cents from public.transactions where type = 'installment_adjustment'
            and reverses_transaction_id = pg_temp.id('p21')), 10000::bigint,
  'O22: diferença registrada como ajuste no razão do cartão');
select is((select debt_total_cents from public.v_card_position where card_id = pg_temp.id('c3')), 110000::bigint,
  'O22: dívida acompanha o novo total');
select is(pg_temp.eq('c3'), 0::bigint, 'EQ-1 após ajuste com redução de total');

-- O41: estorno aplicado ao ciclo aberto e ajuste que deixaria crédito > débito
select pg_temp.luck();
select public.refund_transaction(gen_random_uuid(), pg_temp.id('p21'), 20000, '2026-10-12');
select pg_temp.luck();
select throws_ok($$ select public.adjust_installments(gen_random_uuid(), pg_temp.id('p21'), 43000, 3, 'x') $$,
  '23514', null, 'O41: ajuste que deixaria crédito aplicado maior que o débito do ciclo é recusado');
select is((select total_cents from public.card_purchases where transaction_id = pg_temp.id('p21')), 110000::bigint,
  'O41: nada foi gravado');

-- ---------------------------------------------------------------------------
-- O23: crédito maior que a prévia — excedente consumido pelos ciclos seguintes
-- ---------------------------------------------------------------------------
select pg_temp.day('2026-10-10');
select pg_temp.put('c5', pg_temp.card('Cartão crédito', 5, 15));
select pg_temp.put('p23', pg_temp.purchase('c5', 60000, 2, '2026-10-10'));
select pg_temp.luck();
select public.refund_transaction(gen_random_uuid(), pg_temp.id('p23'), 50000, '2026-10-12');
select is((select amount_cents from public.v_card_cycles where cycle_id = pg_temp.cy('c5', '2026-11-05')), 0::bigint,
  'O23: ciclo aberto zerado pelo crédito');
select is((select unapplied_credit_cents from public.v_card_position where card_id = pg_temp.id('c5')), 20000::bigint,
  'O23: R$ 200 de crédito não aplicado');
select pg_temp.day('2026-11-06');
select pg_temp.put('o23a', pg_temp.close('c5', '2026-11-05'));
select pg_temp.day('2026-12-06');
select pg_temp.put('o23b', pg_temp.close('c5', '2026-12-05'));
select is((select original_amount_cents from public.obligations where id = pg_temp.id('o23b')), 10000::bigint,
  'O23: excedente consumido no ciclo seguinte (300 − 200 = 100)');
select is((select count(*)::int from public.installments i join public.card_purchases p on p.id = i.purchase_id
            where p.transaction_id = pg_temp.id('p23') and i.status = 'valid'), 2,
  'O23: parcelas futuras intactas (estorno não cancela parcelas)');
select is(pg_temp.eq('c5'), 0::bigint, 'EQ-1 após crédito com excedente');

-- ---------------------------------------------------------------------------
-- O39 / O39b: reversão de crédito com parte consumida por fatura paga
-- ---------------------------------------------------------------------------
select pg_temp.day('2026-10-02');
select pg_temp.put('c6', pg_temp.card('Cartão reversão', 5, 15));
select pg_temp.put('p39', pg_temp.purchase('c6', 50000, 1, '2026-10-01'));
select pg_temp.day('2026-10-06');
select pg_temp.put('o39a', pg_temp.close('c6', '2026-10-05'));
select pg_temp.luck();
select public.settle_obligation(gen_random_uuid(), pg_temp.id('o39a'), pg_temp.id('bank'), 50000, '2026-10-10');
select pg_temp.put('q39', pg_temp.purchase('c6', 30000, 1, '2026-10-10'));
select pg_temp.luck();
select pg_temp.put('r39', (public.refund_transaction(gen_random_uuid(), pg_temp.id('p39'), 50000, '2026-10-12') ->> 'id')::uuid);
select pg_temp.day('2026-11-06');
select pg_temp.put('o39b', pg_temp.close('c6', '2026-11-05'));
select is((select is_paid from public.v_card_cycles where cycle_id = pg_temp.cy('c6', '2026-11-05')), true,
  'O39: 300 aplicados ao ciclo 05/11, que fecha zerado (pago)');
select is((select unapplied_credit_cents from public.v_card_position where card_id = pg_temp.id('c6')), 20000::bigint,
  'O39: 200 não aplicados');
select pg_temp.luck();
select throws_ok($$ select public.void_transaction(gen_random_uuid(), pg_temp.id('r39'), 'lançado por engano') $$,
  '23514', null, 'O39b: anular estorno com aplicação em ciclo pago é recusado');
select public.reverse_transaction(gen_random_uuid(), pg_temp.id('r39'), '2026-11-07', 'banco desfez o estorno');
select is((select unapplied_credit_cents from public.v_card_position where card_id = pg_temp.id('c6')), 0::bigint,
  'O39: não aplicado absorvido');
select is((select sum(amount_cents)::bigint from public.cycle_charges where billing_cycle_id = pg_temp.cy('c6', '2026-12-05')),
  30000::bigint, 'O39: os 300 consumidos viram encargo no ciclo aberto');
select is((select original_amount_cents from public.obligations where id = pg_temp.id('o39b')), 0::bigint,
  'O39: fatura paga intacta');
select is(pg_temp.eq('c6'), 0::bigint, 'EQ-1 após reversão de crédito');

-- ---------------------------------------------------------------------------
-- O36: sequência mista — EQ-1 após cada passo; INV-C9 e INV-C10
-- ---------------------------------------------------------------------------
select pg_temp.day('2026-10-10');
select pg_temp.put('c9', pg_temp.card('Cartão O36', 5, 15));
select pg_temp.put('a36', pg_temp.purchase('c9', 120000, 6, '2026-10-10', '6x'));
select is(pg_temp.eq('c9'), 0::bigint, 'O36 passo 1: compra 6x');
select pg_temp.luck();
select pg_temp.put('r36', (public.refund_transaction(gen_random_uuid(), pg_temp.id('a36'), 50000, '2026-10-12') ->> 'id')::uuid);
select is(pg_temp.eq('c9'), 0::bigint, 'O36 passo 2: estorno com excedente');
select pg_temp.put('b36', pg_temp.purchase('c9', 40000, 1, '2026-10-20', '1x'));
select is(pg_temp.eq('c9'), 0::bigint, 'O36 passo 3: nova compra no ciclo');
select pg_temp.day('2026-11-06');
select pg_temp.put('o36', pg_temp.close('c9', '2026-11-05'));
select is(pg_temp.eq('c9'), 0::bigint, 'O36 passo 4: fechamento (aplica crédito pendente)');
select pg_temp.luck();
select public.settle_obligation(gen_random_uuid(), pg_temp.id('o36'), pg_temp.id('bank'), 6000, '2026-11-08');
select is(pg_temp.eq('c9'), 0::bigint, 'O36 passo 5: pagamento parcial');
select pg_temp.luck();
select public.reverse_transaction(gen_random_uuid(), pg_temp.id('r36'), '2026-11-09', 'banco desfez');
select is(pg_temp.eq('c9'), 0::bigint, 'O36 passo 6: reversão do estorno');
select pg_temp.luck();
select public.adjust_installments(gen_random_uuid(), pg_temp.id('a36'), 120000, 4, 'renegociação');
select is(pg_temp.eq('c9'), 0::bigint, 'O36 passo 7: ajuste de parcelas abertas');
select pg_temp.put('d36', pg_temp.purchase('c9', 5000, 1, '2026-11-10', 'engano'));
select pg_temp.luck();
select public.void_transaction(gen_random_uuid(), pg_temp.id('d36'), 'lançada por engano');
select is(pg_temp.eq('c9'), 0::bigint, 'O36 passo 8: anulação de compra');
select pg_temp.luck();
select throws_ok($$ select public.void_transaction(gen_random_uuid(), pg_temp.id('b36'), 'x x') $$,
  '23514', null, 'O36: compra com parcela faturada não é anulável');
select pg_temp.su();
select is((select original_amount_cents from public.obligations where id = pg_temp.id('o36')),
          private.cycle_amount(pg_temp.cy('c9', '2026-11-05')), 'INV-C9: fatura fechada = valor do ciclo após toda a sequência');
select is((select count(*)::int from public.refunds r join public.transactions t on t.id = r.refund_transaction_id
             join public.financial_accounts a on a.id = t.account_id
            where a.type = 'credit_card'
              and not exists (select 1 from public.card_credits c where c.transaction_id = r.refund_transaction_id)), 0,
  'INV-C10: todo estorno no cartão tem crédito correspondente');
select is((select count(*)::int from public.card_credits c
            where not exists (select 1 from public.refunds r where r.refund_transaction_id = c.transaction_id)), 0,
  'INV-C10: todo crédito tem estorno correspondente');

-- varredura final: EQ-1 em todos os cartões
select is((select count(*)::int from public.credit_cards k
            where (private.card_reconciliation(k.id)).difference_cents <> 0), 0, 'EQ-1 vale para todos os cartões');

select * from finish();
rollback;
