-- FluviFiance v2.2 — desbloqueio financeiro no banco (§3.2, §6.11): PRIV-04..10 no nível da API.
-- Sessões e JWT simulados como o Supabase Auth emite (session_id + amr com o horário da senha).
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;
select plan(39);

-- A e B na família F1; A também em F2; Admin (d)
delete from public.administrators;
insert into auth.users (id, instance_id, aud, role, email) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'a@fluvi.test'),
  ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'b@fluvi.test'),
  ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'adm@fluvi.test');
select private.bootstrap_first_admin('adm@fluvi.test');
update public.profiles set provisioned_at = now()
 where user_id in ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000b1');
update auth.users set email_confirmed_at = now(), encrypted_password = 'x' where email like '%@fluvi.test';
insert into public.households (id, name) values
  ('00000000-0000-0000-0000-0000000000f1', 'Família 1'), ('00000000-0000-0000-0000-0000000000f2', 'Família 2');
insert into public.household_members (household_id, user_id) values
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000a1'),
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000b1'),
  ('00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-0000000000a1');

-- sessões de login: A1 e A2 (duas sessões de A), B1 (de B), D1 (Admin)
insert into auth.sessions (id, user_id, aal) values
  ('00000000-0000-0000-0000-00000000005a', '00000000-0000-0000-0000-0000000000a1', 'aal1'),
  ('00000000-0000-0000-0000-00000000006a', '00000000-0000-0000-0000-0000000000a1', 'aal1'),
  ('00000000-0000-0000-0000-00000000005b', '00000000-0000-0000-0000-0000000000b1', 'aal1'),
  ('00000000-0000-0000-0000-00000000005d', '00000000-0000-0000-0000-0000000000d1', 'aal2');

create temp table k (name text primary key, id uuid);
grant all on k to public;
create function pg_temp.put(p text, v uuid) returns uuid language sql as $$
  insert into k (name, id) values (p, v) on conflict (name) do update set id = excluded.id returning id $$;
create function pg_temp.id(p text) returns uuid language sql as $$ select id from k where name = p $$;
create function pg_temp.cat() returns uuid language sql as $$
  select id from public.categories where family_id is null and name = 'Mercado' and kind = 'expense' $$;
-- JWT como o Auth emite: amr com o horário da senha (segundos atrás)
create function pg_temp.as_user(p_uid uuid, p_session uuid, p_password_age int default 30, p_aal text default 'aal1')
returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', p_uid, 'role', 'authenticated', 'aal', p_aal, 'session_id', p_session,
    'amr', jsonb_build_array(jsonb_build_object('method', 'password',
      'timestamp', floor(extract(epoch from now())) - p_password_age)))::text, true);
  execute 'set local role authenticated';
end $$;
create function pg_temp.a() returns void language sql as $$
  select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000005a') $$;
create function pg_temp.visible() returns int language sql as $$
  select (select count(*) from public.transactions)::int + (select count(*) from public.financial_accounts)::int $$;
create function pg_temp.age_unlock(p_session uuid, p_minutes int) returns void language plpgsql as $$
begin
  execute 'reset role';
  update private.financial_unlocks set last_activity_at = now() - make_interval(mins => p_minutes)
   where session_id = p_session;
end $$;

-- ---------------------------------------------------------------------------
-- Escrita rápida sem desbloqueio (PRIV-02) e leitura negada (PRIV-09)
-- ---------------------------------------------------------------------------
select pg_temp.a();
select pg_temp.put('acc', (public.create_account(gen_random_uuid(), '00000000-0000-0000-0000-0000000000f1',
  'Banco', 'checking', '2026-01-01', 200000) ->> 'id')::uuid);
select is(
  (select array_agg(k order by k) from jsonb_object_keys(public.create_transaction(gen_random_uuid(),
     '00000000-0000-0000-0000-0000000000f1', 'expense', pg_temp.id('acc'), 15000, 'Farmácia', pg_temp.cat(), '2026-10-02')) k),
  array['id', 'status'], 'PRIV-02: lançamento sem desbloqueio grava e devolve só {id, status}');
select is((select array_agg(k order by k) from jsonb_object_keys(
            public.quick_entry_options('00000000-0000-0000-0000-0000000000f1') -> 'accounts' -> 0) k),
  array['id', 'name'], 'opções do lançamento rápido: só apelido e id, sem saldo');
select is(jsonb_array_length(public.quick_entry_options('00000000-0000-0000-0000-0000000000f1') -> 'categories') > 0, true,
  'opções do lançamento rápido trazem as categorias');
