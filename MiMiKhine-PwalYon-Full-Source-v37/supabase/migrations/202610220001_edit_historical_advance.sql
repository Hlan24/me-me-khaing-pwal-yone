begin;

create or replace function public.update_historical_advance(
  p_advance_lot_id uuid,
  p_customer_id text,
  p_opening_date date,
  p_advance_type text,
  p_principal_kyat bigint,
  p_monthly_interest_rate numeric,
  p_product_id text,
  p_location_id text,
  p_quantity numeric,
  p_unit_price_kyat bigint,
  p_notes text
)
returns table (
  advance_lot_id uuid,
  document_ref text,
  customer_id text,
  advance_type text,
  original_principal_kyat bigint,
  opening_date date,
  monthly_interest_rate numeric,
  saved_notes text
)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_lot public.advance_lots%rowtype;
  v_entry public.opening_balance_entries%rowtype;
  v_product public.products%rowtype;

  v_customer_id text := trim(coalesce(p_customer_id, ''));
  v_type text := upper(trim(coalesce(p_advance_type, '')));
  v_note text := nullif(trim(coalesce(p_notes, '')), '');

  v_farmer_name text;
  v_principal bigint;
  v_quantity numeric(20, 3);
  v_unit_price bigint;
  v_rate numeric(7, 4);

  v_before jsonb;
  v_after jsonb;
