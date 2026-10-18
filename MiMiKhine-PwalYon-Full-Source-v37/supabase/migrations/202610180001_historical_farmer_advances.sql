-- Historical farmer advances (cash and goods)
--
-- Operational advances must continue to use issue_advance(), which always posts
-- on the server business date and creates the matching cash/stock movement.
-- This migration adds a separate, immutable opening-data path for old records.
-- Historical rows create repayable advance lots, but deliberately do not post a
-- cash-ledger entry or a product-stock movement on today's business date.

alter table public.opening_balance_imports
  drop constraint if exists opening_balance_import_type_valid;
alter table public.opening_balance_imports
  add constraint opening_balance_import_type_valid check (
    import_type in (
      'FARMER_DEBT', 'FARMER_ADVANCE', 'PRODUCT_STOCK', 'CROP_STOCK'
    )
  );

alter table public.opening_balance_entries
  add column if not exists advance_type text,
  add column if not exists unit_price_kyat bigint;

alter table public.opening_balance_entries
  drop constraint if exists opening_balance_entry_type_valid;
alter table public.opening_balance_entries
  add constraint opening_balance_entry_type_valid check (
    entry_type in (
      'FARMER_DEBT', 'FARMER_ADVANCE', 'PRODUCT_STOCK', 'CROP_STOCK'
    )
  );

alter table public.opening_balance_entries
  drop constraint if exists opening_balance_entry_shape;
alter table public.opening_balance_entries
  add constraint opening_balance_entry_shape check (
    (
      entry_type = 'FARMER_DEBT'
      and customer_id is not null
      and crop_type_id is null
      and product_id is null
      and location_id is null
      and quantity is null
      and weight_centi_pyitha is null
      and principal_kyat is not null
      and principal_kyat > 0
      and monthly_interest_rate is not null
      and monthly_interest_rate between 0 and 100
      and opening_date is not null
      and advance_type is null
      and unit_price_kyat is null
    )
    or
    (
      entry_type = 'FARMER_ADVANCE'
      and customer_id is not null
      and crop_type_id is null
      and weight_centi_pyitha is null
      and principal_kyat is not null
      and principal_kyat > 0
      and monthly_interest_rate is not null
      and monthly_interest_rate between 0 and 100
      and opening_date is not null
      and advance_type is not null
      and (
        (
          advance_type = 'CASH'
          and product_id is null
          and location_id is null
          and quantity is null
          and unit_price_kyat is not null
          and unit_price_kyat = 1
        )
        or
        (
          advance_type = 'GOODS'
          and product_id is not null
          and location_id is not null
          and quantity is not null
          and quantity > 0
          and unit_price_kyat is not null
          and unit_price_kyat > 0
          and principal_kyat = round(quantity * unit_price_kyat)::bigint
        )
      )
    )
    or
    (
      entry_type = 'PRODUCT_STOCK'
      and customer_id is null
      and crop_type_id is null
      and product_id is not null
      and location_id is not null
      and quantity is not null
      and quantity > 0
      and weight_centi_pyitha is null
      and principal_kyat is null
      and monthly_interest_rate is null
      and opening_date is null
      and advance_type is null
      and unit_price_kyat is null
    )
    or
    (
      entry_type = 'CROP_STOCK'
      and customer_id is null
      and crop_type_id is not null
      and product_id is null
      and location_id is not null
      and quantity is null
      and weight_centi_pyitha is not null
      and weight_centi_pyitha > 0
      and principal_kyat is null
      and monthly_interest_rate is null
      and opening_date is null
      and advance_type is null
      and unit_price_kyat is null
    )
  );

create index if not exists opening_balance_entries_historical_advance_idx
  on public.opening_balance_entries (customer_id, opening_date, id)
  where entry_type = 'FARMER_ADVANCE';

create or replace function public.create_opening_advance_lot()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_farmer_name text;
  v_created_by uuid;
  v_import_ref text;
  v_product public.products%rowtype;
  v_type text;
