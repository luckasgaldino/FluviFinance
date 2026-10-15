-- Fluvi — Marco A — D5: leitura para o painel administrativo.
-- O e-mail fica em auth.users e nunca é exposto a membros (B4). O Admin com MFA
-- precisa dele para identificar quem convidou e quem bloqueia.
-- Leitura não consome o limite admin_rpc (que protege operações de escrita).
create function public.admin_list_users()
returns table (
  user_id                 uuid,
  email                   text,
  display_name            text,
  status                  public.profile_status,
  is_admin                boolean,
  provisioned_at          timestamptz,
  activation_completed_at timestamptz,
  status_changed_at       timestamptz,
  last_sign_in_at         timestamptz,
  has_mfa                 boolean
)
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
  return query
    select p.user_id, u.email::text, p.display_name, p.status,
           coalesce(a.active, false),
           p.provisioned_at, p.activation_completed_at, p.status_changed_at,
           u.last_sign_in_at,
           exists (select 1 from auth.mfa_factors f where f.user_id = p.user_id and f.status = 'verified')
      from public.profiles p
      join auth.users u on u.id = p.user_id
      left join public.administrators a on a.user_id = p.user_id
     order by coalesce(a.active, false) desc, p.display_name;
end;
$$;

revoke execute on function public.admin_list_users() from public, anon, authenticated;
grant execute on function public.admin_list_users() to authenticated;
