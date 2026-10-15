-- Fluvi — Marco B — Obrigações, competência × liquidação, estornos e recorrências.
-- Oráculos: O6, O7, O11, O17, O27, O28, O29, O30, O38 (+ O9 mapeado: reversão de compra no cartão recusada).
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(45);

delete from public.administrators;
insert into auth.users (id, instance_id, aud, role, email) values
  ('00000000-0000-0000-0000-00000000001c', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'luck@fluvi.test');
update public.profiles set provisioned_at = now() where user_id = '00000000-0000-0000-0000-00000000001c';
update auth.users set email_confirmed_at = now(), encrypted_password = 'x' where id = '00000000-0000-0000-0000-00000000001c';

create temp table k (name text primary key, id uuid);
grant all on k to public;
create function pg_temp.put(p text, v uuid) returns uuid language sql as $$
  insert into k (name, id) values (p, v) on conflict (name) do update set id = excluded.id returning id $$;
create function pg_temp.id(p text) returns uuid language sql as $$ select id from k where name = p $$;
create function pg_temp.cat(p text, kind public.category_kind default 'expense') returns uuid language sql as $$
  select id from public.categories where owner_user_id is null and name = p and kind = kind $$;
create function pg_temp.day(d date) returns void language sql as $$ select set_config('fluvi.today', d::text, true) $$;
create function pg_temp.luck() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-00000000001c","role":"authenticated","aal":"aal1"}', true);
  execute 'set local role authenticated';
end $$;
create function pg_temp.su() returns void language plpgsql as $$ begin execute 'reset role'; end $$;
create function pg_temp.eq(p_card text) returns bigint language plpgsql as $$
declare v bigint;
begin
  execute 'reset role';
  select difference_cents into v from private.card_reconciliation(pg_temp.id(p_card));
  return v;
end $$;
-- componentes de competência (como Luck)
create function pg_temp.comp(p_month date, p_field text) returns bigint language plpgsql as $$
declare v bigint;
begin
  perform pg_temp.luck();
  execute format('select %I from public.competence_summary(%L, %L)', p_field, '00000000-0000-0000-0000-00000000001c', p_month) into v;
  return v;
end $$;
create function pg_temp.obl(p_id text, p_field text) returns text language plpgsql as $$
declare v text;
begin
  perform pg_temp.luck();
  execute format('select %I::text from public.v_obligations_status where id = %L', p_field, pg_temp.id(p_id)) into v;
  return v;
end $$;

select pg_temp.day('2026-10-15');
select pg_temp.luck();
select pg_temp.put('bank', (public.create_account(gen_random_uuid(), '00000000-0000-0000-0000-00000000001c',
  'Banco', 'checking', '2026-01-01', 1000000) ->> 'id')::uuid);

-- ---------------------------------------------------------------------------
-- O6: pagamento parcial e atraso independentes
-- ---------------------------------------------------------------------------
select pg_temp.put('o6', (public.create_obligation(gen_random_uuid(), '00000000-0000-0000-0000-00000000001c', 'bill',
  'Escola', pg_temp.cat('Educação'), 50000, '2026-10-20') ->> 'id')::uuid);
select pg_temp.luck();
select public.settle_obligation(gen_random_uuid(), pg_temp.id('o6'), pg_temp.id('bank'), 20000, '2026-10-15');
select is(pg_temp.obl('o6', 'remaining_cents'), '30000', 'O6: devido 500, pago 200 → restante 300');
select is(pg_temp.obl('o6', 'settlement_status'), 'partial', 'O6: status parcial');
select is(pg_temp.obl('o6', 'is_overdue'), 'false', 'O6: no prazo');
select pg_temp.day('2026-10-21');
select is(pg_temp.obl('o6', 'is_overdue'), 'true', 'O6: após o vencimento é atrasada mesmo parcial');
select is(pg_temp.obl('o6', 'settlement_status'), 'partial', 'O6: continua parcial (atributos independentes)');
select pg_temp.day('2026-10-15');

