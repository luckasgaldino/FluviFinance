-- FluviFiance — Isolamento de identidades e famílias (pgTAP).
-- Especificação v1.1 (§5, §19.2–19.6, matriz §19.9) e v2.2 (§2: a família é a titular; FAM-01..03, PRIV-10).
-- Tudo roda numa transação revertida ao final; usuários e dados são fictícios.
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(90);

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

-- ---------------------------------------------------------------------------
-- Auxiliares de sessão: simulam o JWT emitido pelo Supabase Auth.
-- ---------------------------------------------------------------------------
create function pg_temp.login(p_uid uuid, p_aal text default 'aal1', p_extra jsonb default '{}')
returns void language plpgsql as $$
begin
  execute 'reset role';
  perform pg_temp.unlock(p_uid);
  perform set_config('request.jwt.claims',
    (jsonb_build_object('sub', p_uid, 'role', 'authenticated', 'aal', p_aal, 'session_id', pg_temp.sid(p_uid)) || p_extra)::text, true);
  execute 'set local role authenticated';
end $$;

create function pg_temp.login_anon() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  execute 'set local role anon';
end $$;

create function pg_temp.logout() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
end $$;

-- ---------------------------------------------------------------------------
-- Fixtures (como postgres)
-- ---------------------------------------------------------------------------
-- Isola o teste de dados locais remanescentes de outras suítes (revertido no fim).
delete from public.administrators;

