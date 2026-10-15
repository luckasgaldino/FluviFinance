-- Fluvi — Marco A — Ajustes da Especificação v1.1, §19.
--   B8/§19.2  convite não ativa: pending até e-mail comprovado + credencial definida
--   B13/§19.2 retomada de provisionamento só sobre identidade vinculada à mesma operação
--   B15/§19.6 bootstrap serializado, alvo único, idempotente, recusa Admin pendente
--   §19.3     admin_operations com estado; grant com revisão otimista; último Admin protegido

-- ---------------------------------------------------------------------------
-- 1. Ativação (B8)
-- ---------------------------------------------------------------------------

alter table public.profiles
  add column provisioned_at          timestamptz,
  add column provision_operation_id  uuid,
  add column activation_completed_at timestamptz,
  add constraint profiles_active_requires_activation
    check (status <> 'active' or activation_completed_at is not null);

comment on column public.profiles.provisioned_at is
  'Quando o Admin (ou o bootstrap) autorizou a identidade. Sem isso, nunca ativa.';
comment on column public.profiles.provision_operation_id is
  'operation_id do provision-user que criou a identidade Auth; gravado só na criação.';
comment on column public.profiles.activation_completed_at is
  'E-mail comprovado + senha definida, registrado por gatilho server-side.';

-- Guarda transversal: perfil ativo exige ativação concluída (além da constraint).
create or replace function private.is_active_profile(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.profiles p
    where p.user_id = p_user_id
      and p.status = 'active'
      and p.activation_completed_at is not null
  );
$$;