-- regras de obrigação
select pg_temp.luck();
select throws_ok($$ select public.adjust_obligation(gen_random_uuid(), pg_temp.id('o6'), -40000, 'desconto') $$,
  '23514', null, 'ajuste não pode deixar o devido abaixo do já pago');
select throws_ok($$ select public.cancel_obligation(gen_random_uuid(), pg_temp.id('o6'), 'desistência') $$,
  '23514', null, 'obrigação com pagamento não é cancelada');

-- ---------------------------------------------------------------------------
-- O27 / O28: competência × liquidação, sem dupla contagem
-- ---------------------------------------------------------------------------
select pg_temp.put('o27', (public.create_obligation(gen_random_uuid(), '00000000-0000-0000-0000-00000000001c', 'bill',
  'Aluguel', pg_temp.cat('Moradia'), 50000, '2026-10-25', '2026-10-01') ->> 'id')::uuid);
select is(pg_temp.comp('2026-10-01', 'bills_recognized_cents'), 100000::bigint,
  'O27: despesa reconhecida na competência desde a criação (escola 500 + aluguel 500)');
select is(pg_temp.comp('2026-10-01', 'bills_paid_cents'), 20000::bigint, 'O27: pago até agora (só a escola)');
select pg_temp.luck();
select public.settle_obligation(gen_random_uuid(), pg_temp.id('o27'), pg_temp.id('bank'), 20000, '2026-10-15');
select pg_temp.day('2026-11-05');
select pg_temp.luck();
select pg_temp.put('pay300', (public.settle_obligation(gen_random_uuid(), pg_temp.id('o27'), pg_temp.id('bank'), 30000, '2026-11-05') ->> 'id')::uuid);
select is(pg_temp.comp('2026-10-01', 'bills_recognized_cents'), 100000::bigint,
  'O27: pagamentos não alteram o total reconhecido (INV-O5)');
select is(pg_temp.comp('2026-10-01', 'bills_to_pay_cents'), 30000::bigint, 'O27: a pagar = só o restante da escola');
select pg_temp.luck();
select is(public.account_balance(pg_temp.id('bank'), '2026-10-31'), 960000::bigint, 'O27: caixa de outubro −200 −200');
select is(public.account_balance(pg_temp.id('bank'), '2026-11-30'), 930000::bigint, 'O27: caixa de novembro −300');
select is((select count(*)::int from public.transactions where type = 'expense'), 0,
  'O27: pagamento de conta não cria despesa nova (sem dupla contagem)');

select pg_temp.luck();
select public.void_transaction(gen_random_uuid(), pg_temp.id('pay300'), 'pagamento lançado por engano');
select is(pg_temp.comp('2026-10-01', 'bills_recognized_cents'), 100000::bigint, 'O28: reconhecido continua o mesmo');
select is(pg_temp.obl('o27', 'remaining_cents'), '30000', 'O28: aluguel volta a ter 300 a pagar');
select is(pg_temp.obl('o27', 'settlement_status'), 'partial', 'O28: status parcial');
select pg_temp.luck();
select is(public.account_balance(pg_temp.id('bank'), '2026-11-30'), 960000::bigint, 'O28: caixa de novembro sem os 300');

-- ---------------------------------------------------------------------------
-- O38: obrigação futura distinguível
-- ---------------------------------------------------------------------------
select pg_temp.day('2026-10-15');
select pg_temp.luck();
select pg_temp.put('o38', (public.create_obligation(gen_random_uuid(), '00000000-0000-0000-0000-00000000001c', 'bill',
  'Seguro', pg_temp.cat('Contas e serviços'), 50000, '2026-11-10', '2026-11-01') ->> 'id')::uuid);
