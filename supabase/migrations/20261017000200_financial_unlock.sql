-- Remodelagem v2.2 — R3: desbloqueio financeiro exigido pelo BANCO (§3.2 itens 4–10, §6.11).
--
-- * Ler dados financeiros (e alterar/cancelar registros existentes) exige, além de ser membro
--   ativo da família, um desbloqueio vigente da SESSÃO de login para AQUELA família.
-- * O desbloqueio nasce de uma prova recente de senha: a claim `amr` do JWT (método password)
--   com menos de 2 minutos. Renovar o token mantém o horário original da senha (verificado no
--   Auth local), então só um login com a senha recém-digitada desbloqueia. Nenhuma senha passa
--   pelo banco nem fica no cliente.
-- * Expira após 15 minutos sem atividade (touch_finance, chamado pelo cliente em interação
--   humana; leituras não renovam). Logout, sessão expirada, troca de senha, bloqueio do perfil,
--   suspensão/remoção do vínculo e família inativa invalidam. Um desbloqueio por sessão: liberar
--   outra família substitui o anterior (PRIV-08).
-- * Escrita de criação (lançamento rápido) continua sem desbloqueio e só devolve {id, status};
--   as opções do formulário vêm de quick_entry_options (só apelidos).

-- ---------------------------------------------------------------------------
-- 1. Estado do desbloqueio (schema privado: não exposto pelo PostgREST)
-- ---------------------------------------------------------------------------
create table private.financial_unlocks (
  session_id       uuid primary key,
  user_id          uuid not null references auth.users (id) on delete cascade,
  family_id        uuid not null references public.households (id) on delete cascade,
  unlocked_at      timestamptz not null default now(),
  last_activity_at timestamptz not null default now()
);
create index financial_unlocks_user_idx on private.financial_unlocks (user_id);
create index financial_unlocks_family_idx on private.financial_unlocks (family_id);
revoke all on private.financial_unlocks from public, anon, authenticated;

create function private.unlock_idle_limit()
returns interval
language sql
immutable
set search_path = ''
as $$ select interval '15 minutes' $$;

create function private.jwt_session()
returns uuid
language sql
stable
set search_path = ''
as $$ select nullif(auth.jwt() ->> 'session_id', '')::uuid $$;

-- Desbloqueio vigente desta sessão para a família (a sessão precisa existir e estar válida).
create function private.finance_unlocked(p_family uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from private.financial_unlocks u
      join auth.sessions s on s.id = u.session_id and s.user_id = u.user_id
     where u.session_id = private.jwt_session()
       and u.user_id = auth.uid()
       and u.family_id = p_family
       and u.last_activity_at > now() - private.unlock_idle_limit()
       and (s.not_after is null or s.not_after > now())
  );
$$;

