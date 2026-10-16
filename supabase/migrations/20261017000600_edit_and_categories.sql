-- Remodelagem v2.2 — R4b: edição de lançamento com histórico (FF-02) e categorias da família
-- com arquivamento (FF-08).
--
-- * Editar = anular o original (compensação na data original, histórico preservado) e registrar
--   o novo, numa única transação idempotente; o novo aponta o original em
--   replaces_transaction_id. Só receitas e despesas: compras no cartão têm ajuste de parcelas,
--   estorno e anulação próprios. Exige o desbloqueio (operação 'update').
-- * Categorias: além das padrão, cada família cria as suas; arquivar não apaga histórico
--   (lançamentos antigos continuam com a categoria; novos lançamentos não a aceitam).

alter table public.transactions
  add column replaces_transaction_id uuid references public.transactions (id);
create index transactions_replaces_idx on public.transactions (replaces_transaction_id)
  where replaces_transaction_id is not null;

create function public.edit_transaction(
  p_op uuid, p_transaction uuid, p_amount_cents bigint, p_description text, p_category uuid,
  p_account uuid, p_local_date date, p_competence_month date default null, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_txn     public.transactions;
  v_new     uuid;
  v_payload jsonb := jsonb_build_object('txn', p_transaction, 'amt', p_amount_cents, 'desc', p_description,
    'cat', p_category, 'acc', p_account, 'date', p_local_date, 'comp', p_competence_month, 'note', p_note);
  v_res     jsonb;
begin
  select * into v_txn from public.transactions where id = p_transaction;
  perform private.require_access(v_txn.family_id, 'transactions', 'update');
  v_res := private.fin_replay(v_txn.family_id, p_op, 'edit_transaction', v_payload);
  if v_res is not null then return v_res; end if;

  select * into v_txn from public.transactions where id = p_transaction for update;
  if v_txn.status <> 'active' then
    raise exception 'operação não está ativa' using errcode = 'check_violation';
  end if;
  if v_txn.type not in ('income', 'expense') then
    raise exception 'só receitas e despesas são editáveis; para compras no cartão use ajuste de parcelas, estorno ou anulação'
      using errcode = 'check_violation';
  end if;

  -- anular (mesmas regras e travas da anulação) e registrar o novo, com chaves derivadas
  perform public.void_transaction(md5(p_op::text || ':anular')::uuid, p_transaction, 'substituído por edição');
  v_new := (public.create_transaction(md5(p_op::text || ':novo')::uuid, v_txn.family_id, v_txn.type, p_account,
    p_amount_cents, p_description, p_category, p_local_date, p_competence_month, p_note, null) ->> 'id')::uuid;
  update public.transactions set replaces_transaction_id = p_transaction where id = v_new;

  return private.fin_record(v_txn.family_id, p_op, 'edit_transaction', v_payload, private.result(v_new));
end;
$$;

-- ---------------------------------------------------------------------------
-- Categorias da família
-- ---------------------------------------------------------------------------
create function public.family_categories(p_family uuid)
returns table (id uuid, name text, kind public.category_kind, active boolean)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_access(p_family, 'transactions', 'create');
  return query
    select c.id, c.name, c.kind, c.active from public.categories c
     where c.family_id = p_family order by c.active desc, c.kind, c.name;
end;
$$;

create function public.create_category(p_family uuid, p_name text, p_kind public.category_kind)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_name text := btrim(coalesce(p_name, ''));
  v_id   uuid;
begin
  perform private.require_access(p_family, 'transactions', 'create');
  if char_length(v_name) not between 1 and 60 then
    raise exception 'informe um nome de categoria com até 60 caracteres' using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.categories c
              where c.kind = p_kind and lower(c.name) = lower(v_name)
                and (c.family_id is null or c.family_id = p_family)) then
    raise exception 'categoria já existe' using errcode = 'check_violation';
  end if;
  insert into public.categories (family_id, name, kind) values (p_family, v_name, p_kind) returning id into v_id;
  return private.result(v_id);
end;
$$;

-- Arquivar/reativar: só categorias da própria família (as padrão são compartilhadas).
create function public.set_category_active(p_category uuid, p_active boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_family uuid;
begin
  select family_id into v_family from public.categories where id = p_category;
  perform private.require_access(v_family, 'transactions', 'create');
  update public.categories set active = p_active where id = p_category;
  return private.result(p_category);
end;
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'edit_transaction(uuid, uuid, bigint, text, uuid, uuid, date, date, text)',
    'family_categories(uuid)', 'create_category(uuid, text, public.category_kind)', 'set_category_active(uuid, boolean)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