select is(pg_temp.comp('2026-11-01', 'bills_future_cents'), 50000::bigint, 'O38: em outubro, novembro aparece como previsto');
select is(pg_temp.comp('2026-11-01', 'bills_recognized_cents'), 0::bigint, 'O38: ainda não reconhecido');
select pg_temp.day('2026-11-02');
select is(pg_temp.comp('2026-11-01', 'bills_to_pay_cents'), 50000::bigint, 'O38: em novembro, reconhecido a pagar');
select pg_temp.luck();
select public.settle_obligation(gen_random_uuid(), pg_temp.id('o38'), pg_temp.id('bank'), 50000, '2026-11-02');
select is(pg_temp.comp('2026-11-01', 'bills_paid_cents'), 50000::bigint, 'O38: reconhecido pago');
select is(pg_temp.comp('2026-11-01', 'recognized_total_cents'), 50000::bigint, 'O38: total reconhecido 500, nunca 1.000');

-- ---------------------------------------------------------------------------
-- O7 / O17: estornos
-- ---------------------------------------------------------------------------
select pg_temp.day('2026-10-15');
select pg_temp.luck();
select pg_temp.put('e7', (public.create_transaction(gen_random_uuid(), '00000000-0000-0000-0000-00000000001c', 'expense',
  pg_temp.id('bank'), 30000, 'Tênis', pg_temp.cat('Vestuário'), '2026-10-10') ->> 'id')::uuid);
select public.refund_transaction(gen_random_uuid(), pg_temp.id('e7'), 10000, '2026-10-14');
select is(pg_temp.comp('2026-10-01', 'direct_expenses_cents'), 20000::bigint, 'O7: compra 300 − estorno 100 = 200 de consumo');
select is((select count(*)::int from public.transactions where type = 'income'), 0, 'O7: estorno não é receita');
select pg_temp.luck();
select throws_ok($$ select public.refund_transaction(gen_random_uuid(), pg_temp.id('e7'), 20001, '2026-10-14') $$,
  '23514', null, 'O17: estornos acima do valor estornável são recusados');
select throws_ok($$ select public.void_transaction(gen_random_uuid(), pg_temp.id('e7'), 'erro de digitação') $$,
  '23514', null, 'INV-R3: operação com estorno ativo não é anulada');

-- ---------------------------------------------------------------------------
-- O29 / O30 / O9: reversões no cartão
-- ---------------------------------------------------------------------------
select pg_temp.day('2026-10-10');
select pg_temp.luck();
select pg_temp.put('c', (public.create_card(gen_random_uuid(), '00000000-0000-0000-0000-00000000001c', 'Cartão', 5, 15) ->> 'id')::uuid);
select pg_temp.put('p29', (public.create_card_purchase(gen_random_uuid(), pg_temp.id('c'), 30000, 1, 'Fone',
  pg_temp.cat('Lazer'), '2026-10-10') ->> 'id')::uuid);
select pg_temp.put('r29', (public.refund_transaction(gen_random_uuid(), pg_temp.id('p29'), 10000, '2026-10-12') ->> 'id')::uuid);
select is((select net_cents from public.v_purchase_net where transaction_id = pg_temp.id('p29')), 20000::bigint,
  'O29: líquido 200 após estorno');
select public.reverse_transaction(gen_random_uuid(), pg_temp.id('r29'), '2026-10-20', 'banco desfez o estorno');
select is((select net_cents from public.v_purchase_net where transaction_id = pg_temp.id('p29')), 30000::bigint,
  'O29: reversão do estorno volta o líquido a 300');
select is(pg_temp.eq('c'), 0::bigint, 'O29: EQ-1 após reversão do estorno');

select pg_temp.day('2026-11-06');
select pg_temp.su();
select pg_temp.put('ob30', private.close_cycle((select id from public.billing_cycles where card_id = pg_temp.id('c') and closes_on = '2026-11-05')));
select pg_temp.luck();
select pg_temp.put('pay30', (public.settle_obligation(gen_random_uuid(), pg_temp.id('ob30'), pg_temp.id('bank'), 30000, '2026-11-06') ->> 'id')::uuid);
select is(pg_temp.obl('ob30', 'settlement_status'), 'paid', 'O30: fatura paga');
select pg_temp.day('2026-11-08');
select pg_temp.luck();
select public.reverse_transaction(gen_random_uuid(), pg_temp.id('pay30'), '2026-11-08', 'pagamento devolvido pelo banco');
select is(pg_temp.obl('ob30', 'settlement_status'), 'open', 'O30: fatura reabre');
select pg_temp.luck();
select is(public.account_balance(pg_temp.id('bank'), '2026-11-08') - public.account_balance(pg_temp.id('bank'), '2026-11-07'),
  30000::bigint, 'O30: caixa +300 na data da reversão');
