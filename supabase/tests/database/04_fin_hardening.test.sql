-- Fluvi — Marco B — Endurecimento e invariantes estruturais (varredura do catálogo).
-- INV-P1, INV-P2, INV-P3, INV-L1, INV-L7, INV-C8, INV-C4.
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(14);

-- INV-P1: toda tabela de public tem RLS e nenhuma escrita direta para anon/authenticated
select is(
  (select coalesce(array_agg((c.relname)::text order by c.relname), '{}')::text[]
     from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity),
  '{}'::text[], 'toda tabela de public tem RLS habilitada');

select is(
  (select coalesce(array_agg((c.relname || ':' || p.priv)::text order by c.relname, p.priv), '{}')::text[]
     from pg_class c join pg_namespace n on n.oid = c.relnamespace
     cross join (values ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE')) p(priv)
     cross join (values ('anon'), ('authenticated')) r(role)
    where n.nspname = 'public' and c.relkind = 'r'
      and has_table_privilege(r.role, c.oid, p.priv)),
  '{}'::text[], 'nenhuma tabela aceita escrita direta de anon/authenticated');

-- INV-P2: security definer sempre com search_path fixo; nada executável por anon
select is(
  (select coalesce(array_agg((n.nspname || '.' || p.proname)::text order by 1), '{}')::text[]
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('public', 'private') and p.prosecdef
      and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) cfg where cfg like 'search_path=%')),
  '{}'::text[], 'toda função security definer fixa search_path');

select is(
  (select coalesce(array_agg((n.nspname || '.' || p.proname)::text order by 1), '{}')::text[]
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('public', 'private')
      and has_function_privilege('anon', p.oid, 'EXECUTE')),
  '{}'::text[], 'nenhuma função de public/private é executável por anon');

select is(
  (select coalesce(array_agg((p.proname)::text order by 1), '{}')::text[]
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'private' and p.proname in ('close_cycle', 'generate_occurrences', 'job_close_due_cycles',
      'compensate', 'post', 'new_txn', 'apply_unapplied_credits', 'ensure_cycle', 'fin_record', 'bootstrap_first_admin',
      'admin_recovery_replace', 'admin_recovery_reset_mfa')
      and has_function_privilege('authenticated', p.oid, 'EXECUTE')),
  '{}'::text[], 'funções internas de escrita não são executáveis por authenticated');

select ok(not has_function_privilege('authenticated', 'private.run_job(text)', 'EXECUTE'),
  'procedure de jobs não é executável por authenticated');

-- INV-P3: toda view de public é security_invoker
select is(
  (select coalesce(array_agg((c.relname)::text order by 1), '{}')::text[]
     from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'v'
      and not coalesce('security_invoker=true' = any(c.reloptions), false)),
  '{}'::text[], 'toda view de public é security_invoker');

-- Fixture mínima para invariantes de linha
insert into auth.users (id, instance_id, aud, role, email) values
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'h@fluvi.test');
update public.profiles set provisioned_at = now() where user_id = '00000000-0000-0000-0000-0000000000f1';
update auth.users set email_confirmed_at = now(), encrypted_password = 'x' where id = '00000000-0000-0000-0000-0000000000f1';
insert into public.financial_accounts (id, owner_user_id, name, type, opening_date)
values ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000f1', 'Conta', 'checking', '2026-10-01');
insert into public.transactions (id, owner_user_id, type, description, amount_cents, category_id, account_id,
  local_date, competence_month, created_by)
values ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000f1', 'expense', 'x', 100,
  (select id from public.categories where owner_user_id is null and name = 'Mercado'),
  '00000000-0000-0000-0000-0000000000a1', '2026-10-02', '2026-10-01', '00000000-0000-0000-0000-0000000000f1');

-- INV-L7: o instante de conhecimento é do banco, nunca do cliente
insert into public.ledger_entries (transaction_id, owner_user_id, account_id, amount_cents, posted_on, recorded_at)
values ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000f1',
        '00000000-0000-0000-0000-0000000000a1', -100, '2026-10-02', '2000-01-01');
select ok((select recorded_at > now() - interval '1 minute' from public.ledger_entries
            where transaction_id = '00000000-0000-0000-0000-0000000000b1'),
  'recorded_at informado é ignorado: vale o relógio do banco');

-- INV-L1: razão somente-acréscimo, até para o dono do banco pelos caminhos normais
select throws_ok($$ update public.ledger_entries set amount_cents = -1 $$, '42501', null, 'razão não aceita UPDATE');
select throws_ok($$ delete from public.ledger_entries $$, '42501', null, 'razão não aceita DELETE');
select throws_ok($$ delete from public.transactions $$, '42501', null, 'operações não são apagadas');

-- INV-L2: lançamento em conta de outro titular é recusado pela FK composta
insert into auth.users (id, instance_id, aud, role, email) values
  ('00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'h2@fluvi.test');
insert into public.financial_accounts (id, owner_user_id, name, type, opening_date)
values ('00000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000f2', 'Conta 2', 'checking', '2026-10-01');
select throws_ok(
  $$ insert into public.ledger_entries (transaction_id, owner_user_id, account_id, amount_cents, posted_on)
     values ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000f1',
             '00000000-0000-0000-0000-0000000000a2', -1, '2026-10-02') $$,
  '23503', null, 'lançamento só em conta do mesmo titular da operação');

-- INV-C8: cartão nunca guarda número completo
select throws_ok(
  $$ insert into public.credit_cards (owner_user_id, account_id, name, last_four, closing_day, due_day)
     values ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000a1', 'X', '4111111111111111', 5, 15) $$,
  null, null, 'last_four aceita só 4 dígitos');

-- abertura imutável após o primeiro lançamento
select throws_ok(
  $$ update public.financial_accounts set opening_balance_cents = 1 where id = '00000000-0000-0000-0000-0000000000a1' $$,
  '23514', null, 'abertura imutável após o primeiro lançamento');

select * from finish();
rollback;