begin
  if new.entry_type not in ('FARMER_DEBT', 'FARMER_ADVANCE') then
    return new;
  end if;

  select farmers.full_name into strict v_farmer_name
  from public.farmers as farmers
  where farmers.customer_id = new.customer_id;

  select imports.created_by, imports.import_ref
    into strict v_created_by, v_import_ref
  from public.opening_balance_imports as imports
  where imports.id = new.import_id;

  v_type := case
    when new.entry_type = 'FARMER_DEBT' then 'CASH'
    else new.advance_type
  end;

  if v_type = 'GOODS' then
    select products.* into strict v_product
    from public.products as products
    where products.product_id = new.product_id;
  end if;

  insert into public.advance_lots (
    opening_balance_entry_id, advance_ref, customer_id,
    farmer_name_snapshot, advance_type, product_id, location_id,
    product_name_snapshot, unit_name_snapshot, whole_units_only,
    unit_price_kyat, original_quantity, remaining_quantity,
    original_principal_kyat, remaining_principal_kyat,
    monthly_interest_rate, issued_date, status, notes, created_by
  ) values (
    new.id,
    'AD-OB-' || lpad(new.id::text, 8, '0'),
    new.customer_id,
    v_farmer_name,
    v_type,
    case when v_type = 'GOODS' then new.product_id else null end,
    case when v_type = 'GOODS' then new.location_id else null end,
    case when v_type = 'GOODS' then v_product.name else null end,
    case when v_type = 'GOODS' then v_product.unit_name else 'ကျပ်' end,
    case when v_type = 'GOODS' then v_product.whole_units_only else true end,
    case when v_type = 'GOODS' then new.unit_price_kyat else 1 end,
    case when v_type = 'GOODS' then new.quantity else null end,
    case when v_type = 'GOODS' then new.quantity else null end,
    new.principal_kyat,
    new.principal_kyat,
    new.monthly_interest_rate,
    new.opening_date,
    'OPEN',
    concat_ws(
      ' · ',
      case when new.entry_type = 'FARMER_ADVANCE'
        then 'Historical Advance' else 'Opening Balance' end,
      v_import_ref,
      new.notes
    ),
    v_created_by
  ) on conflict (opening_balance_entry_id) do nothing;

  return new;
end;
$$;

create or replace function public.commit_historical_advance_import(
  p_request_id uuid,
  p_source_name text,
  p_rows jsonb,
  p_notes text default null
)
returns table (
  import_id uuid,
  import_ref text,
  business_date date,
  import_type text,
  row_count integer,
  total_quantity numeric,
  total_weight_centi_pyitha bigint,
  total_principal_kyat bigint,
  idempotent boolean
)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_existing public.opening_balance_imports%rowtype;
  v_import public.opening_balance_imports%rowtype;
  v_source text := trim(coalesce(p_source_name, ''));
  v_row jsonb;
  v_line bigint;
  v_customer_id text;
  v_type text;
  v_product_id text;
  v_location_id text;
  v_notes text;
  v_quantity numeric(20, 3);
  v_unit_price bigint;
  v_principal bigint;
  v_rate numeric(7, 4);
  v_opening_date date;
  v_product public.products%rowtype;
  v_count integer := 0;
  v_total_quantity numeric(20, 3) := 0;
  v_total_principal bigint := 0;
