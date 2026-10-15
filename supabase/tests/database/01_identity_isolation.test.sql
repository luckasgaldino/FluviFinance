-- Fluvi — Marco A — Isolamento de identidades e autorizações (pgTAP).
-- Especificação v1.1: §5, §19.2–19.6 e matriz §19.9.
-- Tudo roda numa transação revertida ao final; usuários e dados são fictícios.
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(98);

-- ---------------------------------------------------------------------------
-- Auxiliares de sessão: simulam o JWT emitido pelo Supabase Auth.
-- ---------------------------------------------------------------------------
create function pg_temp.login(p_uid uuid, p_aal text default 'aal1', p_extra jsonb default '{}')
returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims',
    (jsonb_build_object('sub', p_uid, 'role', 'authenticated', 'aal', p_aal) || p_extra)::text, true);
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

insert into public.households (id, name) values
  ('00000000-0000-0000-0000-0000000000f1', 'Família Luck/Bia'),
  ('00000000-0000-0000-0000-0000000000f2', 'Outro núcleo');
insert into public.household_members (household_id, user_id) values
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000001c'),
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000000b'),
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000000f'),
  ('00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-00000000000c');

-- Tabela-sonda, só nesta transação, com o padrão de política das tabelas
-- financeiras do Marco B (titular + can_access_owner).
create table public.test_private_records (
  id            bigint generated always as identity primary key,
  owner_user_id uuid not null references public.profiles (user_id),
  amount_cents  bigint not null
);
alter table public.test_private_records enable row level security;
grant select, insert, update on public.test_private_records to authenticated;
create policy r on public.test_private_records for select to authenticated
  using (private.can_access_owner(owner_user_id, 'transactions', 'read'));
create policy c on public.test_private_records for insert to authenticated
  with check (private.can_access_owner(owner_user_id, 'transactions', 'create'));
create policy u on public.test_private_records for update to authenticated
  using (private.can_access_owner(owner_user_id, 'transactions', 'update'))
  with check (private.can_access_owner(owner_user_id, 'transactions', 'update'));

insert into public.test_private_records (owner_user_id, amount_cents) values
  ('00000000-0000-0000-0000-00000000001c', 1000), ('00000000-0000-0000-0000-00000000001c', 2000),
  ('00000000-0000-0000-0000-00000000000b', 300), ('00000000-0000-0000-0000-00000000000b', 400),
  ('00000000-0000-0000-0000-00000000000b', 500),
  ('00000000-0000-0000-0000-00000000000c', 9999),
  ('00000000-0000-0000-0000-00000000000f', 42);

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
-- 2. Titulares sem grant
-- ---------------------------------------------------------------------------
select is((select count(*)::int from public.test_private_records), 2,
  'Luck sem grant vê apenas os próprios 2 registros');
select is((select coalesce(sum(amount_cents), 0)::bigint from public.test_private_records), 3000::bigint,
  'agregado de Luck não inclui valores de Bia');
select throws_ok(
  $$ insert into public.test_private_records (owner_user_id, amount_cents)
     values ('00000000-0000-0000-0000-00000000000b', 1) $$,
  '42501', null, 'Luck não cria registro em nome de Bia sem grant create');
update public.test_private_records set amount_cents = 1
 where owner_user_id = '00000000-0000-0000-0000-00000000000b';
select is(private.can_access_owner('00000000-0000-0000-0000-00000000000b', 'transactions', 'read'), false,
  'can_access_owner nega Luck→Bia sem grant');
select is((select count(*)::int from public.accessible_owners('all', 'read')), 1,
  'accessible_owners de Luck contém só ele mesmo');
select is(
  (select array_agg(display_name order by display_name) from public.profiles),
  array['Bia', 'Luck'],
  'Luck vê nomes de membros ATIVOS do próprio núcleo; nem pendentes, nem outros núcleos, nem Admin');

select pg_temp.login('00000000-0000-0000-0000-00000000000b');
select is((select sum(amount_cents)::bigint from public.test_private_records), 1200::bigint,
  'update de Luck sobre dados de Bia não alterou nada');

select pg_temp.login('00000000-0000-0000-0000-00000000000c');
select is((select count(*)::int from public.test_private_records), 1,
  'usuária de outro núcleo vê só o próprio registro');

-- ---------------------------------------------------------------------------
-- 3. Pendentes (B8 / §19.2)
-- ---------------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-00000000000f');
select is((select (public.whoami() ->> 'status')), 'pending', 'convidada sem aceite é pending');
select is((select count(*)::int from public.test_private_records), 0,
  'pending não lê nem os próprios registros');
