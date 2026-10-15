-- Fluvi — Marco A — D3 (rate limiting no servidor) e recuperação do único Admin (§19.6).
--
-- Rate limiting: janela fixa por (tipo, chave), contador atômico via upsert.
--   * Login, recuperação de senha e verificação de tokens são limitados pelo
--     Supabase Auth (config/painel) — ver docs/operacao/rate-limiting.md.
--   * Aqui ficam os limites das operações do próprio Fluvi.
--   * Erro PT429 → PostgREST responde HTTP 429.

-- ---------------------------------------------------------------------------
-- 1. Rate limiting
-- ---------------------------------------------------------------------------

create table private.rate_limit_policies (
  bucket_kind    text primary key,
  max_hits       integer not null check (max_hits > 0),
  window_seconds integer not null check (window_seconds > 0),
  description    text not null
);

insert into private.rate_limit_policies (bucket_kind, max_hits, window_seconds, description) values
  ('admin_rpc',    120,  600, 'RPCs administrativas por Admin'),
  ('invite_actor',  20, 3600, 'convites iniciados por Admin'),
  ('invite_email',   3, 3600, 'convites para o mesmo e-mail de destino');

create table private.rate_limit_counters (
  bucket_kind  text not null references private.rate_limit_policies (bucket_kind),
  bucket_key   text not null,
  window_start timestamptz not null,
  hits         integer not null,
  primary key (bucket_kind, bucket_key, window_start)
);

-- Consome uma unidade; acima do limite lança PT429.
-- A contagem participa da transação do chamador: se a operação falhar e for
-- revertida, o consumo também é (efeito documentado em rate-limiting.md).
create function private.rate_limit_consume(p_kind text, p_key text)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_policy private.rate_limit_policies;
  v_window timestamptz;
  v_hits   integer;
begin
  select * into v_policy from private.rate_limit_policies where bucket_kind = p_kind;
  if not found then
    raise exception 'política de rate limit inexistente: %', p_kind using errcode = 'invalid_parameter_value';
  end if;

  v_window := to_timestamp(
    floor(extract(epoch from clock_timestamp()) / v_policy.window_seconds) * v_policy.window_seconds);

  insert into private.rate_limit_counters as c (bucket_kind, bucket_key, window_start, hits)
  values (p_kind, p_key, v_window, 1)
  on conflict (bucket_kind, bucket_key, window_start) do update set hits = c.hits + 1
  returning hits into v_hits;

  -- expira janelas anteriores desta chave
  delete from private.rate_limit_counters
   where bucket_kind = p_kind and bucket_key = p_key and window_start < v_window;

  if v_hits > v_policy.max_hits then
    raise exception 'limite de requisições excedido'
      using errcode = 'PT429',
            detail  = format('%s: %s em %s s', p_kind, v_policy.max_hits, v_policy.window_seconds),
            hint    = format('tente novamente após %s', v_window + make_interval(secs => v_policy.window_seconds));
  end if;
end;
$$;

-- Toda RPC administrativa passa por aqui: agora também consome o limite do Admin.
create or replace function private.assert_admin()
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if not private.is_admin() then
    raise exception 'operação administrativa exige Admin ativo com MFA (aal2)'
      using errcode = 'insufficient_privilege';
  end if;
  perform private.rate_limit_consume('admin_rpc', auth.uid()::text);
end;
$$;

