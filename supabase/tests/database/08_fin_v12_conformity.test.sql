-- Fluvi — Marco B — Conformidade com a Especificação v1.2 (§20.17): C-1, C-2, C-3.
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(17);

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

delete from public.administrators;
insert into auth.users (id, instance_id, aud, role, email) values
  ('00000000-0000-0000-0000-00000000001c', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'luck@fluvi.test');
update public.profiles set provisioned_at = now() where user_id = '00000000-0000-0000-0000-00000000001c';
update auth.users set email_confirmed_at = now(), encrypted_password = 'x' where id = '00000000-0000-0000-0000-00000000001c';
-- v2.2: a família é a titular; aqui com o mesmo UUID do Luck, para manter as fixtures legíveis.
insert into public.households (id, name) values ('00000000-0000-0000-0000-00000000001c', 'Família do Luck');
insert into public.household_members (household_id, user_id) values ('00000000-0000-0000-0000-00000000001c', '00000000-0000-0000-0000-00000000001c');

create temp table k (name text primary key, id uuid, j jsonb);
grant all on k to public;
create function pg_temp.put(p text, v uuid) returns uuid language sql as $$
  insert into k (name, id) values (p, v) on conflict (name) do update set id = excluded.id returning id $$;
create function pg_temp.putj(p text, v jsonb) returns jsonb language sql as $$
  insert into k (name, j) values (p, v) on conflict (name) do update set j = excluded.j returning j $$;
create function pg_temp.id(p text) returns uuid language sql as $$ select id from k where name = p $$;
create function pg_temp.j(p text) returns jsonb language sql as $$ select j from k where name = p $$;
create function pg_temp.cat() returns uuid language sql as $$
  select id from public.categories where family_id is null and name = 'Mercado' and kind = 'expense' $$;
create function pg_temp.luck() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform pg_temp.unlock('00000000-0000-0000-0000-00000000001c'::uuid);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', '00000000-0000-0000-0000-00000000001c', 'role', 'authenticated', 'aal', 'aal1',
    'session_id', pg_temp.sid('00000000-0000-0000-0000-00000000001c'))::text, true);
  execute 'set local role authenticated';
end $$;
create function pg_temp.su() returns void language plpgsql as $$ begin execute 'reset role'; end $$;
create function pg_temp.cy(p_card text, p_close date) returns uuid language sql as $$
  select id from public.billing_cycles where card_id = pg_temp.id(p_card) and closes_on = p_close $$;
create function pg_temp.eq(p_card text) returns bigint language plpgsql as $$
declare v bigint;
begin
  execute 'reset role';
  select difference_cents into v from private.card_reconciliation(pg_temp.id(p_card));
  return v;
end $$;

select set_config('fluvi.today', '2026-10-15', true);
select pg_temp.luck();

-- ---------------------------------------------------------------------------
-- C-1 (§20.4): ajuste preserva parcelas de ciclo CONFIRMADO e não usa ciclo confirmado para as novas
-- ---------------------------------------------------------------------------
select pg_temp.put('c1', (public.create_card(gen_random_uuid(), '00000000-0000-0000-0000-00000000001c', 'Cartão C-1', 5, 15) ->> 'id')::uuid);
select pg_temp.put('p1', (public.create_card_purchase(gen_random_uuid(), pg_temp.id('c1'), 120000, 6, 'TV',
  pg_temp.cat(), '2026-10-10') ->> 'id')::uuid);
-- banco confirma o ciclo atual (05/11) e um futuro (05/01) com as mesmas datas
select public.confirm_billing_cycle(gen_random_uuid(), pg_temp.cy('c1', '2026-11-05'), '2026-11-05', '2026-11-15');
select public.confirm_billing_cycle(gen_random_uuid(), pg_temp.cy('c1', '2027-01-05'), '2027-01-05', '2027-01-15');
select pg_temp.put('i_nov', (select i.id from public.installments i where i.billing_cycle_id = pg_temp.cy('c1', '2026-11-05')));
select pg_temp.put('i_jan', (select i.id from public.installments i where i.billing_cycle_id = pg_temp.cy('c1', '2027-01-05')));

select throws_ok($$ select public.adjust_installments(gen_random_uuid(), pg_temp.id('p1'), 30000, 1, 'x') $$,
  '23514', null, 'C-1: novo total abaixo das parcelas preservadas (ciclos confirmados) é recusado');

select public.adjust_installments(gen_random_uuid(), pg_temp.id('p1'), 120000, 3, 'renegociação');
select is((select status::text from public.installments where id = pg_temp.id('i_nov')), 'valid',
  'C-1: parcela do ciclo confirmado atual preservada');
select is((select status::text from public.installments where id = pg_temp.id('i_jan')), 'valid',
  'C-1: parcela do ciclo confirmado futuro preservada');