begin
  -- Full Edit ကို Owner တစ်ယောက်တည်းသာ လုပ်နိုင်သည်။
  perform public.require_staff_roles(array['owner']::text[]);

  if p_advance_lot_id is null then
    raise exception 'Advance lot ID is required'
      using errcode = '22023';
  end if;

  if v_customer_id = '' then
    raise exception 'Farmer is required'
      using errcode = '22023';
  end if;

  if p_opening_date is null then
    raise exception 'Original issue date is required'
      using errcode = '22023';
  end if;

  if p_opening_date > public.get_business_date() then
    raise exception 'Original issue date cannot be after the server business date'
      using errcode = '22023';
  end if;

  if v_type not in ('CASH', 'GOODS') then
    raise exception 'Advance type must be CASH or GOODS'
      using errcode = '22023';
  end if;

  if p_monthly_interest_rate is null
    or p_monthly_interest_rate < 0
    or p_monthly_interest_rate > 100 then
    raise exception 'Monthly interest rate must be between 0 and 100'
      using errcode = '22023';
  end if;

  if p_monthly_interest_rate <> round(p_monthly_interest_rate, 4) then
    raise exception 'Monthly interest rate can contain up to four decimal places'
      using errcode = '22023';
  end if;

  v_rate := p_monthly_interest_rate::numeric(7, 4);

  if v_note is not null and length(v_note) > 500 then
    raise exception 'Notes cannot exceed 500 characters'
      using errcode = '22023';
  end if;

  -- Lot ကို lock လုပ်ပြီး တခြား Save/Repayment နဲ့ မတိုက်အောင်လုပ်သည်။
  select lots.*
    into v_lot
  from public.advance_lots as lots
  where lots.id = p_advance_lot_id
  for update;

  if not found then
    raise exception 'Advance lot was not found'
      using errcode = 'P0002';
  end if;

  -- ယနေ့ပုံမှန်စိုက်ထုတ်မဟုတ်ဘဲ Opening/Historical စာရင်းသာ ပြင်ခွင့်ပြုသည်။
  if v_lot.opening_balance_entry_id is null
    or v_lot.transaction_id is not null then
    raise exception 'Only historical opening advances can be edited'
      using errcode = '42501';
  end if;

  if v_lot.status <> 'OPEN' then
    raise exception 'Only an OPEN historical advance can be edited'
      using errcode = '55000';
  end if;

  if v_lot.remaining_principal_kyat <> v_lot.original_principal_kyat then
    raise exception 'Partially paid historical advance cannot be edited'
      using errcode = '55000';
  end if;

  if exists (
    select 1
    from public.advance_repayments as repayments
    where repayments.advance_lot_id = v_lot.id
  ) then
    raise exception 'Advance already has a repayment and cannot be edited'
      using errcode = '55000';
  end if;

  select entries.*
    into v_entry
  from public.opening_balance_entries as entries
  where entries.id = v_lot.opening_balance_entry_id
  for update;

  if not found then
    raise exception 'Historical opening entry was not found'
      using errcode = 'P0002';
  end if;

  if v_entry.entry_type not in ('FARMER_ADVANCE', 'FARMER_DEBT') then
    raise exception 'Opening entry is not a farmer advance'
      using errcode = '42501';
  end if;

  select farmers.full_name
    into v_farmer_name
  from public.farmers as farmers
  where farmers.customer_id = v_customer_id
    and farmers.active = true;

  if not found then
    raise exception 'Active farmer was not found: %', v_customer_id
      using errcode = '23503';
  end if;

  if v_type = 'CASH' then
    if p_principal_kyat is null or p_principal_kyat <= 0 then
      raise exception 'Cash principal must be greater than zero'
        using errcode = '22023';
    end if;

    v_principal := p_principal_kyat;
    v_quantity := null;
    v_unit_price := 1;
  else
    if nullif(trim(coalesce(p_product_id, '')), '') is null then
      raise exception 'Product is required for a goods advance'
        using errcode = '22023';
    end if;

    if nullif(trim(coalesce(p_location_id, '')), '') is null then
      raise exception 'Stock location is required for a goods advance'
        using errcode = '22023';
    end if;

    select products.*
      into v_product
    from public.products as products
    where products.product_id = trim(p_product_id)
      and products.active = true;

    if not found then
      raise exception 'Active product was not found: %', p_product_id
        using errcode = '23503';
    end if;

    if not exists (
      select 1
      from public.stock_locations as locations
      where locations.location_id = trim(p_location_id)
        and locations.active = true
    ) then
      raise exception 'Active stock location was not found: %', p_location_id
        using errcode = '23503';
    end if;

    if p_quantity is null or p_quantity <= 0 then
      raise exception 'Goods quantity must be greater than zero'
        using errcode = '22023';
    end if;

    if p_quantity <> trunc(p_quantity, 3) then
      raise exception 'Goods quantity can contain up to three decimal places'
        using errcode = '22023';
    end if;

    if v_product.whole_units_only
      and p_quantity <> trunc(p_quantity) then
      raise exception 'This product requires a whole-unit quantity'
        using errcode = '22023';
    end if;

    if p_unit_price_kyat is null or p_unit_price_kyat <= 0 then
      raise exception 'Unit price must be greater than zero'
        using errcode = '22023';
    end if;

    if p_quantity * p_unit_price_kyat > 9223372036854775807 then
      raise exception 'Calculated principal is too large'
        using errcode = '22003';
    end if;

    v_quantity := p_quantity::numeric(20, 3);
    v_unit_price := p_unit_price_kyat;
    v_principal := round(v_quantity * v_unit_price)::bigint;

    if v_principal <= 0 then
      raise exception 'Calculated principal must be greater than zero'
        using errcode = '22023';
    end if;
  end if;

  v_before := jsonb_build_object(
    'customer_id', v_lot.customer_id,
    'farmer_name', v_lot.farmer_name_snapshot,
    'issued_date', v_lot.issued_date,
    'advance_type', v_lot.advance_type,
    'product_id', v_lot.product_id,
    'location_id', v_lot.location_id,
    'quantity', v_lot.original_quantity,
    'unit_price_kyat', v_lot.unit_price_kyat,
    'principal_kyat', v_lot.original_principal_kyat,
    'monthly_interest_rate', v_lot.monthly_interest_rate,
    'notes', v_lot.notes
  );

  -- Opening records နှင့် Advance lot ကို Server transaction တစ်ခုအတွင်း ပြင်သည်။
  perform set_config('app.opening_balance_commit', 'on', true);
  perform set_config('app.finance_post', 'on', true);

  update public.opening_balance_entries as entries
  set
    entry_type = 'FARMER_ADVANCE',
    customer_id = v_customer_id,
    product_id =
      case when v_type = 'GOODS' then trim(p_product_id) else null end,
    location_id =
      case when v_type = 'GOODS' then trim(p_location_id) else null end,
    quantity =
      case when v_type = 'GOODS' then v_quantity else null end,
    principal_kyat = v_principal,
    monthly_interest_rate = v_rate,
    opening_date = p_opening_date,
    advance_type = v_type,
    unit_price_kyat = v_unit_price,
    notes = v_note
  where entries.id = v_entry.id;

  update public.advance_lots as lots
  set
    customer_id = v_customer_id,
    farmer_name_snapshot = v_farmer_name,
    advance_type = v_type,

    product_id =
      case when v_type = 'GOODS' then trim(p_product_id) else null end,

    location_id =
      case when v_type = 'GOODS' then trim(p_location_id) else null end,

    product_name_snapshot =
      case when v_type = 'GOODS' then v_product.name else null end,

    unit_name_snapshot =
      case when v_type = 'GOODS' then v_product.unit_name else 'ကျပ်' end,

    whole_units_only =
      case when v_type = 'GOODS' then v_product.whole_units_only else true end,

    unit_price_kyat = v_unit_price,

    original_quantity =
      case when v_type = 'GOODS' then v_quantity else null end,

    remaining_quantity =
      case when v_type = 'GOODS' then v_quantity else null end,

    original_principal_kyat = v_principal,
    remaining_principal_kyat = v_principal,
    monthly_interest_rate = v_rate,
    issued_date = p_opening_date,
    status = 'OPEN',
    notes = v_note,
    updated_at = now()
  where lots.id = v_lot.id;

  -- ပြင်ထားသော Import ရဲ့ စုစုပေါင်းတန်ဖိုးများ ပြန်တွက်သည်။
  update public.opening_balance_imports as imports
  set
    row_count = (
      select count(*)::integer
      from public.opening_balance_entries as entries
      where entries.import_id = v_entry.import_id
    ),
    total_quantity = (
      select coalesce(sum(entries.quantity), 0)
      from public.opening_balance_entries as entries
      where entries.import_id = v_entry.import_id
    ),
    total_principal_kyat = (
      select coalesce(sum(entries.principal_kyat), 0)::bigint
      from public.opening_balance_entries as entries
      where entries.import_id = v_entry.import_id
    )
  where imports.id = v_entry.import_id;

  -- တောင်သူပြောင်းထားနိုင်သောကြောင့် တောင်သူအဟောင်းနှင့်အသစ် နှစ်ယောက်လုံး
  -- Opening Debt ကို ပြန်တွက်သည်။
  update public.farmers as farmers
  set opening_debt_kyat = coalesce((
    select sum(entries.principal_kyat)::bigint
    from public.opening_balance_entries as entries
    where entries.customer_id = farmers.customer_id
      and entries.entry_type in ('FARMER_DEBT', 'FARMER_ADVANCE')
  ), 0)
  where farmers.customer_id in (v_lot.customer_id, v_customer_id);

  v_after := jsonb_build_object(
    'customer_id', v_customer_id,
    'farmer_name', v_farmer_name,
    'issued_date', p_opening_date,
    'advance_type', v_type,
    'product_id',
      case when v_type = 'GOODS' then trim(p_product_id) else null end,
    'location_id',
      case when v_type = 'GOODS' then trim(p_location_id) else null end,
    'quantity',
      case when v_type = 'GOODS' then v_quantity else null end,
    'unit_price_kyat', v_unit_price,
    'principal_kyat', v_principal,
    'monthly_interest_rate', v_rate,
    'notes', v_note
  );

  insert into public.finance_audit_events (
    transaction_id,
    document_ref,
    action,
    payload,
    created_by
  ) values (
    null,
    v_lot.advance_ref,
    'HISTORICAL_ADVANCE_UPDATED',
    jsonb_build_object(
      'before', v_before,
      'after', v_after,
      'opening_balance_entry_id', v_entry.id
    ),
    auth.uid()
  );

  return query
  select
    lots.id,
    lots.advance_ref,
    lots.customer_id,
    lots.advance_type,
    lots.original_principal_kyat,
    lots.issued_date,
    lots.monthly_interest_rate,
    lots.notes
  from public.advance_lots as lots
  where lots.id = v_lot.id;
end;
$$;

revoke all on function public.update_historical_advance(
  uuid, text, date, text, bigint, numeric,
  text, text, numeric, bigint, text
) from public;

grant execute on function public.update_historical_advance(
  uuid, text, date, text, bigint, numeric,
  text, text, numeric, bigint, text
) to authenticated;

grant execute on function public.update_historical_advance(
  uuid, text, date, text, bigint, numeric,
  text, text, numeric, bigint, text
) to service_role;

commit;

notify pgrst, 'reload schema';
