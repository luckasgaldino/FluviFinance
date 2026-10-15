-- Fluvi — Marco A — Fundação: identidade, núcleos e autorizações.
-- Princípios (Especificação v1.0, §5, §6, §10):
--   * negar por padrão: nenhum privilégio implícito para anon/authenticated;
--   * RLS em toda tabela exposta;
--   * permissões nunca vêm de user_metadata (editável pelo próprio usuário);
--   * Admin administra identidades, mas não tem acesso financeiro implícito.

-- ---------------------------------------------------------------------------
-- 0. Postura de privilégios
-- ---------------------------------------------------------------------------

-- Tabelas e funções futuras em public não recebem privilégios automáticos:
-- cada objeto exposto concede explicitamente o mínimo necessário.
alter default privileges for role postgres in schema public
  revoke all on tables from anon, authenticated;
alter default privileges for role postgres in schema public
  revoke all on sequences from anon, authenticated;
alter default privileges for role postgres in schema public
  revoke execute on functions from public, anon, authenticated;

-- Schema privado: funções auxiliares de autorização e operações internas.
-- Não é listado em [api].schemas, portanto não é exposto pelo PostgREST.
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
grant usage on schema private to authenticated, service_role;

alter default privileges for role postgres in schema private
  revoke execute on functions from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 1. Tipos
-- ---------------------------------------------------------------------------

create type public.profile_status as enum ('pending', 'active', 'blocked');
create type public.member_status  as enum ('active', 'suspended', 'removed');

-- Escopos de recurso de um grant. 'all' cobre todos os escopos financeiros.
-- Novos escopos entram por migration junto com o módulo que os usa.
create type public.grant_scope as enum (
  'all', 'accounts', 'cards', 'transactions', 'goals', 'reports'
);

create type public.grant_operation as enum ('read', 'create', 'update', 'cancel');

-- ---------------------------------------------------------------------------
-- 2. Utilitário de updated_at
-- ---------------------------------------------------------------------------

create function private.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Tabelas de identidade
-- ---------------------------------------------------------------------------

create table public.profiles (
  user_id           uuid primary key references auth.users (id) on delete cascade,
  status            public.profile_status not null default 'pending',
  display_name      text not null
                    check (char_length(btrim(display_name)) between 1 and 80),
  status_changed_at timestamptz not null default now(),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
comment on table public.profiles is
  'Perfil de cada identidade. status é controlado só pelo Admin (RPC), nunca por metadata.';

create table public.administrators (
  user_id    uuid primary key references public.profiles (user_id) on delete cascade,
  active     boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
comment on table public.administrators is
  'Identidades exclusivamente administrativas. Não podem pertencer a núcleos financeiros.';

create table public.households (
  id         uuid primary key default gen_random_uuid(),
  name       text not null check (char_length(btrim(name)) between 1 and 80),
  active     boolean not null default true,
  created_by uuid references public.profiles (user_id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.household_members (
  household_id uuid not null references public.households (id) on delete restrict,
  user_id      uuid not null references public.profiles (user_id) on delete cascade,
  status       public.member_status not null default 'active',
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  primary key (household_id, user_id)
);
create index household_members_user_idx on public.household_members (user_id);

create table public.data_grants (
  id              uuid primary key default gen_random_uuid(),
  household_id    uuid not null,
  owner_user_id   uuid not null,
  grantee_user_id uuid not null,
  resource_scope  public.grant_scope not null,
  can_read        boolean not null default false,
  can_create      boolean not null default false,
  can_update      boolean not null default false,
  can_cancel      boolean not null default false,
  revision        integer not null default 1 check (revision >= 1),
  revoked_at      timestamptz,
  revoked_by      uuid references public.profiles (user_id) on delete set null,
  created_by      uuid references public.profiles (user_id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  -- dono e beneficiário precisam ser membros do mesmo núcleo
  foreign key (household_id, owner_user_id)
    references public.household_members (household_id, user_id) on delete cascade,
  foreign key (household_id, grantee_user_id)
    references public.household_members (household_id, user_id) on delete cascade,
  constraint data_grants_not_self check (owner_user_id <> grantee_user_id),
  -- editar ou cancelar exige poder ler o registro-alvo
  constraint data_grants_write_requires_read
    check (can_read or not (can_update or can_cancel)),
  -- grant ativo precisa conceder alguma coisa; para tirar tudo, revogar
  constraint data_grants_active_not_empty
    check (revoked_at is not null or can_read or can_create or can_update or can_cancel)
);
-- um único grant vigente por (núcleo, dono, beneficiário, escopo)
create unique index data_grants_one_active_idx
  on public.data_grants (household_id, owner_user_id, grantee_user_id, resource_scope)
  where revoked_at is null;
create index data_grants_grantee_idx
  on public.data_grants (grantee_user_id, owner_user_id) where revoked_at is null;

-- Registro de idempotência das operações administrativas (provision-user,
-- set-data-grant etc.). O mesmo request_id com outro conteúdo é conflito.
create table public.admin_operations (
  request_id   uuid primary key,
  operation    text not null,
  actor_id     uuid not null,
  request_hash text not null,
  result       jsonb not null,
  created_at   timestamptz not null default now()
);

-- Trilha de auditoria append-only. Sem valores secretos nem cópias de documentos:
-- apenas digests do estado antes/depois.
create table public.audit_events (
  id            uuid primary key default gen_random_uuid(),
  actor_id      uuid,
  action        text not null,
  entity_type   text not null,
  entity_id     text not null,
  before_digest text,
  after_digest  text,
  request_id    uuid,
  created_at    timestamptz not null default now()
);
create index audit_events_entity_idx on public.audit_events (entity_type, entity_id, created_at);
create index audit_events_actor_idx  on public.audit_events (actor_id, created_at);

-- updated_at
create trigger profiles_touch       before update on public.profiles
  for each row execute function private.touch_updated_at();
create trigger administrators_touch before update on public.administrators
  for each row execute function private.touch_updated_at();
create trigger households_touch     before update on public.households
  for each row execute function private.touch_updated_at();
create trigger household_members_touch before update on public.household_members
  for each row execute function private.touch_updated_at();
create trigger data_grants_touch    before update on public.data_grants
  for each row execute function private.touch_updated_at();

-- RLS em todas as tabelas expostas (políticas na migration seguinte).
alter table public.profiles          enable row level security;
alter table public.administrators    enable row level security;
alter table public.households        enable row level security;
alter table public.household_members enable row level security;
alter table public.data_grants       enable row level security;
alter table public.admin_operations  enable row level security;
alter table public.audit_events      enable row level security;
