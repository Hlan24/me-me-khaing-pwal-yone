begin;

-- =========================================================
-- 1. FARMER: unused => delete, already used => deactivate
-- =========================================================

create or replace function public.remove_or_deactivate_farmer(
  p_customer_id text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_id text := trim(coalesce(p_customer_id, ''));
begin
  perform public.require_staff_roles(array['owner']);

  if v_id = '' then
    raise exception 'Farmer ID is required'
      using errcode = '22023';
  end if;

  if not exists (
    select 1
    from public.farmers as farmers
    where farmers.customer_id = v_id
  ) then
    raise exception 'Farmer not found: %', v_id
      using errcode = 'P0002';
  end if;

  begin
    delete from public.farmers as farmers
    where farmers.customer_id = v_id;

    return jsonb_build_object(
      'action', 'DELETED',
      'customer_id', v_id
    );

  exception
    when foreign_key_violation then
      update public.farmers as farmers
      set
        active = false,
        updated_by = auth.uid(),
        updated_at = now()
      where farmers.customer_id = v_id;

      return jsonb_build_object(
        'action', 'DEACTIVATED',
        'customer_id', v_id
      );
  end;
end;
$$;


-- =========================================================
-- 2. PRODUCT: unused => delete, already used => deactivate
-- =========================================================

create or replace function public.remove_or_deactivate_product(
  p_product_id text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_id text := trim(coalesce(p_product_id, ''));
begin
  perform public.require_staff_roles(array['owner']);

  if v_id = '' then
    raise exception 'Product ID is required'
      using errcode = '22023';
  end if;

  if not exists (
    select 1
    from public.products as products
    where products.product_id = v_id
  ) then
    raise exception 'Product not found: %', v_id
      using errcode = 'P0002';
  end if;

  begin
    delete from public.products as products
    where products.product_id = v_id;

    return jsonb_build_object(
      'action', 'DELETED',
      'product_id', v_id
    );

  exception
    when foreign_key_violation then
      update public.products as products
      set
        active = false,
        updated_by = auth.uid(),
        updated_at = now()
      where products.product_id = v_id;

      return jsonb_build_object(
        'action', 'DEACTIVATED',
        'product_id', v_id
      );
  end;
end;
$$;


-- =========================================================
-- 3. ADVANCE GUARD:
--    keep normal repayment updates;
--    allow deletion only inside approved historical RPC
-- =========================================================

create or replace function public.guard_advance_lot_mutation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE'
    and current_setting('app.finance_post', true) = 'on' then
    return new;
  end if;

  if tg_op = 'DELETE'
    and current_setting(
      'app.historical_advance_delete',
      true
    ) = 'on'
    and old.opening_balance_entry_id is not null
    and old.transaction_id is null then
    return old;
  end if;

  raise exception
    'Advance lots can only change through an approved finance workflow'
    using errcode = '42501';
end;
$$;


-- =========================================================
-- 4. DELETE UNTOUCHED HISTORICAL ADVANCE
-- =========================================================

create or replace function public.delete_untouched_historical_advance(
  p_advance_lot_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_reason text := trim(coalesce(p_reason, ''));

  v_lot public.advance_lots%rowtype;
  v_entry public.opening_balance_entries%rowtype;
  v_import public.opening_balance_imports%rowtype;

  v_row_count integer;
  v_total_quantity numeric(20, 3);
  v_total_weight bigint;
  v_total_principal bigint;
begin
  perform public.require_staff_roles(array['owner']);

  if p_advance_lot_id is null then
    raise exception 'Advance lot ID is required'
      using errcode = '22023';
  end if;

  if length(v_reason) not between 1 and 500 then
    raise exception
      'Delete reason must contain 1 to 500 characters'
      using errcode = '22023';
  end if;

  select lots.*
  into v_lot
  from public.advance_lots as lots
  where lots.id = p_advance_lot_id
  for update;

  if not found then
    raise exception 'Advance lot not found'
      using errcode = 'P0002';
  end if;

  if v_lot.opening_balance_entry_id is null
    or v_lot.transaction_id is not null then
    raise exception
      'Only a historical opening advance can be deleted'
      using errcode = '22023';
  end if;

  if v_lot.status <> 'OPEN'
    or v_lot.remaining_principal_kyat
      <> v_lot.original_principal_kyat
    or (
      v_lot.advance_type = 'GOODS'
      and v_lot.remaining_quantity
        is distinct from v_lot.original_quantity
    ) then
    raise exception
      'This advance has already changed; use a correction workflow instead'
      using errcode = '55000';
  end if;

  if exists (
    select 1
    from public.advance_repayments as repayments
    where repayments.advance_lot_id = v_lot.id
  ) then
    raise exception
      'This advance already has a repayment and cannot be deleted'
      using errcode = '55000';
  end if;

  if exists (
    select 1
    from public.crop_settlements as settlements
    where settlements.debt_advance_lot_id = v_lot.id
  ) then
    raise exception
      'This advance is already used by a crop settlement'
      using errcode = '55000';
  end if;

  if exists (
    select 1
    from public.consignment_settlements as settlements
    where settlements.debt_advance_lot_id = v_lot.id
  ) then
    raise exception
      'This advance is already used by a consignment settlement'
      using errcode = '55000';
  end if;

  select entries.*
  into strict v_entry
  from public.opening_balance_entries as entries
  where entries.id = v_lot.opening_balance_entry_id
  for update;

  if v_entry.entry_type
    not in ('FARMER_DEBT', 'FARMER_ADVANCE') then
    raise exception
      'Opening row is not a farmer debt or advance'
      using errcode = '22023';
  end if;

  select imports.*
  into strict v_import
  from public.opening_balance_imports as imports
  where imports.id = v_entry.import_id
  for update;

  perform set_config(
    'app.historical_advance_delete',
    'on',
    true
  );

  perform set_config(
    'app.opening_balance_commit',
    'on',
    true
  );

  delete from public.advance_lots as lots
  where lots.id = v_lot.id;

  delete from public.opening_balance_entries as entries
  where entries.id = v_entry.id;

  select
    count(*)::integer,
    coalesce(
      sum(coalesce(entries.quantity, 0)),
      0
    )::numeric(20, 3),
    coalesce(
      sum(coalesce(entries.weight_centi_pyitha, 0)),
      0
    )::bigint,
    coalesce(
      sum(coalesce(entries.principal_kyat, 0)),
      0
    )::bigint
  into
    v_row_count,
    v_total_quantity,
    v_total_weight,
    v_total_principal
  from public.opening_balance_entries as entries
  where entries.import_id = v_import.id;

  if v_row_count = 0 then
    delete from public.opening_balance_imports as imports
    where imports.id = v_import.id;
  else
    update public.opening_balance_imports as imports
    set
      row_count = v_row_count,
      total_quantity = v_total_quantity,
      total_weight_centi_pyitha = v_total_weight,
      total_principal_kyat = v_total_principal
    where imports.id = v_import.id;
  end if;

  update public.farmers as farmers
  set
    opening_debt_kyat = coalesce((
      select sum(entries.principal_kyat)::bigint
      from public.opening_balance_entries as entries
      where entries.customer_id = farmers.customer_id
        and entries.entry_type
          in ('FARMER_DEBT', 'FARMER_ADVANCE')
    ), 0),
    updated_by = auth.uid(),
    updated_at = now()
  where farmers.customer_id = v_lot.customer_id;

  insert into public.finance_audit_events (
    transaction_id,
    document_ref,
    action,
    payload,
    created_by
  )
  values (
    null,
    v_lot.advance_ref,
    'DELETE_UNTOUCHED_HISTORICAL_ADVANCE',
    jsonb_build_object(
      'reason', v_reason,
      'deleted_advance_lot', to_jsonb(v_lot),
      'deleted_opening_entry', to_jsonb(v_entry),
      'opening_import_ref', v_import.import_ref
    ),
    auth.uid()
  );

  return jsonb_build_object(
    'action', 'DELETED',
    'advance_lot_id', v_lot.id,
    'advance_ref', v_lot.advance_ref,
    'customer_id', v_lot.customer_id
  );
end;
$$;


-- =========================================================
-- 5. PERMISSIONS
-- =========================================================

revoke all on function
  public.remove_or_deactivate_farmer(text)
from public;

revoke all on function
  public.remove_or_deactivate_product(text)
from public;

revoke all on function
  public.delete_untouched_historical_advance(uuid, text)
from public;

grant execute on function
  public.remove_or_deactivate_farmer(text)
to authenticated, service_role;

grant execute on function
  public.remove_or_deactivate_product(text)
to authenticated, service_role;

grant execute on function
  public.delete_untouched_historical_advance(uuid, text)
to authenticated, service_role;

commit;

notify pgrst, 'reload schema';