-- Convites: limite por Admin e por e-mail de destino, só para operações novas
-- (repetição idempotente do mesmo operation_id não consome).
create or replace function public.service_provision_begin(
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
    perform private.rate_limit_consume('invite_actor', p_actor_id::text);
    perform private.rate_limit_consume('invite_email', lower(btrim(p_payload ->> 'email')));
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

-- ---------------------------------------------------------------------------
-- 2. Recuperação do único Admin (§19.6, procedimento em docs/operacao/recuperacao-admin.md)
-- ---------------------------------------------------------------------------
-- Funções sem EXECUTE para nenhum papel de aplicação: só o dono do banco (SQL Editor).
-- O motivo é registrado como digest; o texto fica no registro externo do incidente.

create function private.audit_recovery(p_action text, p_user_id uuid, p_reason text)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.audit_events (actor_id, action, entity_type, entity_id, after_digest)
  values (null, p_action, 'administrators', p_user_id::text,
          private.row_digest(jsonb_build_object('reason', p_reason, 'at', now())));
$$;

create function private.resolve_single_auth_user(p_email text)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_count int;
  v_id    uuid;
begin
  select count(*), min(id::text)::uuid into v_count, v_id
    from auth.users where lower(email) = lower(btrim(p_email));
  if v_count <> 1 then
    raise exception 'o e-mail precisa corresponder a exatamente um usuário Auth' using errcode = 'no_data_found';
  end if;
  return v_id;
end;
$$;

-- Caso 1: Admin perdeu o dispositivo TOTP. Remove os fatores MFA e encerra as
-- sessões; o Admin entra de novo (aal1, sem poderes) e recadastra o TOTP.
create function private.admin_recovery_reset_mfa(p_email text, p_reason text)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user    uuid;
  v_factors integer;
begin
  if coalesce(char_length(btrim(p_reason)), 0) < 10 then
    raise exception 'informe o motivo (mín. 10 caracteres) e registre o incidente' using errcode = 'invalid_parameter_value';
  end if;
  perform pg_advisory_xact_lock(hashtext('fluvi.admin_recovery'));
  v_user := private.resolve_single_auth_user(p_email);
  if not exists (select 1 from public.administrators where user_id = v_user and active) then
    raise exception 'alvo não é Admin ativo' using errcode = 'insufficient_privilege';
  end if;

  delete from auth.mfa_factors where user_id = v_user;
  get diagnostics v_factors = row_count;
  delete from auth.sessions where user_id = v_user;

  perform private.audit_recovery('recovery_reset_mfa', v_user, p_reason);
  return v_factors;
end;
$$;

-- Caso 2: Admin perdeu o acesso à conta/e-mail ou a conta foi comprometida.
-- Desativa e bloqueia o Admin atual, encerra as sessões dele e atribui o papel
-- a outra identidade já convidada (mesmas guardas do bootstrap).
create function private.admin_recovery_replace(p_old_email text, p_new_email text, p_reason text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old uuid;
  v_new uuid;
begin
  if coalesce(char_length(btrim(p_reason)), 0) < 10 then
    raise exception 'informe o motivo (mín. 10 caracteres) e registre o incidente' using errcode = 'invalid_parameter_value';
  end if;
  perform pg_advisory_xact_lock(hashtext('fluvi.admin_recovery'));
  perform pg_advisory_xact_lock(hashtext('fluvi.bootstrap_first_admin'));

  v_old := private.resolve_single_auth_user(p_old_email);
  v_new := private.resolve_single_auth_user(p_new_email);
  if v_old = v_new then
    raise exception 'novo Admin deve ser outra identidade' using errcode = 'check_violation';
  end if;
  if not exists (select 1 from public.administrators where user_id = v_old and active) then
    raise exception 'Admin a substituir não está ativo' using errcode = 'insufficient_privilege';
  end if;
  if exists (select 1 from public.administrators where active and user_id <> v_old) then
    raise exception 'existe outro Admin ativo: use a interface administrativa' using errcode = 'insufficient_privilege';
  end if;
  if exists (select 1 from public.administrators where user_id = v_new)
     or exists (select 1 from public.household_members where user_id = v_new and status = 'active')
     or exists (select 1 from public.profiles where user_id = v_new and status = 'blocked') then
    raise exception 'alvo inelegível para Admin' using errcode = 'check_violation';
  end if;

  update public.administrators set active = false where user_id = v_old;
  update public.profiles set status = 'blocked', status_changed_at = now() where user_id = v_old;
  delete from auth.sessions where user_id = v_old;

  update public.profiles set provisioned_at = coalesce(provisioned_at, now()) where user_id = v_new;
  insert into public.administrators (user_id, active) values (v_new, true);
  perform private.try_activate_profile(v_new);

  perform private.audit_recovery('recovery_replace_admin', v_new, p_reason);
  return v_new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Exclusão de identidade sem conflito de cascata
-- ---------------------------------------------------------------------------
-- Excluir um usuário Auth apaga em cascata perfil → vínculos → grants. As FKs
-- created_by/revoked_by (ON DELETE SET NULL) tentavam atualizar grants cujo
-- vínculo estava sendo apagado na mesma operação, violando a FK composta
-- conforme a ordem das cascatas. São metadados de autoria; o histórico fica em
-- audit_events, que deve sobreviver à exclusão da pessoa.
alter table public.data_grants
  drop constraint data_grants_created_by_fkey,
  drop constraint data_grants_revoked_by_fkey;

-- ---------------------------------------------------------------------------
-- 4. Privilégios
-- ---------------------------------------------------------------------------
revoke all on private.rate_limit_policies, private.rate_limit_counters from public, anon, authenticated;
revoke execute on all functions in schema private from public, anon, authenticated;

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

grant execute on function public.service_provision_begin(uuid, uuid, jsonb) to service_role;