select is(pg_temp.visible(), 0, 'PRIV-09: logado, mas sem desbloqueio, a leitura direta não traz nada');
select is((select count(*)::int from public.v_account_balances), 0, 'PRIV-09: views também não revelam saldos');
select is(public.account_balance(pg_temp.id('acc')), null::bigint, 'PRIV-09: account_balance não revela');
select is((select direct_expenses_cents from public.competence_summary('00000000-0000-0000-0000-0000000000f1', '2026-10-01')),
  0::bigint, 'PRIV-09: resumo por competência não revela valores (R$ 150 lançados aparecem como 0)');
select throws_ok($$ select public.void_transaction(gen_random_uuid(), (select id from k where name = 'none'), 'x') $$,
  'P0002', null, 'alterar/anular registros exige desbloqueio');
select is(public.finance_status() ->> 'unlocked', 'false', 'status: bloqueado');

-- ---------------------------------------------------------------------------
-- Desbloqueio exige senha recente (PRIV-03) e vale para a sessão
-- ---------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000005a', 600);
select throws_ok($$ select public.unlock_finance('00000000-0000-0000-0000-0000000000f1') $$,
  '42501', 'confirme a senha para desbloquear', 'PRIV-03: senha comprovada há 10 min não desbloqueia (token renovado não basta)');
select pg_temp.a();
select lives_ok($$ select public.unlock_finance('00000000-0000-0000-0000-0000000000f1') $$,
  'senha recém-confirmada desbloqueia a família');
select is(pg_temp.visible(), 2, 'PRIV-04: desbloqueado, lê contas e lançamentos');
select is(public.account_balance(pg_temp.id('acc')), 185000::bigint, 'PRIV-04: saldo visível após o desbloqueio');
select is(public.finance_status() ->> 'family_id', '00000000-0000-0000-0000-0000000000f1', 'status: família desbloqueada');

select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000006a');
select is(pg_temp.visible(), 0, 'o desbloqueio é da sessão: outra sessão do mesmo usuário continua bloqueada');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-00000000005b');
select is(pg_temp.visible(), 0, 'B (mesma família) não herda o desbloqueio de A');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1', gen_random_uuid());
select throws_ok($$ select public.unlock_finance('00000000-0000-0000-0000-0000000000f1') $$,
  'P0002', null, 'sessão inexistente (forjada) não desbloqueia');

-- ---------------------------------------------------------------------------
-- Inatividade (PRIV-05) e renovação só por atividade (PRIV-06)
-- ---------------------------------------------------------------------------
select pg_temp.age_unlock('00000000-0000-0000-0000-00000000005a', 10);
select pg_temp.a();
select is(pg_temp.visible(), 2, 'aos 10 min sem atividade ainda está liberado');
select is((public.finance_status() ->> 'expires_in_seconds')::int, 300, 'status informa o tempo restante (5 min) sem renovar');
select pg_temp.age_unlock('00000000-0000-0000-0000-00000000005a', 10);
select pg_temp.a();
select pg_temp.visible();
reset role;
select ok((select now() - last_activity_at >= interval '10 minutes' from private.financial_unlocks
            where session_id = '00000000-0000-0000-0000-00000000005a'), 'PRIV-06: leituras não renovam a janela');
select pg_temp.a();
select is(public.touch_finance(), true, 'atividade humana renova dentro da janela');
reset role;
select ok((select now() - last_activity_at < interval '1 minute' from private.financial_unlocks
            where session_id = '00000000-0000-0000-0000-00000000005a'), 'a renovação zera a contagem de inatividade');

select pg_temp.age_unlock('00000000-0000-0000-0000-00000000005a', 16);
select pg_temp.a();
select is(pg_temp.visible(), 0, 'PRIV-05: após 15 min sem atividade, as leituras são bloqueadas');
select is(public.touch_finance(), false, 'PRIV-06: atividade depois de expirar não reabre');
select lives_ok($$ select public.create_transaction(gen_random_uuid(), '00000000-0000-0000-0000-0000000000f1',
  'expense', pg_temp.id('acc'), 100, 'Café', pg_temp.cat(), '2026-10-03') $$,
  'PRIV-05: login continua e o lançamento rápido segue disponível');

