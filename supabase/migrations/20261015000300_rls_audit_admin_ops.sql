-- Fluvi — Marco A — Políticas RLS, auditoria, operações administrativas.

-- ---------------------------------------------------------------------------
-- 1. Invariantes de identidade
-- ---------------------------------------------------------------------------

-- Identidade administrativa e participação financeira são mutuamente exclusivas.
create function private.enforce_admin_member_exclusivity()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_table_name = 'household_members' then
    if new.status = 'active' and private.is_admin_identity(new.user_id) then
      raise exception 'identidade administrativa não pode participar de núcleo financeiro'
        using errcode = 'check_violation';
    end if;
  elsif tg_table_name = 'administrators' then
    if new.active and exists (
      select 1 from public.household_members m
      where m.user_id = new.user_id and m.status = 'active'
    ) then
      raise exception 'membro de núcleo financeiro não pode ser administrador'
        using errcode = 'check_violation';
    end if;
  end if;
  return new;
end;
$$;

create trigger household_members_admin_exclusivity
  before insert or update on public.household_members
  for each row execute function private.enforce_admin_member_exclusivity();
create trigger administrators_member_exclusivity
  before insert or update on public.administrators
  for each row execute function private.enforce_admin_member_exclusivity();

-- Perfil criado automaticamente para todo usuário Auth, sempre 'pending'.
-- display_name do metadata é apenas cosmético; status nunca vem dele.
create function private.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (user_id, display_name, status)
  values (
    new.id,
    left(coalesce(
      nullif(btrim(new.raw_user_meta_data ->> 'display_name'), ''),
      nullif(split_part(coalesce(new.email, ''), '@', 1), ''),
      'Usuário'
    ), 80),
    'pending'
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function private.handle_new_auth_user();

-- ---------------------------------------------------------------------------
-- 2. Auditoria (append-only, apenas digests)
-- ---------------------------------------------------------------------------

create function private.current_actor()
returns uuid
language sql
stable
set search_path = ''
as $$
  select coalesce(auth.uid(), nullif(current_setting('fluvi.actor_id', true), '')::uuid);
$$;

create function private.row_digest(p_row jsonb)
returns text
language sql
immutable
set search_path = ''
as $$
  select case when p_row is null then null
              else encode(sha256(convert_to(p_row::text, 'UTF8')), 'hex') end;
$$;

-- TG_ARGV: nomes das colunas que compõem a chave da entidade.
create function private.audit_row()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old jsonb := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end;
  v_new jsonb := case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end;
  v_ref jsonb := coalesce(v_new, v_old);
  v_key text  := '';
  i     int;
begin
  if tg_op = 'UPDATE' and v_old = v_new then
    return new;
  end if;
  for i in 0 .. tg_nargs - 1 loop
    v_key := v_key || case when i > 0 then ':' else '' end || (v_ref ->> tg_argv[i]);
  end loop;

  insert into public.audit_events
    (actor_id, action, entity_type, entity_id, before_digest, after_digest, request_id)
  values (
    private.current_actor(),
    lower(tg_op),
    tg_table_name,
    v_key,
    private.row_digest(v_old),
    private.row_digest(v_new),
    nullif(current_setting('fluvi.request_id', true), '')::uuid
  );
  return coalesce(new, old);
end;
$$;

create trigger profiles_audit after insert or update or delete on public.profiles
  for each row execute function private.audit_row('user_id');
create trigger administrators_audit after insert or update or delete on public.administrators
  for each row execute function private.audit_row('user_id');
create trigger households_audit after insert or update or delete on public.households
  for each row execute function private.audit_row('id');
create trigger household_members_audit after insert or update or delete on public.household_members
  for each row execute function private.audit_row('household_id', 'user_id');
create trigger data_grants_audit after insert or update or delete on public.data_grants
  for each row execute function private.audit_row('id');

create function private.audit_events_immutable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'audit_events é append-only' using errcode = 'insufficient_privilege';
end;
$$;

create trigger audit_events_no_update_delete
  before update or delete on public.audit_events
  for each row execute function private.audit_events_immutable();

-- ---------------------------------------------------------------------------
-- 3. Privilégios de tabela e políticas RLS
-- ---------------------------------------------------------------------------

revoke all on
  public.profiles, public.administrators, public.households,
  public.household_members, public.data_grants, public.admin_operations,
  public.audit_events
from anon, authenticated;

grant select on
  public.profiles, public.administrators, public.households,
  public.household_members, public.data_grants, public.admin_operations,
  public.audit_events
to authenticated;

-- único campo que o próprio usuário altera diretamente
grant update (display_name) on public.profiles to authenticated;

-- profiles
create policy profiles_select on public.profiles
  for select to authenticated
  using (
    user_id = (select auth.uid())
    or (select private.is_admin())
    or private.shares_household_with(user_id)
  );

create policy profiles_update_own on public.profiles
  for update to authenticated
  using (user_id = (select auth.uid()) and (select private.is_active_profile(auth.uid())))
  with check (user_id = (select auth.uid()));

-- administrators: cada um vê o próprio papel; Admin com MFA vê todos
create policy administrators_select on public.administrators
  for select to authenticated
  using (user_id = (select auth.uid()) or (select private.is_admin()));

-- households / household_members: membros ativos e Admin com MFA
create policy households_select on public.households
  for select to authenticated
  using ((select private.is_admin()) or private.is_active_member(id));

create policy household_members_select on public.household_members
  for select to authenticated
  using ((select private.is_admin()) or private.is_active_member(household_id));

-- data_grants: dono e beneficiário veem os grants que os envolvem (transparência);
-- ninguém escreve diretamente — somente pelas RPCs administrativas.
create policy data_grants_select on public.data_grants
  for select to authenticated
  using (
    (select private.is_admin())
    or (
      (owner_user_id = (select auth.uid()) or grantee_user_id = (select auth.uid()))
      and (select private.is_financial_user(auth.uid()))
    )
  );

create policy admin_operations_select on public.admin_operations
  for select to authenticated
  using ((select private.is_admin()));

-- auditoria: Admin com MFA vê tudo; usuário vê os próprios eventos
create policy audit_events_select on public.audit_events
  for select to authenticated
  using ((select private.is_admin()) or actor_id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- 4. Idempotência das operações administrativas
-- ---------------------------------------------------------------------------

-- Retorna o resultado já gravado para o request_id, ou null se for novo.
-- Mesmo request_id com operação ou conteúdo diferente é conflito.
create function private.admin_operation_replay(
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
  return v_op.result;
end;
$$;

create function private.admin_operation_record(
  p_request_id uuid, p_operation text, p_payload jsonb, p_result jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.admin_operations (request_id, operation, actor_id, request_hash, result)
  values (p_request_id, p_operation, private.current_actor(), private.row_digest(p_payload), p_result);
  return p_result;
end;
$$;

create function private.assert_admin()
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not private.is_admin() then
    raise exception 'operação administrativa exige Admin ativo com MFA (aal2)'
      using errcode = 'insufficient_privilege';
  end if;
end;
$$;

create function private.begin_request(p_request_id uuid)
returns void
language sql
set search_path = ''
as $$
  select set_config('fluvi.request_id', p_request_id::text, true);
$$;

-- ---------------------------------------------------------------------------
-- 5. RPCs administrativas (expostas; autorização dentro da função)
-- ---------------------------------------------------------------------------

create function public.admin_create_household(p_request_id uuid, p_name text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_payload jsonb := jsonb_build_object('name', p_name);
  v_result  jsonb;
  v_id      uuid;
begin
  perform private.assert_admin();
  v_result := private.admin_operation_replay(p_request_id, 'create_household', v_payload);
  if v_result is not null then return v_result; end if;
  perform private.begin_request(p_request_id);

  insert into public.households (name, created_by)
  values (btrim(p_name), auth.uid())
  returning id into v_id;

  return private.admin_operation_record(p_request_id, 'create_household', v_payload,
    jsonb_build_object('household_id', v_id));
end;
$$;

create function public.admin_set_user_status(
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

  update public.profiles
     set status = p_status, status_changed_at = now()
   where user_id = p_user_id;
  if not found then
    raise exception 'usuário inexistente' using errcode = 'no_data_found';
  end if;

  return private.admin_operation_record(p_request_id, 'set_user_status', v_payload,
    jsonb_build_object('user_id', p_user_id, 'status', p_status));
end;
$$;

create function public.admin_set_household_member(
  p_request_id uuid, p_household_id uuid, p_user_id uuid, p_status public.member_status
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_payload jsonb := jsonb_build_object(
    'household_id', p_household_id, 'user_id', p_user_id, 'status', p_status);
  v_result  jsonb;
begin
  perform private.assert_admin();
  v_result := private.admin_operation_replay(p_request_id, 'set_household_member', v_payload);
  if v_result is not null then return v_result; end if;
  perform private.begin_request(p_request_id);

  insert into public.household_members (household_id, user_id, status)
  values (p_household_id, p_user_id, p_status)
  on conflict (household_id, user_id) do update set status = excluded.status;

  -- Sair do núcleo encerra os grants que dependiam do vínculo.
  if p_status <> 'active' then
    update public.data_grants
       set revoked_at = now(), revoked_by = auth.uid(), revision = revision + 1
     where household_id = p_household_id
       and revoked_at is null
       and (owner_user_id = p_user_id or grantee_user_id = p_user_id);
  end if;

  return private.admin_operation_record(p_request_id, 'set_household_member', v_payload,
    jsonb_build_object('household_id', p_household_id, 'user_id', p_user_id, 'status', p_status));
end;
$$;

-- Cria ou altera o grant vigente de (núcleo, dono, beneficiário, escopo).
-- Todos os flags falsos = revogação.
create function public.admin_set_data_grant(
  p_request_id   uuid,
  p_household_id uuid,
  p_owner        uuid,
  p_grantee      uuid,
  p_scope        public.grant_scope,
  p_can_read     boolean,
  p_can_create   boolean,
  p_can_update   boolean,
  p_can_cancel   boolean
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
    'update', p_can_update, 'cancel', p_can_cancel);
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
-- 6. RPCs para usuários autenticados
-- ---------------------------------------------------------------------------

-- Estado da sessão atual, para o frontend decidir navegação.
-- Fonte: banco, não metadata.
create function public.whoami()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'user_id',            auth.uid(),
    'status',             (select p.status from public.profiles p where p.user_id = auth.uid()),
    'aal',                private.current_aal(),
    'is_admin_identity',  private.is_admin_identity(auth.uid()),
    'can_administer',     private.is_admin(),
    'is_financial_user',  private.is_financial_user(auth.uid())
  )
  where auth.uid() is not null;
$$;

-- Titulares cujos dados o usuário atual pode acessar em (escopo, operação).
-- Alimenta o seletor "usuário(s) autorizado(s)" do topo.
create function public.accessible_owners(
  p_scope public.grant_scope, p_operation public.grant_operation
)
returns table (owner_user_id uuid, display_name text, is_self boolean)
language sql
stable
security invoker
set search_path = ''
as $$
  select p.user_id, p.display_name, p.user_id = auth.uid()
  from public.profiles p
  where private.can_access_owner(p.user_id, p_scope, p_operation)
  order by p.user_id <> auth.uid(), p.display_name;
$$;

-- ---------------------------------------------------------------------------
-- 7. Funções para Edge Functions (apenas service_role)
-- ---------------------------------------------------------------------------

-- Verifica idempotência antes de efeitos externos (ex.: convite por e-mail).
-- Devolve o resultado gravado, null se o request_id é novo, ou erro se conflitar.
create function public.service_admin_operation_replay(
  p_request_id uuid, p_operation text, p_payload jsonb
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select private.admin_operation_replay(p_request_id, p_operation, p_payload);
$$;

-- Localiza usuário Auth por e-mail (retomada de provisionamento interrompido).
create function public.service_find_auth_user(p_email text)
returns table (user_id uuid, profile_status public.profile_status)
language sql
stable
security definer
set search_path = ''
as $$
  select u.id, p.status
  from auth.users u
  left join public.profiles p on p.user_id = u.id
  where lower(u.email) = lower(btrim(p_email));
$$;

-- Conclui o provisionamento de um usuário convidado pelo Auth Admin API.
-- A Edge Function verifica que o chamador é Admin aal2 antes de invocar.
create function public.service_provision_profile(
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
  v_result jsonb;
begin
  if not (private.is_admin_identity(p_actor_id) and private.is_active_profile(p_actor_id)) then
    raise exception 'ator não é Admin ativo' using errcode = 'insufficient_privilege';
  end if;
  perform set_config('fluvi.actor_id', p_actor_id::text, true);
  v_result := private.admin_operation_replay(p_request_id, 'provision_user', p_payload);
  if v_result is not null then return v_result; end if;
  perform private.begin_request(p_request_id);

  update public.profiles
     set display_name = btrim(p_display_name), status = 'active', status_changed_at = now()
   where user_id = p_user_id;
  if not found then
    raise exception 'perfil do usuário não encontrado' using errcode = 'no_data_found';
  end if;

  if p_household_id is not null then
    insert into public.household_members (household_id, user_id, status)
    values (p_household_id, p_user_id, 'active')
    on conflict (household_id, user_id) do update set status = 'active';
  end if;

  return private.admin_operation_record(p_request_id, 'provision_user', p_payload,
    jsonb_build_object('user_id', p_user_id, 'household_id', p_household_id));
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. Bootstrap do primeiro Admin (somente operação privilegiada, sem grant)
-- ---------------------------------------------------------------------------
-- Uso documentado em docs/operacao/bootstrap-admin.md:
--   select private.bootstrap_first_admin('admin@exemplo.com');
create function private.bootstrap_first_admin(p_email text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
begin
  if exists (select 1 from public.administrators where active) then
    raise exception 'já existe Admin ativo; use a interface administrativa'
      using errcode = 'insufficient_privilege';
  end if;
  select id into v_user_id from auth.users where lower(email) = lower(btrim(p_email));
  if v_user_id is null then
    raise exception 'usuário Auth não encontrado para o e-mail informado'
      using errcode = 'no_data_found';
  end if;
  update public.profiles set status = 'active', status_changed_at = now()
   where user_id = v_user_id;
  insert into public.administrators (user_id, active) values (v_user_id, true)
  on conflict (user_id) do update set active = true;
  return v_user_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- 9. Execução das funções
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
                              boolean, boolean, boolean, boolean),
  public.whoami(),
  public.accessible_owners(public.grant_scope, public.grant_operation)
to authenticated;

grant execute on function
  public.service_admin_operation_replay(uuid, text, jsonb),
  public.service_find_auth_user(text),
  public.service_provision_profile(uuid, uuid, uuid, text, uuid, jsonb)
to service_role;