-- ---------------------------------------------------------------------------
-- 2. Regra de acesso: leitura, alteração e cancelamento exigem o desbloqueio
-- ---------------------------------------------------------------------------
create or replace function private.can_access_family(
  p_family    uuid,
  p_scope     public.grant_scope,
  p_operation public.grant_operation
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select auth.uid() is not null
     and p_family is not null
     and private.is_financial_user(auth.uid())
     and exists (
       select 1
         from public.household_members m
         join public.households h on h.id = m.household_id and h.active
        where m.household_id = p_family
          and m.user_id = auth.uid()
          and m.status = 'active'
     )
     and (p_operation = 'create' or private.finance_unlocked(p_family));
$$;

-- ---------------------------------------------------------------------------
-- 3. Compra no cartão pelo lançamento rápido: criar não exige ler o cartão
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_card_purchase(p_op uuid, p_card uuid, p_amount_cents bigint, p_installments integer, p_description text, p_category uuid, p_local_date date, p_competence_month date DEFAULT NULL::date, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_card    public.credit_cards;
  v_payload jsonb := jsonb_build_object('card', p_card, 'amt', p_amount_cents, 'n', p_installments,
    'desc', p_description, 'cat', p_category, 'date', p_local_date, 'comp', p_competence_month, 'note', p_note);
  v_res      jsonb;
  v_txn      uuid;
  v_purchase uuid;
  v_cycle    uuid;
  v_part     record;
begin
  select * into v_card from public.credit_cards where id = p_card for update;
  perform private.require_access(v_card.family_id, 'transactions', 'create');
  perform private.require_access(v_card.family_id, 'cards', 'create');
  v_res := private.fin_replay(v_card.family_id, p_op, 'create_card_purchase', v_payload);
  if v_res is not null then return v_res; end if;
  if not v_card.active then
    raise exception 'cartão inativo' using errcode = 'check_violation';
  end if;
  if p_installments is null or p_installments not between 1 and 36 then
    raise exception 'parcelas devem ser de 1 a 36' using errcode = 'check_violation';
  end if;
  perform private.check_category(v_card.family_id, p_category, 'expense');

  v_txn := private.new_txn(v_card.family_id, 'card_purchase', p_description, p_amount_cents, p_category,
    v_card.account_id, p_local_date, p_competence_month, p_note, null, p_op);
  insert into public.card_purchases (transaction_id, family_id, card_id, total_cents, installment_count)
  values (v_txn, v_card.family_id, p_card, p_amount_cents, p_installments)
  returning id into v_purchase;

  v_cycle := private.purchase_cycle(p_card, p_local_date);
  for v_part in select * from private.split_cents(p_amount_cents, p_installments) loop
    if v_part.seq > 1 then v_cycle := private.next_cycle(v_cycle); end if;
    insert into public.installments (purchase_id, family_id, revision, sequence, amount_cents, billing_cycle_id)
    values (v_purchase, v_card.family_id, 1, v_part.seq, v_part.amount, v_cycle);
  end loop;

  perform private.post(v_txn, v_card.family_id, v_card.account_id, -p_amount_cents, p_local_date);
  perform private.assert_card_reconciled(p_card);
  return private.fin_record(v_card.family_id, p_op, 'create_card_purchase', v_payload, private.result(v_txn));
end;
$function$
;

-- ---------------------------------------------------------------------------
-- 4. Opções do lançamento rápido (sem desbloqueio): só apelidos, nunca valores
-- ---------------------------------------------------------------------------
create function public.quick_entry_options(p_family uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_access(p_family, 'transactions', 'create');
  return jsonb_build_object(
    'accounts', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name) order by a.name)
                            from public.financial_accounts a
                           where a.family_id = p_family and a.active and a.type <> 'credit_card'), '[]'),
    'cards', coalesce((select jsonb_agg(jsonb_build_object('id', k.id, 'name', k.name) order by k.name)
                         from public.credit_cards k
                        where k.family_id = p_family and k.active), '[]'),
    'categories', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'kind', c.kind) order by c.name)
                              from public.categories c
                             where c.active and (c.family_id is null or c.family_id = p_family)), '[]'));
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Ciclo de vida do desbloqueio
-- ---------------------------------------------------------------------------
-- Desbloqueia a família ativa nesta sessão. Exige senha comprovada há menos de 2 minutos.
create function public.unlock_finance(p_family uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_session uuid := private.jwt_session();
begin
  if v_session is null
     or not private.can_access_family(p_family, 'transactions', 'create')
     or not exists (select 1 from auth.sessions s
                     where s.id = v_session and s.user_id = auth.uid()
                       and (s.not_after is null or s.not_after > now())) then
    raise exception 'não encontrado ou sem permissão' using errcode = 'no_data_found', hint = 'not_found_or_forbidden';
  end if;
  if not exists (
    select 1 from jsonb_array_elements(coalesce(auth.jwt() -> 'amr', '[]'::jsonb)) a
     where a ->> 'method' = 'password'
       and to_timestamp((a ->> 'timestamp')::double precision) > now() - interval '2 minutes'
  ) then
    raise exception 'confirme a senha para desbloquear' using errcode = 'insufficient_privilege',
      hint = 'reauthentication_required';
  end if;

  -- limpeza: desbloqueios vencidos ou de sessões encerradas deste usuário
  delete from private.financial_unlocks u
   where u.user_id = auth.uid()
     and (u.last_activity_at <= now() - private.unlock_idle_limit()
          or not exists (select 1 from auth.sessions s where s.id = u.session_id));

  insert into private.financial_unlocks (session_id, user_id, family_id)
  values (v_session, auth.uid(), p_family)
  on conflict (session_id) do update
    set family_id = excluded.family_id, unlocked_at = now(), last_activity_at = now();
  return jsonb_build_object('family_id', p_family,
    'idle_seconds', extract(epoch from private.unlock_idle_limit())::int);
end;
$$;

-- Atividade humana em área protegida: renova a janela se ainda vigente (leituras não renovam).
create function public.touch_finance()
returns boolean
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  update private.financial_unlocks
     set last_activity_at = now()
   where session_id = private.jwt_session()
     and user_id = auth.uid()
     and last_activity_at > now() - private.unlock_idle_limit();
  return found;
end;
$$;

-- Bloqueio manual: a sessão de login continua.
create function public.lock_finance()
returns void
language sql
volatile
security definer
set search_path = ''
as $$
  delete from private.financial_unlocks
   where session_id = private.jwt_session() and user_id = auth.uid();
$$;

-- Estado (sem renovar): para o cliente decidir o que mostrar ao abrir ou voltar ao app.
create function public.finance_status()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select jsonb_build_object(
              'unlocked', true,
              'family_id', u.family_id,
              'expires_in_seconds', greatest(0, extract(epoch from
                 (u.last_activity_at + private.unlock_idle_limit() - now()))::int))
       from private.financial_unlocks u
      where u.session_id = private.jwt_session()
        and u.user_id = auth.uid()
        and private.finance_unlocked(u.family_id)),
    jsonb_build_object('unlocked', false));