select is((select count(*)::int from public.profiles), 1,
  'pending vê só o próprio perfil, não os membros do núcleo');
select is((select count(*)::int from public.households), 0, 'pending não vê o núcleo');
select is((select count(*)::int from public.accessible_owners('all', 'read')), 0,
  'pending não tem titulares acessíveis');

select pg_temp.login('00000000-0000-0000-0000-00000000000d');
select is((select (public.whoami() ->> 'is_financial_user')::boolean), false,
  'identidade não provisionada não é usuário financeiro');

-- ---------------------------------------------------------------------------
-- 4. Admin sem acesso financeiro; aal1 não administra
-- ---------------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-00000000000a', 'aal2');
select is((select count(*)::int from public.test_private_records), 0,
  'Admin com MFA não lê registros financeiros');
select is((select count(*)::int from public.accessible_owners('all', 'read')), 0,
  'Admin não é titular acessível de ninguém');
select throws_ok(
  $$ insert into public.test_private_records (owner_user_id, amount_cents)
     values ('00000000-0000-0000-0000-00000000000a', 1) $$,
  '42501', null, 'Admin não registra lançamentos nem em nome próprio');
select is((select count(*)::int from public.households
            where id in ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000f2')),
  2, 'Admin com MFA vê os núcleos');
select throws_ok(
  $$ select public.admin_set_user_status(gen_random_uuid(), '00000000-0000-0000-0000-00000000000f', 'active') $$,
  '23514', null, 'Admin não ativa manualmente um pending (ativação exige aceite)');

select pg_temp.login('00000000-0000-0000-0000-00000000000a', 'aal1');
select is((select count(*)::int from public.households), 0, 'Admin aal1 não vê núcleos');
select is((select (public.whoami() ->> 'can_administer')::boolean), false, 'whoami: Admin aal1 não administra');
select throws_ok(
  $$ select public.admin_set_data_grant(gen_random_uuid(),
       '00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000000b',
       '00000000-0000-0000-0000-00000000001c', 'transactions', true, false, false, false) $$,
  '42501', null, 'Admin aal1 não altera grants');
select throws_ok($$ select public.admin_create_household(gen_random_uuid(), 'X') $$,
  '42501', null, 'Admin aal1 não cria núcleos');
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
-- 6. Grant de leitura: escopo, direção e núcleo
-- ---------------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-00000000000a', 'aal2');
select throws_ok(
  $$ select public.admin_set_data_grant(gen_random_uuid(),
       '00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000000b',
       '00000000-0000-0000-0000-00000000001c', 'transactions', true, false, false, false, 3) $$,
  '40001', null, 'revisão otimista: esperar revisão 3 de grant inexistente falha');
select lives_ok(
  $$ select public.admin_set_data_grant('11111111-0000-0000-0000-000000000001',
       '00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000000b',
       '00000000-0000-0000-0000-00000000001c', 'transactions', true, false, false, false, 0) $$,
  'Admin com MFA concede read Bia→Luck em transactions (revisão esperada 0)');

select pg_temp.login('00000000-0000-0000-0000-00000000001c');
select is((select count(*)::int from public.test_private_records), 5,
  'Luck com grant read vê os próprios 2 + os 3 de Bia');
select is(private.can_access_owner('00000000-0000-0000-0000-00000000000b', 'goals', 'read'), false,
  'grant em transactions não abre goals');
select throws_ok(
  $$ insert into public.test_private_records (owner_user_id, amount_cents)
     values ('00000000-0000-0000-0000-00000000000b', 1) $$,
  '42501', null, 'grant read não permite create');
select is(
  (select array_agg(owner_user_id order by owner_user_id) from public.accessible_owners('transactions', 'read')),
  array['00000000-0000-0000-0000-00000000000b', '00000000-0000-0000-0000-00000000001c']::uuid[],
  'accessible_owners de Luck: ele e Bia, nunca Carol (outro núcleo)');
select is((select count(*)::int from public.data_grants), 1,
  'Luck vê o grant de que participa');
select throws_ok($$ update public.data_grants set can_create = true $$, '42501', null,
  'Luck não altera o grant que consegue ler');

select pg_temp.login('00000000-0000-0000-0000-00000000000b');
select is((select count(*)::int from public.test_private_records), 3,
  'grant é direcional: Bia continua sem ver Luck');
select is((select count(*)::int from public.data_grants), 1,
  'Bia (titular) vê o grant que concedeu');

select pg_temp.login('00000000-0000-0000-0000-00000000000c');
select is((select count(*)::int from public.test_private_records), 1,
  'grant no núcleo F1 não afeta usuária do núcleo F2');
select is((select count(*)::int from public.data_grants), 0,
  'usuária de outro núcleo não vê grants alheios');

-- ---------------------------------------------------------------------------
-- 7. Titular bloqueado (B1): beneficiário perde acesso na hora
-- ---------------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-00000000000a', 'aal2');
select public.admin_set_user_status('11111111-0000-0000-0000-0000000000b1',
  '00000000-0000-0000-0000-00000000000b', 'blocked');
select pg_temp.login('00000000-0000-0000-0000-00000000001c');
select is((select count(*)::int from public.test_private_records), 2,
  'titular bloqueado: Luck deixa de ler Bia com a mesma sessão');
select pg_temp.login('00000000-0000-0000-0000-00000000000a', 'aal2');
select public.admin_set_user_status('11111111-0000-0000-0000-0000000000b2',
  '00000000-0000-0000-0000-00000000000b', 'active');
select pg_temp.login('00000000-0000-0000-0000-00000000001c');
select is((select count(*)::int from public.test_private_records), 5,
  'reativação (já ativada antes) restaura o acesso do grant vigente');

-- ---------------------------------------------------------------------------
-- 8. Idempotência, revisão e auditoria
-- ---------------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-00000000000a', 'aal2');
select is(
  (public.admin_set_data_grant('11111111-0000-0000-0000-000000000001',
     '00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000000b',
     '00000000-0000-0000-0000-00000000001c', 'transactions', true, false, false, false, 0) ->> 'revision')::int,
  1, 'repetir o mesmo request_id devolve o mesmo resultado');
select is((select count(*)::int from public.data_grants where household_id = '00000000-0000-0000-0000-0000000000f1'),
  1, 'repetição não cria segundo grant');
select throws_ok(
  $$ select public.admin_set_data_grant('11111111-0000-0000-0000-000000000001',
       '00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000000b',
       '00000000-0000-0000-0000-00000000001c', 'transactions', true, true, false, false, 0) $$,
  '23505', null, 'mesmo request_id com conteúdo diferente é rejeitado');
select is((select can_create from public.data_grants where household_id = '00000000-0000-0000-0000-0000000000f1'),
  false, 'rejeição não deixou alteração parcial');
select is(
  (select count(*)::int from public.audit_events
    where entity_type = 'data_grants' and action = 'insert'
      and actor_id = '00000000-0000-0000-0000-00000000000a'
      and request_id = '11111111-0000-0000-0000-000000000001'),
  1, 'criação do grant auditada com ator e request_id');
select throws_ok($$ delete from public.audit_events $$, '42501', null, 'Admin não apaga auditoria');

-- revogação: revision sobe, nenhuma concessão vigente, histórico preservado
select throws_ok(
  $$ select public.admin_set_data_grant(gen_random_uuid(),
       '00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000000b',
       '00000000-0000-0000-0000-00000000001c', 'transactions', false, false, false, false, 0) $$,
  '40001', null, 'revisão otimista: revogar esperando revisão 0 quando vigente é 1 falha');
select is(
  (public.admin_set_data_grant('11111111-0000-0000-0000-000000000002',
     '00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000000b',
     '00000000-0000-0000-0000-00000000001c', 'transactions', false, false, false, false, 1) ->> 'revision')::int,
  2, 'revogação incrementa revision');
select is((select count(*)::int from public.data_grants
            where household_id = '00000000-0000-0000-0000-0000000000f1' and revoked_at is null),
  0, 'nenhuma concessão vigente após revogar');
select is(
  (select count(*)::int from public.audit_events a
     join public.data_grants g on a.entity_id = g.id::text
    where g.household_id = '00000000-0000-0000-0000-0000000000f1'),
  2, 'auditoria preserva criação e revogação');

select pg_temp.login('00000000-0000-0000-0000-00000000001c');
select is((select count(*)::int from public.test_private_records), 2,
  'após revogação Luck volta a ver só os próprios registros (mesma sessão)');

-- ---------------------------------------------------------------------------
-- 9. CREATE sem READ (B2)
-- ---------------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-00000000000a', 'aal2');
select public.admin_set_data_grant('11111111-0000-0000-0000-000000000003',
  '00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000000b',
  '00000000-0000-0000-0000-00000000001c', 'all', false, true, false, false);
select pg_temp.login('00000000-0000-0000-0000-00000000001c');
select lives_ok(
  $$ insert into public.test_private_records (owner_user_id, amount_cents)
     values ('00000000-0000-0000-0000-00000000000b', 77) $$,
  'grant create permite Luck registrar em nome de Bia');
select throws_ok(
  $$ insert into public.test_private_records (owner_user_id, amount_cents)
     values ('00000000-0000-0000-0000-00000000000b', 78) returning amount_cents $$,
  '42501', null, 'create sem read não devolve o registro criado (RETURNING negado)');
select is((select count(*)::int from public.test_private_records), 2,
  'create sem read não revela registros de Bia');

-- ---------------------------------------------------------------------------
-- 10. Vínculo suspenso (B3)
-- ---------------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-00000000000a', 'aal2');
select public.admin_set_data_grant('11111111-0000-0000-0000-000000000004',
  '00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000000b',
  '00000000-0000-0000-0000-00000000001c', 'transactions', true, false, false, false);
select public.admin_set_household_member('11111111-0000-0000-0000-000000000005',
  '00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000001c', 'suspended');
select pg_temp.login('00000000-0000-0000-0000-00000000001c');
select is((select count(*)::int from public.test_private_records), 2,
  'vínculo suspenso: sessão antiga deixa de ler Bia');
select is(private.can_access_owner('00000000-0000-0000-0000-00000000000b', 'transactions', 'create'), false,
  'vínculo suspenso: grant create deixa de valer');
select is((select count(*)::int from public.data_grants where revoked_at is null), 0,
  'suspensão revogou os grants vigentes');

-- ---------------------------------------------------------------------------
-- 11. Usuário bloqueado (B9)
-- ---------------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-00000000000a', 'aal2');
select public.admin_set_user_status('11111111-0000-0000-0000-000000000006',
  '00000000-0000-0000-0000-00000000001c', 'blocked');
select pg_temp.login('00000000-0000-0000-0000-00000000001c');
select is((select count(*)::int from public.test_private_records), 0,
  'bloqueado não lê nem os próprios registros, mesmo com JWT válido');
-- update barrado pela política não lança erro (0 linhas); confirmamos pelo efeito
update public.profiles set display_name = 'Hack' where user_id = auth.uid();
select pg_temp.logout();
select is((select display_name from public.profiles where user_id = '00000000-0000-0000-0000-00000000001c'),
  'Luck', 'bloqueado não altera o próprio perfil');

-- ---------------------------------------------------------------------------
-- 12. Invariantes
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
  '23514', null, 'Admin não entra em núcleo financeiro');