-- B4: só nomes de membros ATIVOS com perfil ATIVO (pendentes e bloqueados não aparecem).
create or replace function private.shares_household_with(p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.is_financial_user(auth.uid())
     and private.is_active_profile(p_user)
     and exists (
       select 1
       from public.household_members me
       join public.household_members other
         on other.household_id = me.household_id
        and other.user_id = p_user
        and other.status = 'active'
       join public.households h on h.id = me.household_id and h.active
       where me.user_id = auth.uid() and me.status = 'active'
     );
$$;

-- Promove pending → active somente quando: houve provisionamento autorizado,
-- o e-mail foi comprovado e existe senha. Nunca reativa bloqueado.
create function private.try_activate_profile(p_user_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform set_config('fluvi.actor_id', coalesce(nullif(current_setting('fluvi.actor_id', true), ''), p_user_id::text), true);
  update public.profiles p
     set status = 'active', activation_completed_at = now(), status_changed_at = now()
    from auth.users u
   where p.user_id = p_user_id
     and u.id = p.user_id
     and p.status = 'pending'
     and p.provisioned_at is not null
     and u.email_confirmed_at is not null
     and coalesce(u.encrypted_password, '') <> '';
  return found;
end;
$$;

create function private.handle_auth_user_activation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.try_activate_profile(new.id);
  return new;
end;
$$;

create trigger on_auth_user_credentials_changed
  after update of email_confirmed_at, encrypted_password on auth.users
  for each row execute function private.handle_auth_user_activation();

-- Vínculo identidade ↔ operação gravado apenas na criação do usuário Auth.
-- (user_metadata é editável depois, mas esta coluna não.)
create or replace function private.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_op text := new.raw_user_meta_data ->> 'fluvi_provision_operation_id';
begin
  insert into public.profiles (user_id, display_name, status, provision_operation_id)
  values (
    new.id,
    left(coalesce(
      nullif(btrim(new.raw_user_meta_data ->> 'display_name'), ''),
      nullif(split_part(coalesce(new.email, ''), '@', 1), ''),
      'Usuário'
    ), 80),
    'pending',
    case when v_op ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
         then v_op::uuid end
  );
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. admin_operations com estado (§19.3)
-- ---------------------------------------------------------------------------

alter table public.admin_operations
  add column status          text not null default 'succeeded'
                             check (status in ('pending', 'succeeded')),
  add column subject_user_id uuid,
  add column updated_at      timestamptz not null default now();

create trigger admin_operations_touch before update on public.admin_operations
  for each row execute function private.touch_updated_at();

comment on table public.admin_operations is
  'Idempotência de operações administrativas. Guarda hash dos parâmetros e resultado '
  'sanitizado (ids/estado), nunca e-mail, senha, token ou payload completo. '
  'Retenção proposta: 400 dias (expurgo a implementar com os jobs).';

-- Operações síncronas nunca ficam pending; se aparecer, é outra execução em curso.
create or replace function private.admin_operation_replay(
  p_request_id uuid, p_operation text, p_payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_op public.admin_operations;
begin
  if p_request_id is null then
    raise exception 'request_id obrigatório' using errcode = 'invalid_parameter_value';
  end if;
  select * into v_op from public.admin_operations where request_id = p_request_id;
  if not found then
    return null;
  end if;
  if v_op.operation <> p_operation or v_op.request_hash <> private.row_digest(p_payload) then
    raise exception 'request_id já usado com outro conteúdo' using errcode = 'unique_violation';
  end if;
  if v_op.status <> 'succeeded' then
    raise exception 'operação em andamento' using errcode = 'lock_not_available';
  end if;
  return v_op.result;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Provisionamento em duas fases (B8, B13)
-- ---------------------------------------------------------------------------

drop function public.service_admin_operation_replay(uuid, text, jsonb);
drop function public.service_find_auth_user(text);

create function private.assert_service_actor(p_actor_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not (private.is_admin_identity(p_actor_id) and private.is_active_profile(p_actor_id)) then
    raise exception 'ator não é Admin ativo' using errcode = 'insufficient_privilege';
  end if;
  perform set_config('fluvi.actor_id', p_actor_id::text, true);
end;
$$;

-- Fase 1: reserva o operation_id antes de qualquer efeito externo.
-- Retorna {state: new|resume|done, result?}.
create function public.service_provision_begin(
  p_request_id uuid, p_actor_id uuid, p_payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_op public.admin_operations;
begin
  perform private.assert_service_actor(p_actor_id);
  select * into v_op from public.admin_operations where request_id = p_request_id for update;
  if not found then
    insert into public.admin_operations (request_id, operation, actor_id, request_hash, result, status)
    values (p_request_id, 'provision_user', p_actor_id, private.row_digest(p_payload), '{}', 'pending');
    return jsonb_build_object('state', 'new');
  end if;
  if v_op.operation <> 'provision_user' or v_op.request_hash <> private.row_digest(p_payload) then
    raise exception 'operation_id já usado com outro conteúdo' using errcode = 'unique_violation';
  end if;
  if v_op.status = 'succeeded' then
    return jsonb_build_object('state', 'done', 'result', v_op.result);
  end if;
  return jsonb_build_object('state', 'resume');
end;
$$;

-- Situação de uma identidade Auth para o e-mail, relativa a esta operação.
-- Retorna {state: absent|linked_pending|active|conflict, user_id?}.
create function public.service_provision_identity(p_request_id uuid, p_email text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_count int;
  v_user  uuid;
  v_prof  public.profiles;
begin
  select count(*), min(u.id::text)::uuid into v_count, v_user
    from auth.users u where lower(u.email) = lower(btrim(p_email));
  if v_count = 0 then
    return jsonb_build_object('state', 'absent');
  elsif v_count > 1 then
    return jsonb_build_object('state', 'conflict');
  end if;
  select * into v_prof from public.profiles where user_id = v_user;
  if v_prof.status = 'pending' and v_prof.provision_operation_id = p_request_id then
    return jsonb_build_object('state', 'linked_pending', 'user_id', v_user);
  elsif v_prof.status = 'active' then
    return jsonb_build_object('state', 'active');
  end if;
  return jsonb_build_object('state', 'conflict');
end;
$$;

-- Fase 2: conclui o provisionamento. O perfil continua pending até a ativação.
create or replace function public.service_provision_profile(
  p_request_id   uuid,
  p_actor_id     uuid,
  p_user_id      uuid,
  p_display_name text,
  p_household_id uuid,
  p_payload      jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_op     public.admin_operations;
  v_result jsonb;
begin
  perform private.assert_service_actor(p_actor_id);
  select * into v_op from public.admin_operations where request_id = p_request_id for update;
  if not found or v_op.operation <> 'provision_user'
     or v_op.request_hash <> private.row_digest(p_payload) then
    raise exception 'operação não reservada ou com outro conteúdo' using errcode = 'unique_violation';
  end if;
  if v_op.status = 'succeeded' then
    return v_op.result;
  end if;
  perform private.begin_request(p_request_id);

  update public.profiles
     set display_name = btrim(p_display_name), provisioned_at = coalesce(provisioned_at, now())
   where user_id = p_user_id
     and status = 'pending'
     and provision_operation_id = p_request_id;
  if not found then
    raise exception 'identidade não vinculada a esta operação' using errcode = 'insufficient_privilege';
  end if;

  if p_household_id is not null then
    insert into public.household_members (household_id, user_id, status)
    values (p_household_id, p_user_id, 'active')
    on conflict (household_id, user_id) do update set status = 'active';
  end if;

  perform private.try_activate_profile(p_user_id);

  v_result := jsonb_build_object(
    'user_id', p_user_id,
    'household_id', p_household_id,
    'status', (select status from public.profiles where user_id = p_user_id));
  update public.admin_operations
     set status = 'succeeded', subject_user_id = p_user_id, result = v_result
   where request_id = p_request_id;
  return v_result;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Bootstrap do primeiro Admin (B15)
-- ---------------------------------------------------------------------------

create or replace function private.bootstrap_first_admin(p_email text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count   int;
  v_user_id uuid;
begin
  -- serializa execuções concorrentes até o fim da transação
  perform pg_advisory_xact_lock(hashtext('fluvi.bootstrap_first_admin'));

  select count(*), min(id::text)::uuid into v_count, v_user_id
    from auth.users where lower(email) = lower(btrim(p_email));
  if v_count <> 1 then
    raise exception 'o e-mail precisa corresponder a exatamente um usuário Auth'
      using errcode = 'no_data_found';
  end if;

  if exists (select 1 from public.administrators where user_id <> v_user_id) then
    raise exception 'já existe Admin provisionado (ativo ou pendente); use a interface administrativa'
      using errcode = 'insufficient_privilege';
  end if;

  if exists (select 1 from public.administrators where user_id = v_user_id) then
    return v_user_id;  -- reexecução para o mesmo alvo: sem efeito
  end if;

  if exists (select 1 from public.household_members where user_id = v_user_id and status = 'active')
     or exists (select 1 from public.profiles where user_id = v_user_id and status = 'blocked') then
    raise exception 'alvo inelegível para Admin' using errcode = 'check_violation';
  end if;

  update public.profiles set provisioned_at = coalesce(provisioned_at, now())
   where user_id = v_user_id;
  insert into public.administrators (user_id, active) values (v_user_id, true);
  perform private.try_activate_profile(v_user_id);
  return v_user_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Status: nunca deixar o sistema sem Admin ativo (§19.3)
-- ---------------------------------------------------------------------------

create or replace function public.admin_set_user_status(
  p_request_id uuid, p_user_id uuid, p_status public.profile_status
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_payload jsonb := jsonb_build_object('user_id', p_user_id, 'status', p_status);
  v_result  jsonb;
begin
  perform private.assert_admin();
  v_result := private.admin_operation_replay(p_request_id, 'set_user_status', v_payload);
  if v_result is not null then return v_result; end if;
  if p_user_id = auth.uid() then
    raise exception 'Admin não altera o próprio status' using errcode = 'insufficient_privilege';
  end if;
  perform private.begin_request(p_request_id);

  -- active só é aceito se a ativação já foi concluída (constraint); pending→active manual falha.
  update public.profiles
     set status = p_status, status_changed_at = now()
   where user_id = p_user_id;
  if not found then
    raise exception 'usuário inexistente' using errcode = 'no_data_found';
  end if;

  if not exists (
    select 1 from public.administrators a
    join public.profiles p on p.user_id = a.user_id
    where a.active and p.status = 'active'
  ) then
    raise exception 'operação deixaria o sistema sem Admin ativo' using errcode = 'insufficient_privilege';
  end if;

  return private.admin_operation_record(p_request_id, 'set_user_status', v_payload,
    jsonb_build_object('user_id', p_user_id, 'status', p_status));
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Grant com revisão otimista (§19.3)
-- ---------------------------------------------------------------------------
-- p_expected_revision: revisão vigente que o Admin viu (0 = não existe grant vigente).
-- null = sem verificação (uso interno/teste). Divergência → 40001.

drop function public.admin_set_data_grant(uuid, uuid, uuid, uuid, public.grant_scope,
                                          boolean, boolean, boolean, boolean);

create function public.admin_set_data_grant(
  p_request_id        uuid,
  p_household_id      uuid,
  p_owner             uuid,
  p_grantee           uuid,
  p_scope             public.grant_scope,
  p_can_read          boolean,
  p_can_create        boolean,
  p_can_update        boolean,
  p_can_cancel        boolean,
  p_expected_revision integer default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_payload jsonb := jsonb_build_object(
    'household_id', p_household_id, 'owner', p_owner, 'grantee', p_grantee,
    'scope', p_scope, 'read', p_can_read, 'create', p_can_create,
    'update', p_can_update, 'cancel', p_can_cancel, 'expected_revision', p_expected_revision);
  v_result  jsonb;
  v_grant   public.data_grants;
  v_empty   boolean := not (coalesce(p_can_read, false) or coalesce(p_can_create, false)
                            or coalesce(p_can_update, false) or coalesce(p_can_cancel, false));
begin
  perform private.assert_admin();
  v_result := private.admin_operation_replay(p_request_id, 'set_data_grant', v_payload);
  if v_result is not null then return v_result; end if;
  perform private.begin_request(p_request_id);

  if not exists (
    select 1 from public.household_members
    where household_id = p_household_id and user_id in (p_owner, p_grantee) and status = 'active'
    having count(*) = 2
  ) then
    raise exception 'dono e beneficiário precisam ser membros ativos do núcleo'
      using errcode = 'check_violation';
  end if;

  select * into v_grant from public.data_grants
   where household_id = p_household_id and owner_user_id = p_owner
     and grantee_user_id = p_grantee and resource_scope = p_scope
     and revoked_at is null
   for update;

  if p_expected_revision is not null
     and p_expected_revision <> coalesce(case when found then v_grant.revision end, 0) then
    raise exception 'grant alterado por outra operação (revisão divergente)'
      using errcode = 'serialization_failure';
  end if;

  if found and v_empty then
    update public.data_grants
       set revoked_at = now(), revoked_by = auth.uid(), revision = revision + 1
     where id = v_grant.id
    returning * into v_grant;
  elsif found then
    update public.data_grants
       set can_read = coalesce(p_can_read, false), can_create = coalesce(p_can_create, false),
           can_update = coalesce(p_can_update, false), can_cancel = coalesce(p_can_cancel, false),
           revision = revision + 1
     where id = v_grant.id
    returning * into v_grant;
  elsif not v_empty then
    insert into public.data_grants
      (household_id, owner_user_id, grantee_user_id, resource_scope,
       can_read, can_create, can_update, can_cancel, created_by)
    values
      (p_household_id, p_owner, p_grantee, p_scope,
       coalesce(p_can_read, false), coalesce(p_can_create, false),
       coalesce(p_can_update, false), coalesce(p_can_cancel, false), auth.uid())
    returning * into v_grant;
  end if;

  return private.admin_operation_record(p_request_id, 'set_data_grant', v_payload,
    jsonb_build_object(
      'grant_id', v_grant.id,
      'revision', v_grant.revision,
      'active',   v_grant.id is not null and v_grant.revoked_at is null));
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Privilégios
-- ---------------------------------------------------------------------------

revoke execute on all functions in schema private from public, anon, authenticated;
revoke execute on all functions in schema public from public, anon, authenticated;

grant execute on function
  private.current_aal(),
  private.is_active_profile(uuid),
  private.is_admin_identity(uuid),
  private.is_admin(),
  private.is_financial_user(uuid),
  private.can_access_owner(uuid, public.grant_scope, public.grant_operation),
  private.is_active_member(uuid),
  private.shares_household_with(uuid)
to authenticated, service_role;

grant execute on function
  public.admin_create_household(uuid, text),
  public.admin_set_user_status(uuid, uuid, public.profile_status),
  public.admin_set_household_member(uuid, uuid, uuid, public.member_status),
  public.admin_set_data_grant(uuid, uuid, uuid, uuid, public.grant_scope,
                              boolean, boolean, boolean, boolean, integer),
  public.whoami(),
  public.accessible_owners(public.grant_scope, public.grant_operation)
to authenticated;

grant execute on function
  public.service_provision_begin(uuid, uuid, jsonb),
  public.service_provision_identity(uuid, text),
  public.service_provision_profile(uuid, uuid, uuid, text, uuid, jsonb)
to service_role;