-- ---------------------------------------------------------------------------
-- Bloqueio manual e troca de família (PRIV-08)
-- ---------------------------------------------------------------------------
select public.unlock_finance('00000000-0000-0000-0000-0000000000f1');
select is(pg_temp.visible(), 3, 'novo desbloqueio libera de novo');
select public.lock_finance();
select is(pg_temp.visible(), 0, 'bloqueio manual fecha a leitura');

select public.unlock_finance('00000000-0000-0000-0000-0000000000f1');
select public.unlock_finance('00000000-0000-0000-0000-0000000000f2');
select is((select count(*)::int from public.financial_accounts where family_id = '00000000-0000-0000-0000-0000000000f1'), 0,
  'PRIV-08: ao desbloquear a Família 2, a Família 1 deixa de ser legível');
select is(private.finance_unlocked('00000000-0000-0000-0000-0000000000f2'), true, 'PRIV-08: só a família escolhida fica liberada');
select is(private.finance_unlocked('00000000-0000-0000-0000-0000000000f1'), false,
  'PRIV-08: voltar à família anterior exige novo desbloqueio');

-- ---------------------------------------------------------------------------
-- Invalidações (PRIV-07)
-- ---------------------------------------------------------------------------
select public.unlock_finance('00000000-0000-0000-0000-0000000000f1');
reset role;
update auth.users set encrypted_password = 'outra' where id = '00000000-0000-0000-0000-0000000000a1';
select pg_temp.a();
select is(pg_temp.visible(), 0, 'PRIV-07: troca de senha invalida o desbloqueio');

select public.unlock_finance('00000000-0000-0000-0000-0000000000f1');
reset role;
update public.household_members set status = 'suspended'
 where household_id = '00000000-0000-0000-0000-0000000000f1' and user_id = '00000000-0000-0000-0000-0000000000a1';
select is((select count(*)::int from private.financial_unlocks where user_id = '00000000-0000-0000-0000-0000000000a1'), 0,
  'PRIV-07: suspender o vínculo invalida o desbloqueio daquela família');
update public.household_members set status = 'active'
 where household_id = '00000000-0000-0000-0000-0000000000f1' and user_id = '00000000-0000-0000-0000-0000000000a1';

select pg_temp.a();
select public.unlock_finance('00000000-0000-0000-0000-0000000000f1');
reset role;
update public.profiles set status = 'blocked' where user_id = '00000000-0000-0000-0000-0000000000a1';
select is((select count(*)::int from private.financial_unlocks where user_id = '00000000-0000-0000-0000-0000000000a1'), 0,
  'PRIV-07: bloquear o usuário invalida o desbloqueio');
update public.profiles set status = 'active' where user_id = '00000000-0000-0000-0000-0000000000a1';

select pg_temp.a();
select public.unlock_finance('00000000-0000-0000-0000-0000000000f1');
reset role;
delete from auth.sessions where id = '00000000-0000-0000-0000-00000000005a';
select pg_temp.a();
select is(pg_temp.visible(), 0, 'PRIV-07: após o logout (sessão encerrada), o token antigo não lê nada');

reset role;
insert into auth.sessions (id, user_id, aal) values ('00000000-0000-0000-0000-00000000007a', '00000000-0000-0000-0000-0000000000a1', 'aal1');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000007a');
select public.unlock_finance('00000000-0000-0000-0000-0000000000f1');
reset role;
update auth.sessions set not_after = now() - interval '1 second' where id = '00000000-0000-0000-0000-00000000007a';
select pg_temp.as_user('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-00000000007a');
select is(pg_temp.visible(), 0, 'sessão vencida não lê, mesmo com desbloqueio registrado');

-- ---------------------------------------------------------------------------
-- Admin e família alheia (PRIV-10)
-- ---------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-00000000005d', 30, 'aal2');
select throws_ok($$ select public.unlock_finance('00000000-0000-0000-0000-0000000000f1') $$,
  'P0002', null, 'PRIV-10: Admin não desbloqueia família');
select throws_ok($$ select public.quick_entry_options('00000000-0000-0000-0000-0000000000f1') $$,
  'P0002', null, 'PRIV-10: Admin não lê nem os apelidos das contas');
select pg_temp.as_user('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-00000000005b');
select throws_ok($$ select public.unlock_finance('00000000-0000-0000-0000-0000000000f2') $$,
  'P0002', null, 'não desbloqueia família da qual não é membro');

-- quem não tem desbloqueio não chama as funções internas de estado
select throws_ok($$ select * from private.financial_unlocks $$, '42501', null, 'tabela de desbloqueios inacessível ao usuário');

select * from finish();
rollback;