$$;

-- ---------------------------------------------------------------------------
-- 6. Invalidação: senha, perfil, vínculo e família
-- ---------------------------------------------------------------------------
create function private.unlocks_on_password_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.encrypted_password is distinct from old.encrypted_password then
    delete from private.financial_unlocks where user_id = new.id;
  end if;
  return null;
end;
$$;
create trigger financial_unlocks_password_change
  after update of encrypted_password on auth.users
  for each row execute function private.unlocks_on_password_change();

create function private.unlocks_on_profile_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status <> 'active' then
    delete from private.financial_unlocks where user_id = new.user_id;
  end if;
  return null;
end;
$$;
create trigger financial_unlocks_profile_change
  after update of status on public.profiles
  for each row execute function private.unlocks_on_profile_change();

create function private.unlocks_on_membership_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' or new.status <> 'active' then
    delete from private.financial_unlocks where user_id = old.user_id and family_id = old.household_id;
  end if;
  return null;
end;
$$;
create trigger financial_unlocks_membership_change
  after update of status or delete on public.household_members
  for each row execute function private.unlocks_on_membership_change();

create function private.unlocks_on_family_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not new.active then
    delete from private.financial_unlocks where family_id = new.id;
  end if;
  return null;
end;
$$;
create trigger financial_unlocks_family_change
  after update of active on public.households
  for each row execute function private.unlocks_on_family_change();

-- ---------------------------------------------------------------------------
-- 7. Execução
-- ---------------------------------------------------------------------------
revoke execute on all functions in schema private from public, anon, authenticated;
revoke execute on procedure private.run_job(text) from public, anon, authenticated;

grant execute on function
  private.current_aal(), private.is_active_profile(uuid), private.is_admin_identity(uuid),
  private.is_admin(), private.is_financial_user(uuid),
  private.can_access_family(uuid, public.grant_scope, public.grant_operation),
  private.finance_unlocked(uuid), private.jwt_session(), private.unlock_idle_limit(),
  private.is_active_member(uuid), private.shares_household_with(uuid),
  private.today(), private.month_start(date),
  private.cycle_debits(uuid), private.cycle_credits(uuid), private.cycle_amount(uuid),
  private.obligation_paid(uuid), private.credit_unapplied(uuid), private.card_debt(uuid)
to authenticated, service_role;

do $$
declare f text;
begin
  foreach f in array array[
    'quick_entry_options(uuid)', 'unlock_finance(uuid)', 'touch_finance()', 'lock_finance()', 'finance_status()'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
