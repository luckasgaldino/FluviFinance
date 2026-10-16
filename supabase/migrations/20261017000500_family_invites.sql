-- Remodelagem v2.2 — R5: convite e aceite para entrar numa família (§2, FAM-03).
--
-- * O Admin CONVIDA: vincular alguém (ou reativar um vínculo suspenso/removido) grava
--   'invited'. Nada é liberado antes do aceite: só membros 'active' acessam a família.
-- * A pessoa aceita ou recusa no app, com o aviso de que verá TODO o histórico da família.
-- * Provisionar usuário novo já indicando a família também gera convite.
-- * Identidade administrativa não pode ser convidada (sem acesso financeiro, PRIV-10).

alter table public.household_members
  add column invited_at  timestamptz,
  add column invited_by  uuid references public.profiles (user_id) on delete set null,
  add column accepted_at timestamptz;

-- vínculos ativos existentes contam como aceitos
update public.household_members set accepted_at = created_at where status = 'active' and accepted_at is null;

create or replace function public.admin_set_household_member(
  p_request_id uuid, p_household_id uuid, p_user_id uuid, p_status public.member_status)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_payload jsonb := jsonb_build_object(
    'household_id', p_household_id, 'user_id', p_user_id, 'status', p_status);
  v_result  jsonb;
  v_current public.member_status;
  v_status  public.member_status := p_status;
begin
  perform private.assert_admin();
  v_result := private.admin_operation_replay(p_request_id, 'set_household_member', v_payload);
  if v_result is not null then return v_result; end if;
  perform private.begin_request(p_request_id);

  if p_status in ('active', 'invited') and private.is_admin_identity(p_user_id) then
    raise exception 'identidade administrativa não pode participar de família' using errcode = 'check_violation';
  end if;

  select status into v_current from public.household_members
   where household_id = p_household_id and user_id = p_user_id;
  -- entrar (ou voltar) para a família é sempre um convite: só a própria pessoa aceita
  if p_status = 'active' and v_current is distinct from 'active' then
    v_status := 'invited';
  end if;

  insert into public.household_members (household_id, user_id, status, invited_at, invited_by, accepted_at)
  values (p_household_id, p_user_id, v_status,
          case when v_status = 'invited' then now() end,
          case when v_status = 'invited' then auth.uid() end, null)
  on conflict (household_id, user_id) do update
    set status      = excluded.status,
        invited_at  = case when excluded.status = 'invited' then now() else household_members.invited_at end,
        invited_by  = case when excluded.status = 'invited' then auth.uid() else household_members.invited_by end,
        accepted_at = case when excluded.status = 'invited' then null else household_members.accepted_at end;

  -- permissões individuais legadas (sem efeito desde a R2) acompanham a saída
  if v_status <> 'active' then
    update public.data_grants
       set revoked_at = now(), revoked_by = auth.uid(), revision = revision + 1
     where household_id = p_household_id
       and revoked_at is null
       and (owner_user_id = p_user_id or grantee_user_id = p_user_id);
  end if;

  return private.admin_operation_record(p_request_id, 'set_household_member', v_payload,
    jsonb_build_object('household_id', p_household_id, 'user_id', p_user_id, 'status', v_status));
end;
$$;

create or replace function public.service_provision_profile(
  p_request_id uuid, p_actor_id uuid, p_user_id uuid, p_display_name text, p_household_id uuid, p_payload jsonb)
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

  -- v2.2: indicar a família no provisionamento gera um CONVITE (aceite no app)
  if p_household_id is not null then
    insert into public.household_members (household_id, user_id, status, invited_at, invited_by)
    values (p_household_id, p_user_id, 'invited', now(), p_actor_id)
    on conflict (household_id, user_id) do update
      set status = 'invited', invited_at = now(), invited_by = p_actor_id, accepted_at = null
      where household_members.status <> 'active';
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
-- Convites do próprio usuário
-- ---------------------------------------------------------------------------
create function public.my_family_invites()
returns table (family_id uuid, name text, invited_at timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select h.id, h.name, m.invited_at
    from public.household_members m
    join public.households h on h.id = m.household_id and h.active
   where m.user_id = auth.uid()
     and m.status = 'invited'
     and private.is_financial_user(auth.uid())
   order by m.invited_at, h.name;
$$;

create function public.accept_family_invite(p_family uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if not private.is_financial_user(auth.uid()) then
    raise exception 'não encontrado ou sem permissão' using errcode = 'no_data_found', hint = 'not_found_or_forbidden';
  end if;
  update public.household_members m
     set status = 'active', accepted_at = now()
    from public.households h
   where m.household_id = p_family and m.user_id = auth.uid() and m.status = 'invited'
     and h.id = m.household_id and h.active;
  if not found then
    raise exception 'não encontrado ou sem permissão' using errcode = 'no_data_found', hint = 'not_found_or_forbidden';
  end if;
  return jsonb_build_object('family_id', p_family, 'status', 'active');
end;
$$;

create function public.decline_family_invite(p_family uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  update public.household_members
     set status = 'removed'
   where household_id = p_family and user_id = auth.uid() and status = 'invited';
  if not found then
    raise exception 'não encontrado ou sem permissão' using errcode = 'no_data_found', hint = 'not_found_or_forbidden';
  end if;
  return jsonb_build_object('family_id', p_family, 'status', 'removed');
end;
$$;

do $$
declare f text;
begin
  foreach f in array array['my_family_invites()', 'accept_family_invite(uuid)', 'decline_family_invite(uuid)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
