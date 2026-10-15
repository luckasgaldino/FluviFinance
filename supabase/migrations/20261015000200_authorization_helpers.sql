-- Fluvi — Marco A — Funções de autorização.
-- Todas avaliam o estado persistido a cada consulta: bloquear um usuário,
-- suspender um vínculo ou revogar um grant vale imediatamente, mesmo com JWT
-- ainda válido. Nenhuma lê user_metadata.

-- Nível de autenticação da sessão atual ('aal1' ou 'aal2').
create function private.current_aal()
returns text
language sql
stable
set search_path = ''
as $$
  select coalesce(auth.jwt() ->> 'aal', 'aal1');
$$;

create function private.is_active_profile(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.profiles p
    where p.user_id = p_user_id and p.status = 'active'
  );
$$;

-- Identidade administrativa ativa (qualquer AAL). Usada para negar o uso
-- financeiro dessas contas, nunca para conceder acesso.
create function private.is_admin_identity(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.administrators a
    where a.user_id = p_user_id and a.active
  );
$$;

-- Admin autorizado a administrar: perfil ativo, papel ativo e sessão com MFA (aal2).
create function private.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select auth.uid() is not null
     and private.current_aal() = 'aal2'
     and private.is_admin_identity(auth.uid())
     and private.is_active_profile(auth.uid());
$$;

-- Usuário financeiro: perfil ativo e não administrativo.
create function private.is_financial_user(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_user_id is not null
     and private.is_active_profile(p_user_id)
     and not private.is_admin_identity(p_user_id);
$$;

-- Ponto único de decisão para dados financeiros.
-- O usuário atual pode executar p_operation sobre dados de p_owner no escopo p_scope?
--   * titular: sempre, se for usuário financeiro ativo;
--   * terceiro: apenas com grant vigente, no mesmo núcleo ativo, ambos membros
--     ativos e ambos perfis ativos;
--   * Admin: nunca por ser Admin.
create function private.can_access_owner(
  p_owner     uuid,
  p_scope     public.grant_scope,
  p_operation public.grant_operation
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when auth.uid() is null or p_owner is null then false
    when not private.is_financial_user(auth.uid()) then false
    when p_owner = auth.uid() then true
    else
      private.is_financial_user(p_owner)
      and exists (
        select 1
        from public.data_grants g
        join public.households h
          on h.id = g.household_id and h.active
        join public.household_members mo
          on mo.household_id = g.household_id
         and mo.user_id = g.owner_user_id
         and mo.status = 'active'
        join public.household_members mg
          on mg.household_id = g.household_id
         and mg.user_id = g.grantee_user_id
         and mg.status = 'active'
        where g.owner_user_id = p_owner
          and g.grantee_user_id = auth.uid()
          and g.revoked_at is null
          and g.resource_scope in (p_scope, 'all')
          and case p_operation
                when 'read'   then g.can_read
                when 'create' then g.can_create
                when 'update' then g.can_update
                when 'cancel' then g.can_cancel
              end
      )
  end;
$$;

-- O usuário atual é membro ativo do núcleo ativo?
create function private.is_active_member(p_household uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.household_members m
    join public.households h on h.id = m.household_id and h.active
    where m.household_id = p_household
      and m.user_id = auth.uid()
      and m.status = 'active'
  ) and private.is_financial_user(auth.uid());
$$;

-- O usuário atual compartilha algum núcleo ativo com p_user (para ver nomes).
create function private.shares_household_with(p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select private.is_financial_user(auth.uid()) and exists (
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