-- a = Admin, 1c = Luck, b = Bia, c = Carol (outro núcleo), d = sem provisionamento,
-- e = metadata forjado, f = convidada que ainda não aceitou
insert into auth.users (id, instance_id, aud, role, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'admin@fluvi.test', '{"display_name":"Admin"}'),
  ('00000000-0000-0000-0000-00000000001c', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'luck@fluvi.test',  '{"display_name":"Luck"}'),
  ('00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'bia@fluvi.test',   '{"display_name":"Bia"}'),
  ('00000000-0000-0000-0000-00000000000c', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'carol@fluvi.test', '{"display_name":"Carol"}'),
  ('00000000-0000-0000-0000-00000000000d', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'semprov@fluvi.test', '{"display_name":"SemProv"}'),
  ('00000000-0000-0000-0000-00000000000e', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'meta@fluvi.test',  '{"display_name":"Meta","role":"admin","status":"active","is_admin":true}'),
  ('00000000-0000-0000-0000-00000000000f', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'convidada@fluvi.test', '{"display_name":"Convidada"}');

select is(
  (select count(*)::int from public.profiles
    where status = 'pending' and user_id::text like '00000000-0000-0000-0000-0000000000%'),
  7, 'todo usuário Auth nasce pending (status nunca vem de metadata)');

-- Bootstrap (B15 / §19.6)
select is(private.bootstrap_first_admin('admin@fluvi.test'), '00000000-0000-0000-0000-00000000000a'::uuid,
  'bootstrap atribui o papel ao único usuário com o e-mail');
select is(private.bootstrap_first_admin('  ADMIN@fluvi.test '), '00000000-0000-0000-0000-00000000000a'::uuid,
  'bootstrap repetido para o mesmo alvo (e-mail normalizado) é idempotente');
select is((select count(*)::int from public.administrators), 1,
  'repetição do bootstrap não duplica papel');
select throws_ok($$ select private.bootstrap_first_admin('luck@fluvi.test') $$,
  '42501', null, 'bootstrap para outro alvo é negado mesmo com o Admin ainda pendente');
select throws_ok($$ select private.bootstrap_first_admin('ninguem@fluvi.test') $$,
  'P0002', null, 'bootstrap exige usuário Auth existente');
select is((select status::text from public.profiles where user_id = '00000000-0000-0000-0000-00000000000a'),
  'pending', 'Admin recém-atribuído continua pending até comprovar e-mail e senha');

-- Provisionamento autorizado (equivalente ao provision-user) e aceite do convite
update public.profiles set provisioned_at = now()
 where user_id in ('00000000-0000-0000-0000-00000000001c', '00000000-0000-0000-0000-00000000000b',
                   '00000000-0000-0000-0000-00000000000c', '00000000-0000-0000-0000-00000000000e',
                   '00000000-0000-0000-0000-00000000000f');
select is((select count(*)::int from public.profiles
            where status = 'active' and user_id::text like '00000000-0000-0000-0000-0000000000%'),
  0, 'provisionar não ativa ninguém (B8)');

update auth.users set email_confirmed_at = now(), encrypted_password = 'hash-ficticio'
 where id in ('00000000-0000-0000-0000-00000000000a', '00000000-0000-0000-0000-00000000001c',
              '00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-00000000000c',
              '00000000-0000-0000-0000-00000000000d', '00000000-0000-0000-0000-00000000000e');
select is((select count(*)::int from public.profiles
            where status = 'active' and activation_completed_at is not null
              and user_id::text like '00000000-0000-0000-0000-0000000000%'),
  5, 'e-mail comprovado + senha ativa os 5 perfis provisionados');
select is((select status::text from public.profiles where user_id = '00000000-0000-0000-0000-00000000000d'),
  'pending', 'identidade sem provisionamento não ativa nem com e-mail e senha');

-- convidada comprova e-mail (ex.: link alternativo) mas não define senha
update auth.users set email_confirmed_at = now() where id = '00000000-0000-0000-0000-00000000000f';
select is((select status::text from public.profiles where user_id = '00000000-0000-0000-0000-00000000000f'),
  'pending', 'e-mail comprovado sem senha não ativa');

-- v2.2: a FAMÍLIA é a titular. A = Luck, Bia e a convidada (pendente); B = Carol; C = sem membros.
insert into public.households (id, name) values
  ('00000000-0000-0000-0000-0000000000f1', 'Família A'),
  ('00000000-0000-0000-0000-0000000000f2', 'Família B'),
  ('00000000-0000-0000-0000-0000000000f3', 'Família C');
insert into public.household_members (household_id, user_id) values
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000001c'),
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000000b'),
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000000f'),
  ('00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-00000000000c');

-- Tabela-sonda, só nesta transação, com o mesmo padrão de política das tabelas financeiras
-- (família + can_access_family). created_by é só autoria: não dá nem tira acesso.
create table public.test_private_records (
  id           bigint generated always as identity primary key,
  family_id    uuid not null references public.households (id),
  created_by   uuid not null,
  amount_cents bigint not null
);
alter table public.test_private_records enable row level security;
grant select, insert, update on public.test_private_records to authenticated;
create policy r on public.test_private_records for select to authenticated
  using (private.can_access_family(family_id, 'transactions', 'read'));
create policy c on public.test_private_records for insert to authenticated
  with check (private.can_access_family(family_id, 'transactions', 'create'));
create policy u on public.test_private_records for update to authenticated
  using (private.can_access_family(family_id, 'transactions', 'update'))
  with check (private.can_access_family(family_id, 'transactions', 'update'));

insert into public.test_private_records (family_id, created_by, amount_cents) values
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000001c', 1000),
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000001c', 2000),
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000000b', 300),
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000000b', 400),
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000000b', 500),
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000000f', 42),
  ('00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-00000000000c', 9999),
  ('00000000-0000-0000-0000-0000000000f3', '00000000-0000-0000-0000-00000000000c', 7);

-- ---------------------------------------------------------------------------
-- 1. Anônimo e chamadas fora de papel (§19.9)
-- ---------------------------------------------------------------------------
select pg_temp.login_anon();
select throws_ok($$ select * from public.profiles $$, '42501', null, 'anon não lê profiles');
select throws_ok($$ select * from public.data_grants $$, '42501', null, 'anon não lê data_grants');
select throws_ok($$ select public.whoami() $$, '42501', null, 'anon não executa whoami');
select throws_ok($$ select public.admin_create_household(gen_random_uuid(), 'X') $$,
  '42501', null, 'anon não executa admin_*');
select throws_ok($$ select public.service_provision_begin(gen_random_uuid(), gen_random_uuid(), '{}') $$,
  '42501', null, 'anon não executa service_*');

select pg_temp.login('00000000-0000-0000-0000-00000000001c');
select throws_ok($$ select public.service_provision_begin(gen_random_uuid(), '00000000-0000-0000-0000-00000000000a', '{}') $$,
  '42501', null, 'usuário comum não executa service_provision_begin');
select throws_ok($$ select public.service_provision_profile(gen_random_uuid(), '00000000-0000-0000-0000-00000000000a',
                     '00000000-0000-0000-0000-00000000001c', 'x', null, '{}') $$,
  '42501', null, 'usuário comum não executa service_provision_profile');
select throws_ok($$ select private.bootstrap_first_admin('luck@fluvi.test') $$,
  '42501', null, 'usuário comum não executa bootstrap');
select is((select array_agg(k order by k) from jsonb_object_keys(public.whoami()) k),
  array['aal', 'can_administer', 'is_admin_identity', 'is_financial_user', 'status', 'user_id'],
  'whoami tem resposta mínima e fixa');
select is((select (public.whoami() ->> 'user_id')::uuid), '00000000-0000-0000-0000-00000000001c'::uuid,
  'whoami devolve o próprio id');

-- ---------------------------------------------------------------------------
-- 2. Visão única da família (FAM-01) e isolamento entre famílias (FAM-02)
-- ---------------------------------------------------------------------------
select is((select count(*)::int from public.test_private_records), 6,
  'FAM-01: Luck vê os 6 registros da Família A, inclusive os criados por Bia e pela convidada');
select is((select sum(amount_cents)::bigint from public.test_private_records), 4242::bigint,
  'agregado de Luck é o da família inteira, sem nada da Família B ou C');
select lives_ok(
  $$ insert into public.test_private_records (family_id, created_by, amount_cents)
     values ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000001c', 1) $$,
  'membro registra na própria família');
select throws_ok(
  $$ insert into public.test_private_records (family_id, created_by, amount_cents)
     values ('00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-00000000001c', 1) $$,
  '42501', null, 'Luck não registra na Família B');
update public.test_private_records set amount_cents = 1
 where family_id = '00000000-0000-0000-0000-0000000000f2';
select is(private.can_access_family('00000000-0000-0000-0000-0000000000f2', 'transactions', 'read'), false,
  'can_access_family nega a Família B para Luck');
select is((select array_agg(family_id) from public.my_families()),
  array['00000000-0000-0000-0000-0000000000f1']::uuid[], 'my_families de Luck: só a Família A');
select is(
  (select array_agg(display_name order by display_name) from public.profiles),
  array['Bia', 'Luck'],
  'Luck vê nomes de membros ATIVOS da própria família; nem pendentes, nem outras famílias, nem Admin');

select pg_temp.login('00000000-0000-0000-0000-00000000000b');
select is((select count(*)::int from public.test_private_records), 7,
  'FAM-01: Bia vê exatamente os mesmos registros que Luck (visão única, sem dono individual)');
select is((select sum(amount_cents)::bigint from public.test_private_records), 4243::bigint,
  'Bia vê também o registro que Luck acabou de criar');

select pg_temp.login('00000000-0000-0000-0000-00000000000c');
select is((select count(*)::int from public.test_private_records), 1,
  'FAM-02: Carol (Família B) vê só a própria família');
select is((select sum(amount_cents)::bigint from public.test_private_records), 9999::bigint,
  'update de Luck sobre a Família B não alterou nada');

-- ---------------------------------------------------------------------------
-- 3. Pendentes (B8 / §19.2)
-- ---------------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-00000000000f');
select is((select (public.whoami() ->> 'status')), 'pending', 'convidada sem aceite é pending');
select is((select count(*)::int from public.test_private_records), 0,
  'pending não lê a família, nem o que ela própria registrou');
select is((select count(*)::int from public.profiles), 1,
  'pending vê só o próprio perfil, não os membros da família');
select is((select count(*)::int from public.households), 0, 'pending não vê a família');
select is((select count(*)::int from public.my_families()), 0, 'pending não tem família acessível');

select pg_temp.login('00000000-0000-0000-0000-00000000000d');
select is((select (public.whoami() ->> 'is_financial_user')::boolean), false,
  'identidade não provisionada não é usuário financeiro');

-- ---------------------------------------------------------------------------
-- 4. Admin sem acesso financeiro (PRIV-10); aal1 não administra
-- ---------------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-00000000000a', 'aal2');
select is((select count(*)::int from public.test_private_records), 0,
  'Admin com MFA não lê registros financeiros de nenhuma família');
select is((select count(*)::int from public.my_families()), 0, 'Admin não pertence a família financeira');
select throws_ok(
  $$ insert into public.test_private_records (family_id, created_by, amount_cents)
     values ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000000a', 1) $$,
  '42501', null, 'Admin não registra lançamentos em nenhuma família');
select is((select count(*)::int from public.households
            where id in ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000f2')),
  2, 'Admin com MFA vê as famílias (cadastro, sem finanças)');
select throws_ok(
  $$ select public.admin_set_user_status(gen_random_uuid(), '00000000-0000-0000-0000-00000000000f', 'active') $$,
  '23514', null, 'Admin não ativa manualmente um pending (ativação exige aceite)');

select pg_temp.login('00000000-0000-0000-0000-00000000000a', 'aal1');
select is((select count(*)::int from public.households), 0, 'Admin aal1 não vê famílias');
select is((select (public.whoami() ->> 'can_administer')::boolean), false, 'whoami: Admin aal1 não administra');
select throws_ok(
  $$ select public.admin_set_data_grant(gen_random_uuid(),
       '00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000000b',
       '00000000-0000-0000-0000-00000000001c', 'transactions', true, false, false, false) $$,
  '42501', null, 'Admin aal1 não altera permissões');
select throws_ok($$ select public.admin_create_household(gen_random_uuid(), 'X') $$,
  '42501', null, 'Admin aal1 não cria famílias');
select throws_ok(
  $$ select public.admin_set_user_status(gen_random_uuid(), '00000000-0000-0000-0000-00000000000b', 'blocked') $$,
  '42501', null, 'Admin aal1 não bloqueia usuários');
select throws_ok(
  $$ select public.admin_set_household_member(gen_random_uuid(), '00000000-0000-0000-0000-0000000000f1',
       '00000000-0000-0000-0000-00000000000b', 'suspended') $$,
  '42501', null, 'Admin aal1 não altera vínculos');

-- ---------------------------------------------------------------------------
-- 5. Usuário comum não altera autorizações nem auditoria
-- ---------------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-00000000001c', 'aal2');
select throws_ok(
  $$ insert into public.data_grants (household_id, owner_user_id, grantee_user_id, resource_scope, can_read)
     values ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000000b',
             '00000000-0000-0000-0000-00000000001c', 'all', true) $$,
  '42501', null, 'Luck não insere grant diretamente');
select throws_ok(
  $$ select public.admin_set_data_grant(gen_random_uuid(),
       '00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000000b',
       '00000000-0000-0000-0000-00000000001c', 'all', true, true, true, true) $$,
  '42501', null, 'Luck (mesmo com aal2) não executa RPC administrativa');
select throws_ok(
  $$ update public.profiles set status = 'blocked' where user_id = '00000000-0000-0000-0000-00000000000b' $$,
  '42501', null, 'Luck não altera status de perfis');
select throws_ok(
  $$ update public.profiles set provisioned_at = now() where user_id = auth.uid() $$,
  '42501', null, 'Luck não altera campos de provisionamento');
select throws_ok(
  $$ insert into public.administrators (user_id) values ('00000000-0000-0000-0000-00000000001c') $$,
  '42501', null, 'Luck não se promove a Admin');
select is((select count(*)::int from public.admin_operations), 0,
  'Luck não lê operações administrativas');
select throws_ok(
  $$ insert into public.audit_events (action, entity_type, entity_id) values ('forjado', 'x', 'y') $$,
  '42501', null, 'Luck não insere evento de auditoria arbitrário');
select throws_ok($$ delete from public.audit_events $$, '42501', null, 'Luck não apaga auditoria');

select pg_temp.login('00000000-0000-0000-0000-00000000000e', 'aal2',
  '{"user_metadata":{"role":"admin","is_admin":true},"app_metadata":{"role":"admin"}}');
select is((select (public.whoami() ->> 'can_administer')::boolean), false,
  'claims de metadata dizendo admin não concedem administração');
select throws_ok($$ select public.admin_create_household(gen_random_uuid(), 'X') $$,
  '42501', null, 'usuário com metadata forjado não executa RPC administrativa');

-- ---------------------------------------------------------------------------
-- 6. Permissões individuais descontinuadas (v2.2 §2)
-- ---------------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-00000000000a', 'aal2');
select throws_ok(
  $$ select public.admin_set_data_grant(gen_random_uuid(),
       '00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000000b',
       '00000000-0000-0000-0000-00000000001c', 'transactions', true, false, false, false, 0) $$,
  '42501', null, 'nem o Admin com MFA concede permissão individual: o acesso é da família');
select is((select count(*)::int from public.data_grants), 0, 'nenhuma permissão individual foi criada');

-- ---------------------------------------------------------------------------
-- 7. Membro bloqueado: o histórico é da família, não do autor
-- ---------------------------------------------------------------------------
select public.admin_set_user_status('11111111-0000-0000-0000-0000000000b1',
  '00000000-0000-0000-0000-00000000000b', 'blocked');
select pg_temp.login('00000000-0000-0000-0000-00000000001c');
select is((select count(*)::int from public.test_private_records), 7,
  'Bia bloqueada: Luck continua vendo todo o histórico, inclusive o que Bia registrou');
select pg_temp.login('00000000-0000-0000-0000-00000000000b');
select is((select count(*)::int from public.test_private_records), 0,
  'Bia bloqueada não lê nada da família, mesmo com JWT válido');
select pg_temp.login('00000000-0000-0000-0000-00000000000a', 'aal2');
select public.admin_set_user_status('11111111-0000-0000-0000-0000000000b2',
  '00000000-0000-0000-0000-00000000000b', 'active');
select pg_temp.login('00000000-0000-0000-0000-00000000000b');
select is((select count(*)::int from public.test_private_records), 7, 'reativada, Bia volta a ver a família');

-- ---------------------------------------------------------------------------
-- 8. Vínculos: suspensão, realocação (FAM-03, parte do banco) e mais de uma família
-- ---------------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-00000000000a', 'aal2');
select public.admin_set_household_member('11111111-0000-0000-0000-000000000005',
  '00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000001c', 'suspended');
select pg_temp.login('00000000-0000-0000-0000-00000000001c');
select is((select count(*)::int from public.test_private_records), 0,
  'vínculo suspenso: a sessão aberta perde a Família A na hora');
select throws_ok(
  $$ insert into public.test_private_records (family_id, created_by, amount_cents)
     values ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000001c', 1) $$,
  '42501', null, 'vínculo suspenso não registra na família');
select pg_temp.login('00000000-0000-0000-0000-00000000000b');
select is((select count(*)::int from public.test_private_records), 7,
  'suspender Luck não move nem esconde nada da família (nenhum lançamento é transferido)');

select pg_temp.login('00000000-0000-0000-0000-00000000000a', 'aal2');
select is((public.admin_set_household_member('11111111-0000-0000-0000-000000000006',
  '00000000-0000-0000-0000-0000000000f3', '00000000-0000-0000-0000-00000000001c', 'active') ->> 'status'),
  'invited', 'FAM-03: vincular alguém a uma família gera convite, não acesso');
select pg_temp.login('00000000-0000-0000-0000-00000000001c');
select is((select count(*)::int from public.test_private_records), 0,
  'FAM-03: antes do aceite, nada da Família C é liberado');
select is((select array_agg(name) from public.my_family_invites()), array['Família C'],
  'o convite aparece para a própria pessoa');
select lives_ok($$ select public.accept_family_invite('00000000-0000-0000-0000-0000000000f3') $$,
  'a própria pessoa aceita o convite');
select pg_temp.login('00000000-0000-0000-0000-00000000001c');  -- novo desbloqueio, já com a família ativa
select is((select count(*)::int from public.test_private_records), 1,
  'realocado para a Família C, Luck vê só a Família C, sem levar o histórico da A');
select is((select array_agg(family_id) from public.my_families()),
  array['00000000-0000-0000-0000-0000000000f3']::uuid[], 'my_families acompanha o vínculo vigente');

select pg_temp.login('00000000-0000-0000-0000-00000000000a', 'aal2');
select public.admin_set_household_member('11111111-0000-0000-0000-000000000007',
  '00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000001c', 'active');
select pg_temp.login('00000000-0000-0000-0000-00000000001c');
select is((select count(*)::int from public.test_private_records
            where family_id = '00000000-0000-0000-0000-0000000000f1'), 0,
  'FAM-03: voltar a uma família após suspensão também exige novo aceite');
select pg_temp.login('00000000-0000-0000-0000-00000000000b');
select throws_ok($$ select public.accept_family_invite('00000000-0000-0000-0000-0000000000f3') $$,
  'P0002', null, 'ninguém aceita convite alheio');
select pg_temp.login('00000000-0000-0000-0000-00000000001c');
select public.accept_family_invite('00000000-0000-0000-0000-0000000000f1');
select pg_temp.login('00000000-0000-0000-0000-00000000001c');
select is((select array_agg(family_id) from public.my_families()),
  array['00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000f3']::uuid[],
  'membro de duas famílias: as duas aparecem para seleção explícita da família ativa');
select is((select count(*)::int from public.test_private_records
            where family_id = '00000000-0000-0000-0000-0000000000f1'), 7,
  'aceito na Família A, Luck volta a ver o histórico dela (a separação por família ativa é do cliente e do desbloqueio)');

-- recusar: o convite some e nada é liberado
select pg_temp.login('00000000-0000-0000-0000-00000000000a', 'aal2');
select public.admin_set_household_member('11111111-0000-0000-0000-000000000009',
  '00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-00000000000b', 'active');
select pg_temp.login('00000000-0000-0000-0000-00000000000b');
select lives_ok($$ select public.decline_family_invite('00000000-0000-0000-0000-0000000000f2') $$, 'recusar um convite');
select is((select count(*)::int from public.my_family_invites()) + (select count(*)::int from public.test_private_records
            where family_id = '00000000-0000-0000-0000-0000000000f2'), 0, 'convite recusado não libera nada e sai da lista');


-- ---------------------------------------------------------------------------
-- 9. Usuário bloqueado (B9)
-- ---------------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-00000000000a', 'aal2');
select public.admin_set_user_status('11111111-0000-0000-0000-000000000008',
  '00000000-0000-0000-0000-00000000001c', 'blocked');
select pg_temp.login('00000000-0000-0000-0000-00000000001c');
select is((select count(*)::int from public.test_private_records), 0,
  'bloqueado não lê nenhuma família, mesmo com JWT válido');
-- update barrado pela política não lança erro (0 linhas); confirmamos pelo efeito
update public.profiles set display_name = 'Hack' where user_id = auth.uid();
select pg_temp.logout();
select is((select display_name from public.profiles where user_id = '00000000-0000-0000-0000-00000000001c'),
  'Luck', 'bloqueado não altera o próprio perfil');

-- ---------------------------------------------------------------------------
-- 10. Invariantes
-- ---------------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-00000000000b');
select lives_ok($$ update public.profiles set display_name = 'Bia S.' where user_id = auth.uid() $$,
  'usuária ativa altera o próprio display_name');
select throws_ok($$ update public.profiles set status = 'active' where user_id = auth.uid() $$,
  '42501', null, 'usuária não altera o próprio status');

select pg_temp.login('00000000-0000-0000-0000-00000000000a', 'aal2');
select throws_ok(
  $$ select public.admin_set_household_member(gen_random_uuid(),
       '00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000000a', 'active') $$,
  '23514', null, 'Admin não entra em família financeira');
select throws_ok(
  $$ select public.admin_set_user_status(gen_random_uuid(), '00000000-0000-0000-0000-00000000000a', 'blocked') $$,
  '42501', null, 'Admin não altera o próprio status');

select pg_temp.logout();
select throws_ok(
  $$ insert into public.data_grants (household_id, owner_user_id, grantee_user_id, resource_scope, can_update)
     values ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000000b',
             '00000000-0000-0000-0000-00000000000f', 'cards', true) $$,
  '23514', null, 'histórico de grants mantém a integridade: update sem read é inválido');
select throws_ok(
  $$ insert into public.data_grants (household_id, owner_user_id, grantee_user_id, resource_scope, can_cancel)
     values ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000000b',
             '00000000-0000-0000-0000-00000000000f', 'cards', true) $$,
  '23514', null, 'histórico de grants mantém a integridade: cancel sem read é inválido');
-- B11: o gatilho barra UPDATE/DELETE pelos caminhos normais; não é garantia
-- absoluta contra o dono do banco, que pode alterar o próprio gatilho.
select throws_ok($$ update public.audit_events set action = 'x' $$, '42501', null,
  'gatilho de auditoria barra UPDATE');

-- exclusão de identidades (ex.: pedido do titular): a família e seu histórico permanecem
select lives_ok(
  $$ delete from auth.users where id in ('00000000-0000-0000-0000-00000000000a',
       '00000000-0000-0000-0000-00000000001c', '00000000-0000-0000-0000-00000000000b') $$,
  'excluir Admin e membros não viola integridade');
select is((select count(*)::int from public.test_private_records
            where family_id = '00000000-0000-0000-0000-0000000000f1'), 7,
  'o histórico da família permanece após excluir identidades de membros');

select * from finish();
rollback;