select is(pg_temp.comp('2026-10-01', 'card_purchases_net_cents'), 30000::bigint, 'O30: consumo inalterado');
select is(pg_temp.eq('c'), 0::bigint, 'O30: EQ-1 após reversão de pagamento');
select pg_temp.luck();
select throws_ok($$ select public.reverse_transaction(gen_random_uuid(), pg_temp.id('p29'), '2026-11-08', 'devolução') $$,
  '23514', null, 'O9: compra no cartão não é "revertida": usa estorno ou ajuste');

-- ---------------------------------------------------------------------------
-- O11: recorrências idempotentes; pausa; "esta e as futuras"
-- ---------------------------------------------------------------------------
select pg_temp.day('2026-10-15');
-- isola o gerador de dados de outras suítes (revertido ao fim da transação)
select pg_temp.su();
update public.recurrence_rules set status = 'paused' where status = 'active';
select pg_temp.luck();
select pg_temp.put('rule', (public.create_recurrence_rule(gen_random_uuid(), '00000000-0000-0000-0000-00000000001c', 'bill',
  'Streaming', pg_temp.cat('Assinaturas'), 4990, 'monthly', 31, '2026-10-01') ->> 'id')::uuid);
select pg_temp.su();
select is(private.generate_occurrences('2026-12-14'), 2, 'horizonte por vencimento: até 14/12 gera out e nov (dez vence 31/12)');
select is(private.generate_occurrences('2026-12-31'), 1, 'estendendo o horizonte, só dezembro é acrescentado');
select is(private.generate_occurrences('2026-12-31'), 0, 'O11: rodar de novo não duplica');
select is((select array_agg(due_date order by due_date) from public.obligations o join public.recurrence_occurrences r on r.id = o.occurrence_id
            where r.rule_id = pg_temp.id('rule')),
  array['2026-10-31', '2026-11-30', '2026-12-31']::date[], 'dia 31 ajustado ao fim de cada mês');
select pg_temp.luck();
select public.update_recurrence_amount(gen_random_uuid(), pg_temp.id('rule'), 5990, '2026-11');
select is((select array_agg(o.original_amount_cents + o.adjustments_cents order by o.due_date) from public.obligations o
            join public.recurrence_occurrences r on r.id = o.occurrence_id where r.rule_id = pg_temp.id('rule')),
  array[4990, 5990, 5990]::bigint[], '"esta e as futuras": só novembro em diante muda');
select public.set_recurrence_status(gen_random_uuid(), pg_temp.id('rule'), 'paused');
select pg_temp.su();
select is(private.generate_occurrences('2027-03-31'), 0, 'regra pausada não gera ocorrências');

-- receivable: receita só quando liquida
select pg_temp.luck();
select pg_temp.put('rec', (public.create_obligation(gen_random_uuid(), '00000000-0000-0000-0000-00000000001c', 'receivable',
  'Salário', pg_temp.cat('Salário', 'income'), 800000, '2026-10-30') ->> 'id')::uuid);
select is(pg_temp.comp('2026-10-01', 'receivable_forecast_cents'), 800000::bigint, 'previsão de receita separada');
select is((select count(*)::int from public.transactions where type = 'income'), 0, 'previsão não é receita realizada');
select pg_temp.luck();
select public.settle_obligation(gen_random_uuid(), pg_temp.id('rec'), pg_temp.id('bank'), 800000, '2026-10-15');
select is((select count(*)::int from public.transactions where type = 'income'), 1, 'recebimento gera receita realizada');

select * from finish();
rollback;