begin
  perform public.require_staff_roles(array['owner', 'admin', 'accountant']);
  perform set_config('app.opening_balance_commit', 'on', true);

  if p_request_id is null then
    raise exception 'Historical-advance request ID is required'
      using errcode = '22023';
  end if;

  select imports.* into v_existing
  from public.opening_balance_imports as imports
  where imports.request_id = p_request_id;

  if found then
    if v_existing.import_type <> 'FARMER_ADVANCE' then
      raise exception 'Request ID already belongs to another import type'
        using errcode = '22023';
    end if;
    return query select
      v_existing.id,
      v_existing.import_ref,
      v_existing.business_date,
      v_existing.import_type,
      v_existing.row_count,
      v_existing.total_quantity,
      v_existing.total_weight_centi_pyitha,
      v_existing.total_principal_kyat,
      true;
    return;
  end if;

  if length(v_source) not between 1 and 200 then
    raise exception 'Source name must contain 1 to 200 characters'
      using errcode = '22023';
  end if;
  if p_notes is not null and length(p_notes) > 500 then
    raise exception 'Import notes cannot exceed 500 characters'
      using errcode = '22023';
  end if;
  if jsonb_typeof(p_rows) <> 'array'
    or jsonb_array_length(p_rows) < 1
    or jsonb_array_length(p_rows) > 1000 then
    raise exception 'Historical-advance import requires 1 to 1000 rows'
      using errcode = '22023';
  end if;

  insert into public.opening_balance_imports (
    import_ref, request_id, business_date, import_type,
    source_name, notes, created_by
  ) values (
    'OB-' || to_char(public.get_business_date(), 'YYYYMMDD') || '-'
      || lpad(nextval('public.opening_balance_ref_seq')::text, 6, '0'),
    p_request_id,
    public.get_business_date(),
    'FARMER_ADVANCE',
    v_source,
    nullif(trim(coalesce(p_notes, '')), ''),
    auth.uid()
  ) returning * into v_import;

  for v_row, v_line in
    select item.value, item.ordinality
    from jsonb_array_elements(p_rows) with ordinality as item(value, ordinality)
  loop
    if jsonb_typeof(v_row) <> 'object' then
      raise exception 'Line % must be an object', v_line
        using errcode = '22023';
    end if;

    v_customer_id := trim(coalesce(v_row ->> 'customer_id', ''));
    v_type := upper(trim(coalesce(v_row ->> 'advance_type', '')));
    v_product_id := nullif(trim(coalesce(v_row ->> 'product_id', '')), '');
    v_location_id := nullif(trim(coalesce(v_row ->> 'location_id', '')), '');
    v_notes := nullif(trim(coalesce(v_row ->> 'notes', '')), '');
    v_quantity := null;
    v_unit_price := null;
    v_principal := null;

    if not exists (
      select 1 from public.farmers as farmers
      where farmers.customer_id = v_customer_id
    ) then
      raise exception 'Line % farmer not found: %', v_line, v_customer_id
        using errcode = '23503';
    end if;
    if v_type not in ('CASH', 'GOODS') then
      raise exception 'Line % advance_type must be CASH or GOODS', v_line
        using errcode = '22023';
    end if;
    if v_notes is not null and length(v_notes) > 500 then
      raise exception 'Line % notes cannot exceed 500 characters', v_line
        using errcode = '22023';
    end if;

    if coalesce(v_row ->> 'monthly_rate', '')
      !~ '^[0-9]+([.][0-9]{1,4})?$' then
      raise exception 'Line % monthly_rate must contain up to four decimals', v_line
        using errcode = '22023';
    end if;
    v_rate := (v_row ->> 'monthly_rate')::numeric(7, 4);
    if v_rate < 0 or v_rate > 100 then
      raise exception 'Line % monthly_rate must be from 0 to 100', v_line
        using errcode = '22023';
    end if;

    if coalesce(v_row ->> 'opening_date', '')
      !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
      raise exception 'Line % opening_date must use YYYY-MM-DD', v_line
        using errcode = '22023';
    end if;
    begin
      v_opening_date := (v_row ->> 'opening_date')::date;
    exception when others then
      raise exception 'Line % opening_date is not a valid date', v_line
        using errcode = '22023';
    end;
    if v_opening_date > public.get_business_date() then
      raise exception 'Line % opening_date cannot be after the server business date', v_line
        using errcode = '22023';
    end if;

    if v_type = 'CASH' then
      if v_product_id is not null or v_location_id is not null
        or nullif(trim(coalesce(v_row ->> 'quantity', '')), '') is not null
        or nullif(trim(coalesce(v_row ->> 'unit_price_kyat', '')), '') is not null then
        raise exception 'Line % CASH row cannot contain product, location, quantity or unit price', v_line
          using errcode = '22023';
      end if;
      if coalesce(v_row ->> 'principal_kyat', '') !~ '^[0-9]+$'
        or (v_row ->> 'principal_kyat')::numeric > 9223372036854775807 then
        raise exception 'Line % principal_kyat must be a positive whole kyat amount', v_line
          using errcode = '22023';
      end if;
      v_principal := (v_row ->> 'principal_kyat')::bigint;
      if v_principal <= 0 then
        raise exception 'Line % principal_kyat must be greater than zero', v_line
          using errcode = '22023';
      end if;
      v_unit_price := 1;
    else
      if nullif(trim(coalesce(v_row ->> 'principal_kyat', '')), '') is not null then
        raise exception 'Line % GOODS principal is calculated from quantity and unit price', v_line
          using errcode = '22023';
      end if;
      select products.* into v_product
      from public.products as products
      where products.product_id = v_product_id and products.active = true;
      if not found then
        raise exception 'Line % active product not found: %', v_line, v_product_id
          using errcode = '23503';
      end if;
      if not exists (
        select 1 from public.stock_locations as locations
        where locations.location_id = v_location_id and locations.active = true
      ) then
        raise exception 'Line % active stock location not found: %', v_line, v_location_id
          using errcode = '23503';
      end if;
      if coalesce(v_row ->> 'quantity', '')
        !~ '^[0-9]+([.][0-9]{1,3})?$' then
        raise exception 'Line % quantity must contain up to three decimals', v_line
          using errcode = '22023';
      end if;
      v_quantity := (v_row ->> 'quantity')::numeric(20, 3);
      if v_quantity <= 0 then
        raise exception 'Line % quantity must be greater than zero', v_line
          using errcode = '22023';
      end if;
      if v_product.whole_units_only and v_quantity <> trunc(v_quantity) then
        raise exception 'Line % product requires a whole-unit quantity', v_line
          using errcode = '22023';
      end if;
      if coalesce(v_row ->> 'unit_price_kyat', '') !~ '^[0-9]+$'
        or (v_row ->> 'unit_price_kyat')::numeric > 9223372036854775807 then
        raise exception 'Line % unit_price_kyat must be a positive whole kyat amount', v_line
          using errcode = '22023';
      end if;
      v_unit_price := (v_row ->> 'unit_price_kyat')::bigint;
      if v_unit_price <= 0 then
        raise exception 'Line % unit_price_kyat must be greater than zero', v_line
          using errcode = '22023';
      end if;
      if v_quantity * v_unit_price > 9223372036854775807 then
        raise exception 'Line % calculated principal is too large', v_line
          using errcode = '22003';
      end if;
      v_principal := round(v_quantity * v_unit_price)::bigint;
      if v_principal <= 0 then
        raise exception 'Line % calculated principal must be at least one kyat', v_line
          using errcode = '22023';
      end if;
    end if;

    insert into public.opening_balance_entries (
      import_id, line_no, entry_type, customer_id,
      product_id, location_id, quantity, principal_kyat,
      monthly_interest_rate, opening_date, advance_type,
      unit_price_kyat, notes
    ) values (
      v_import.id, v_line, 'FARMER_ADVANCE', v_customer_id,
      case when v_type = 'GOODS' then v_product_id else null end,
      case when v_type = 'GOODS' then v_location_id else null end,
      case when v_type = 'GOODS' then v_quantity else null end,
      v_principal, v_rate, v_opening_date, v_type, v_unit_price, v_notes
    );

    v_count := v_count + 1;
    v_total_principal := v_total_principal + v_principal;
    if v_type = 'GOODS' then
      v_total_quantity := v_total_quantity + v_quantity;
    end if;
  end loop;

  update public.opening_balance_imports as imports set
    row_count = v_count,
    total_quantity = v_total_quantity,
    total_principal_kyat = v_total_principal
  where imports.id = v_import.id;

  update public.farmers as farmers set
    opening_debt_kyat = coalesce((
      select sum(entries.principal_kyat)::bigint
      from public.opening_balance_entries as entries
      where entries.entry_type in ('FARMER_DEBT', 'FARMER_ADVANCE')
        and entries.customer_id = farmers.customer_id
    ), 0)
  where farmers.customer_id in (
    select distinct entries.customer_id
    from public.opening_balance_entries as entries
    where entries.import_id = v_import.id
  );

  return query select
    v_import.id,
    v_import.import_ref,
    v_import.business_date,
    'FARMER_ADVANCE'::text,
    v_count,
    v_total_quantity,
    0::bigint,
    v_total_principal,
    false;
end;
$$;

revoke all on function public.commit_historical_advance_import(
  uuid, text, jsonb, text
) from public;
grant execute on function public.commit_historical_advance_import(
  uuid, text, jsonb, text
) to authenticated;
grant execute on function public.commit_historical_advance_import(
  uuid, text, jsonb, text
) to service_role;

comment on function public.commit_historical_advance_import(
  uuid, text, jsonb, text
) is 'Imports immutable historical CASH/GOODS farmer advances without posting current cash or stock movements.';
