-- Fluvi — Marco A — D3 (rate limiting) e recuperação do único Admin (§19.6) (pgTAP).
-- Concorrência real do rate limit é testada na integração (rate-limit.test.ts).
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(26);

create function pg_temp.login(p_uid uuid, p_aal text default 'aal1')
returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub', p_uid, 'role', 'authenticated', 'aal', p_aal)::text, true);
  execute 'set local role authenticated';
end $$;

create function pg_temp.logout() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
end $$;

-- Fixtures: Admin ativo (a), sucessor convidado (s), usuário financeiro (u)
delete from public.administrators;
insert into auth.users (id, instance_id, aud, role, email) values
  ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'rl-admin@fluvi.test'),
  ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'rl-sucessor@fluvi.test'),
  ('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'rl-user@fluvi.test');
select private.bootstrap_first_admin('rl-admin@fluvi.test');
update public.profiles set provisioned_at = now() where user_id = '00000000-0000-0000-0000-0000000000a3';
update auth.users set email_confirmed_at = now(), encrypted_password = 'hash-ficticio'
 where id in ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2',
              '00000000-0000-0000-0000-0000000000a3');

-- ---------------------------------------------------------------------------
-- 1. Rate limit: contagem, bloqueio, chaves independentes, expiração
-- ---------------------------------------------------------------------------
update private.rate_limit_policies set max_hits = 3 where bucket_kind = 'admin_rpc';

select pg_temp.login('00000000-0000-0000-0000-0000000000a1', 'aal2');
select lives_ok($$ select public.admin_create_household(gen_random_uuid(), 'RL 1') $$, 'chamada 1 de 3 permitida');
select lives_ok($$ select public.admin_create_household(gen_random_uuid(), 'RL 2') $$, 'chamada 2 de 3 permitida');
select lives_ok($$ select public.admin_create_household(gen_random_uuid(), 'RL 3') $$, 'chamada 3 de 3 permitida');
select throws_ok($$ select public.admin_create_household(gen_random_uuid(), 'RL 4') $$,
  'PT429', null, '4ª chamada na janela: PT429 (HTTP 429)');
select throws_ok($$ select public.admin_set_user_status(gen_random_uuid(), '00000000-0000-0000-0000-0000000000a3', 'blocked') $$,
  'PT429', null, 'limite vale para todas as RPCs administrativas do mesmo Admin');
select is((select count(*)::int from public.households where name like 'RL %'), 3,
  'chamada bloqueada não produz efeito');

select pg_temp.logout();
select is((select hits from private.rate_limit_counters
            where bucket_kind = 'admin_rpc' and bucket_key = '00000000-0000-0000-0000-0000000000a1'),
  3, 'contador fica no limite (tentativas negadas não inflam o registro)');

-- expiração: a janela anterior não conta mais
update private.rate_limit_counters set window_start = window_start - interval '1 day'
 where bucket_kind = 'admin_rpc';
select pg_temp.login('00000000-0000-0000-0000-0000000000a1', 'aal2');
select lives_ok($$ select public.admin_create_household(gen_random_uuid(), 'RL 5') $$,
  'nova janela: chamada volta a ser permitida');
select pg_temp.logout();
select is((select count(*)::int from private.rate_limit_counters
            where bucket_kind = 'admin_rpc' and bucket_key = '00000000-0000-0000-0000-0000000000a1'), 1,
  'janela expirada é removida do contador');

-- chaves independentes
update private.rate_limit_policies set max_hits = 1 where bucket_kind = 'invite_email';
select lives_ok($$ select private.rate_limit_consume('invite_email', 'x@fluvi.test') $$, 'e-mail X: 1º convite');
select throws_ok($$ select private.rate_limit_consume('invite_email', 'x@fluvi.test') $$,
  'PT429', null, 'e-mail X: 2º convite na janela é negado');
select lives_ok($$ select private.rate_limit_consume('invite_email', 'y@fluvi.test') $$,
  'e-mail Y tem contador próprio');