select throws_ok(
  $$ select public.admin_set_data_grant(gen_random_uuid(),
       '00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000000b',
       '00000000-0000-0000-0000-00000000000c', 'all', true, false, false, false) $$,
  '23514', null, 'grant exige dono e beneficiário no mesmo núcleo');
select throws_ok(
  $$ select public.admin_set_user_status(gen_random_uuid(), '00000000-0000-0000-0000-00000000000a', 'blocked') $$,
  '42501', null, 'Admin não altera o próprio status');

select pg_temp.logout();
select throws_ok(
  $$ insert into public.data_grants (household_id, owner_user_id, grantee_user_id, resource_scope, can_update)
     values ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000000b',
             '00000000-0000-0000-0000-00000000000f', 'cards', true) $$,
  '23514', null, 'grant de update sem read é inválido');
select throws_ok(
  $$ insert into public.data_grants (household_id, owner_user_id, grantee_user_id, resource_scope, can_cancel)
     values ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-00000000000b',
             '00000000-0000-0000-0000-00000000000f', 'cards', true) $$,
  '23514', null, 'grant de cancel sem read é inválido');
-- B11: o gatilho barra UPDATE/DELETE pelos caminhos normais; não é garantia
-- absoluta contra o dono do banco, que pode alterar o próprio gatilho.
select throws_ok($$ update public.audit_events set action = 'x' $$, '42501', null,
  'gatilho de auditoria barra UPDATE');

-- exclusão de identidades (ex.: pedido do titular) com grants concedidos/revogados
select lives_ok(
  $$ delete from public.test_private_records;  -- tabela-sonda do teste não tem cascata
     delete from auth.users where id in ('00000000-0000-0000-0000-00000000000a',
       '00000000-0000-0000-0000-00000000001c', '00000000-0000-0000-0000-00000000000b') $$,
  'excluir Admin e titulares com grants e auditoria não viola integridade');

select * from finish();
rollback;
