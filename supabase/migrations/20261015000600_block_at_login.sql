-- Fluvi — Marco A — D4: bloqueio também no login (§19.2, §19.8).
-- Três camadas, da mais cedo para a mais tarde:
--   1. emissão de token: o Custom Access Token Hook recusa login e refresh de perfil bloqueado;
--   2. sessões: bloquear encerra as sessões (refresh tokens deixam de valer na hora);
--   3. dados: access token já emitido continua negado pela RLS (is_active_profile).

-- ---------------------------------------------------------------------------
-- 1. Custom Access Token Hook
-- ---------------------------------------------------------------------------
-- Executado pelo Supabase Auth (papel supabase_auth_admin) antes de emitir
-- qualquer access token: login por senha, refresh, magic link, convite, recuperação.
-- Não adiciona claims de autorização: permissões continuam vindo do banco.
create function public.custom_access_token_hook(event jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_status public.profile_status;
begin
  select p.status into v_status
    from public.profiles p
   where p.user_id = (event ->> 'user_id')::uuid;

  if v_status = 'blocked' then
    return jsonb_build_object('error', jsonb_build_object(
      'http_code', 403,
      'message', 'Conta bloqueada. Procure o administrador.'));
  end if;

  return jsonb_build_object('claims', event -> 'claims');
end;
$$;

revoke execute on function public.custom_access_token_hook(jsonb) from public, anon, authenticated;
grant execute on function public.custom_access_token_hook(jsonb) to supabase_auth_admin;

-- ---------------------------------------------------------------------------
-- 2. Bloquear encerra as sessões
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

  -- refresh tokens dependem da sessão: deixam de valer imediatamente
  if p_status = 'blocked' then
    delete from auth.sessions where user_id = p_user_id;
  end if;

  return private.admin_operation_record(p_request_id, 'set_user_status', v_payload,
    jsonb_build_object('user_id', p_user_id, 'status', p_status));
end;
$$;