-- convite: limite por e-mail aplicado em service_provision_begin, só para operações novas
select lives_ok(
  $$ select public.service_provision_begin('22222222-0000-0000-0000-000000000001',
       '00000000-0000-0000-0000-0000000000a1', '{"email":"Z@fluvi.test","display_name":"Z","household_id":null}') $$,
  'convite novo para Z consome o limite');
select is(
  (public.service_provision_begin('22222222-0000-0000-0000-000000000001',
     '00000000-0000-0000-0000-0000000000a1', '{"email":"Z@fluvi.test","display_name":"Z","household_id":null}') ->> 'state'),
  'resume', 'repetição idempotente do mesmo operation_id não é barrada pelo limite');
select throws_ok(
  $$ select public.service_provision_begin(gen_random_uuid(),
       '00000000-0000-0000-0000-0000000000a1', '{"email":"z@fluvi.test","display_name":"Z","household_id":null}') $$,
  'PT429', null, 'outro convite para o mesmo e-mail (normalizado) é negado');

-- papéis de aplicação não tocam no rate limit
select pg_temp.login('00000000-0000-0000-0000-0000000000a3');
select throws_ok($$ select * from private.rate_limit_counters $$, '42501', null, 'usuário não lê contadores');
select throws_ok($$ select private.rate_limit_consume('admin_rpc', 'x') $$, '42501', null,
  'usuário não executa rate_limit_consume');

-- ---------------------------------------------------------------------------
-- 2. Recuperação do único Admin
-- ---------------------------------------------------------------------------
select throws_ok($$ select private.admin_recovery_reset_mfa('rl-admin@fluvi.test', 'teste de permissão') $$,
  '42501', null, 'usuário não executa recuperação de MFA');
select throws_ok($$ select private.admin_recovery_replace('rl-admin@fluvi.test', 'rl-sucessor@fluvi.test', 'teste de permissão') $$,
  '42501', null, 'usuário não executa substituição de Admin');
select pg_temp.logout();

-- reset de MFA
insert into auth.mfa_factors (id, user_id, friendly_name, factor_type, status, created_at, updated_at, secret)
values (gen_random_uuid(), '00000000-0000-0000-0000-0000000000a1', 'perdido', 'totp', 'verified', now(), now(), 'segredo-ficticio');
insert into auth.sessions (id, user_id, created_at, updated_at, aal)
values (gen_random_uuid(), '00000000-0000-0000-0000-0000000000a1', now(), now(), 'aal2');

select throws_ok($$ select private.admin_recovery_reset_mfa('rl-admin@fluvi.test', 'curto') $$,
  '22023', null, 'recuperação exige motivo registrado');
select throws_ok($$ select private.admin_recovery_reset_mfa('rl-user@fluvi.test', 'usuário comum não é alvo válido') $$,
  '42501', null, 'reset de MFA só vale para Admin ativo');
select is(private.admin_recovery_reset_mfa('rl-admin@fluvi.test', 'dispositivo TOTP perdido, chamado #1'), 1,
  'reset remove o fator MFA do Admin');
select is((select count(*)::int from auth.sessions where user_id = '00000000-0000-0000-0000-0000000000a1'), 0,
  'reset encerra as sessões do Admin');

-- substituição
select is(private.admin_recovery_replace('rl-admin@fluvi.test', 'rl-sucessor@fluvi.test', 'conta do Admin comprometida, chamado #2'),
  '00000000-0000-0000-0000-0000000000a2'::uuid, 'substituição atribui o papel ao sucessor');
select results_eq(
  $$ select a.user_id, a.active, p.status::text from public.administrators a
       join public.profiles p on p.user_id = a.user_id order by a.user_id $$,
  $$ values ('00000000-0000-0000-0000-0000000000a1'::uuid, false, 'blocked'),
            ('00000000-0000-0000-0000-0000000000a2'::uuid, true,  'active') $$,
  'Admin antigo desativado e bloqueado; sucessor ativo');
select is((select count(*)::int from public.audit_events
            where action in ('recovery_reset_mfa', 'recovery_replace_admin')), 2,
  'as duas recuperações ficaram na auditoria');

select * from finish();
rollback;