select is((select array_agg(c.closes_on order by i.sequence) from public.installments i
             join public.billing_cycles c on c.id = i.billing_cycle_id
             join public.card_purchases p on p.id = i.purchase_id
            where p.transaction_id = pg_temp.id('p1') and i.status = 'valid' and i.revision = 2),
  array['2026-12-05', '2027-02-05', '2027-03-05']::date[],
  'C-1: parcelas novas só em ciclos estimados (pula o confirmado de 05/01)');
select is((select sum(i.amount_cents)::bigint from public.installments i join public.card_purchases p on p.id = i.purchase_id
            where p.transaction_id = pg_temp.id('p1') and i.status = 'valid'), 120000::bigint,
  'C-1: parcelas válidas fecham com o total');
select is((select count(*)::int from public.installments i
            where i.billing_cycle_id in (pg_temp.cy('c1', '2026-11-05'), pg_temp.cy('c1', '2027-01-05'))), 2,
  'C-1: nenhum item novo entrou em ciclo confirmado');
select is(pg_temp.eq('c1'), 0::bigint, 'C-1: EQ-1 = 0');

-- ---------------------------------------------------------------------------
-- C-2 (§20.9): recálculo preserva atribuição, valida e relata itens fora da janela
-- ---------------------------------------------------------------------------
select pg_temp.luck();
select pg_temp.put('c2', (public.create_card(gen_random_uuid(), '00000000-0000-0000-0000-00000000001c', 'Cartão C-2', 5, 15) ->> 'id')::uuid);
select pg_temp.put('p2', (public.create_card_purchase(gen_random_uuid(), pg_temp.id('c2'), 5000, 1, 'Compra em 04/11',
  pg_temp.cat(), '2026-11-04') ->> 'id')::uuid);
select pg_temp.put('p2b', (public.create_card_purchase(gen_random_uuid(), pg_temp.id('c2'), 7000, 2, 'Compra em 20/10',
  pg_temp.cat(), '2026-10-20') ->> 'id')::uuid);
select pg_temp.put('cy2', pg_temp.cy('c2', '2026-11-05'));
select pg_temp.putj('r2', public.update_card_rules(gen_random_uuid(), pg_temp.id('c2'), 3, 15, 'current_cycle', 1000000));

select is((select c.closes_on from public.billing_cycles c where c.id = pg_temp.id('cy2')), '2026-11-03'::date,
  'C-2: datas do ciclo aberto estimado recalculadas (fecha 03/11)');
select is((select i.billing_cycle_id from public.installments i join public.card_purchases p on p.id = i.purchase_id
            where p.transaction_id = pg_temp.id('p2')), pg_temp.id('cy2'),
  'C-2: atribuição histórica preservada (compra de 04/11 não foi movida)');
select is((pg_temp.j('r2') -> 'review_items' -> 0 ->> 'transaction_id')::uuid, pg_temp.id('p2'),
  'C-2: compra fora da nova janela aparece no relatório de consistência');
select is(jsonb_array_length(pg_temp.j('r2') -> 'review_items'), 1,
  'C-2: compras dentro da janela não são relatadas');
select is((select count(*)::int from public.cycle_assignment_reviews where transaction_id = pg_temp.id('p2')), 1,
  'C-2: item registrado para revisão');
select is((select starts_on from public.billing_cycles where id = pg_temp.cy('c2', '2026-12-03')), '2026-11-04'::date,
  'C-2: ciclo seguinte começa no dia seguinte (sem lacuna)');
select is(pg_temp.eq('c2'), 0::bigint, 'C-2: EQ-1 = 0 após o recálculo');

-- ---------------------------------------------------------------------------
-- C-3 (§20.12): agendamento idempotente, com opção desligado
-- ---------------------------------------------------------------------------
select pg_temp.su();
-- O ambiente restaurado de verificação não tem pg_cron por desenho (§20.12): pula com motivo.
create function pg_temp.c3() returns setof text language plpgsql as $f$
begin
  if not exists (select 1 from pg_namespace where nspname = 'cron') then
    return next skip('pg_cron ausente: ambiente restaurado isolado não agenda jobs (§20.12)', 3);
    return;
  end if;
  perform private.ensure_job_schedules(false);
  perform private.ensure_job_schedules(false);
  return next is((select count(*)::int from cron.job where jobname like 'fluvi-%'), 2,
    'C-3: rodar duas vezes mantém uma entrada por job (nenhum job fluvi duplicado ou órfão)');
  return next is((select bool_or(active) from cron.job where jobname like 'fluvi-%'), false,
    'C-3: agendamentos criados desligados para execução controlada');
  perform private.ensure_job_schedules(true);
  return next is((select bool_and(active) from cron.job where jobname like 'fluvi-%'), true,
    'C-3: habilitação após a execução controlada');
end $f$;
select * from pg_temp.c3();

select * from finish();
rollback;
