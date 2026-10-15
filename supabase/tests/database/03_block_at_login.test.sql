-- Fluvi — Marco A — D4: bloqueio na emissão de token e encerramento de sessões (pgTAP).
-- O fluxo real com o Supabase Auth está em tests/integration/block-at-login.test.ts.
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(13);

delete from public.administrators;
insert into auth.users (id, instance_id, aud, role, email) values
  ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'bl-admin@fluvi.test'),
  ('00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'bl-user@fluvi.test'),
  ('00000000-0000-0000-0000-0000000000b3', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'bl-pend@fluvi.test');
select private.bootstrap_first_admin('bl-admin@fluvi.test');
update public.profiles set provisioned_at = now() where user_id = '00000000-0000-0000-0000-0000000000b2';
update auth.users set email_confirmed_at = now(), encrypted_password = 'hash-ficticio'
 where id in ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000b2');

create function pg_temp.hook(p_user uuid) returns jsonb language sql as $$
  select public.custom_access_token_hook(jsonb_build_object(
    'user_id', p_user,
    'claims', jsonb_build_object('sub', p_user, 'role', 'authenticated', 'aal', 'aal1'),
    'authentication_method', 'password'));
$$;

select is(pg_temp.hook('00000000-0000-0000-0000-0000000000b2') -> 'claims' ->> 'sub',
  '00000000-0000-0000-0000-0000000000b2', 'usuário ativo: hook devolve as claims sem alteração');
select ok(pg_temp.hook('00000000-0000-0000-0000-0000000000b2') -> 'error' is null,
  'usuário ativo: sem erro');
select ok(pg_temp.hook('00000000-0000-0000-0000-0000000000b3') -> 'error' is null,
  'pendente recebe token (precisa concluir ativação), mas a RLS continua negando dados');

-- bloqueio pelo Admin encerra sessões
insert into auth.sessions (id, user_id, created_at, updated_at, aal)
values (gen_random_uuid(), '00000000-0000-0000-0000-0000000000b2', now(), now(), 'aal1'),
       (gen_random_uuid(), '00000000-0000-0000-0000-0000000000b2', now(), now(), 'aal1');

select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated","aal":"aal2"}', true);
set local role authenticated;
select lives_ok($$ select public.admin_set_user_status(gen_random_uuid(), '00000000-0000-0000-0000-0000000000b2', 'blocked') $$,
  'Admin bloqueia o usuário');
reset role;

select is((select count(*)::int from auth.sessions where user_id = '00000000-0000-0000-0000-0000000000b2'), 0,
  'bloqueio encerra todas as sessões do usuário (refresh deixa de valer)');
select is((pg_temp.hook('00000000-0000-0000-0000-0000000000b2') -> 'error' ->> 'http_code')::int, 403,
  'usuário bloqueado: hook recusa emitir token (HTTP 403)');
select ok(pg_temp.hook('00000000-0000-0000-0000-0000000000b2') -> 'claims' is null,
  'usuário bloqueado: nenhuma claim é devolvida');

-- a aplicação não executa o hook
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-0000000000b2","role":"authenticated","aal":"aal1"}', true);
set local role authenticated;
select throws_ok($$ select public.custom_access_token_hook('{}') $$, '42501', null,
  'usuário não executa o hook');
reset role;
set local role anon;
select throws_ok($$ select public.custom_access_token_hook('{}') $$, '42501', null,
  'anon não executa o hook');
reset role;

-- D5: listagem administrativa (e-mail só para Admin com MFA)
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated","aal":"aal2"}', true);
set local role authenticated;
select is((select count(*)::int from public.admin_list_users() where email like 'bl-%@fluvi.test'), 3,
  'Admin aal2 lista usuários com e-mail');
select is((select is_admin from public.admin_list_users() where email = 'bl-admin@fluvi.test'), true,
  'listagem identifica o Admin');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000b1","role":"authenticated","aal":"aal1"}', true);
select throws_ok('select * from public.admin_list_users()', '42501', null, 'Admin aal1 não lista usuários');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000b3","role":"authenticated","aal":"aal2"}', true);
select throws_ok('select * from public.admin_list_users()', '42501', null, 'usuário comum não lista usuários nem e-mails');
reset role;

select * from finish();
rollback;
