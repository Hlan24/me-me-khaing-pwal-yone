-- Farmer consignment (အပ်ပဲ) later sale/settlement.
--
-- A consignment lot remains farmer-owned while it is held in custody.  This
-- workflow transfers only the selected quantity to pwal-yon-owned crop stock,
-- pays the farmer after costs/debt offsets, and leaves any unselected balance
-- open for a later settlement.  All custody, stock, debt and cash effects are
-- posted atomically under one idempotent request ID.

begin;

-- ---------------------------------------------------------------------------
-- Common finance envelope: use the existing CS sequence, but keep the
-- transaction type distinct from an intake-time crop settlement for audit.
-- ---------------------------------------------------------------------------

alter table public.finance_transactions
  drop constraint if exists finance_transaction_type_valid;
alter table public.finance_transactions
  add constraint finance_transaction_type_valid check (
    document_type in (
      'ADVANCE', 'ADVANCE_REPAYMENT', 'PRODUCT_SALE', 'STOCK_RECEIPT',
      'EXPENSE', 'CROP_SETTLEMENT', 'CONSIGNMENT_SETTLEMENT',
      'CROP_SALE', 'DAY_CLOSE'
    )
  );

-- ---------------------------------------------------------------------------
-- Immutable settlement snapshot.  Multiple rows may reference one custody
-- lot so partial settlement is a first-class operation.
-- ---------------------------------------------------------------------------

create table if not exists public.consignment_settlements (
  id uuid primary key default gen_random_uuid(),
  transaction_id uuid not null unique
    references public.finance_transactions(id)
      on update restrict on delete restrict,
  settlement_ref text not null unique,
  consignment_lot_id uuid not null
    references public.consignment_lots(id)
      on update restrict on delete restrict,
  business_date date not null,
  customer_id text not null
    references public.farmers(customer_id)
      on update restrict on delete restrict,
  farmer_name_snapshot text not null,
  crop_type_id text not null
    references public.crop_types(crop_type_id)
      on update restrict on delete restrict,
  crop_name_snapshot text not null,
  location_id text not null
    references public.stock_locations(location_id)
      on update restrict on delete restrict,

  original_lot_centi_pyitha bigint not null,
  lot_before_centi_pyitha bigint not null,
  settled_centi_pyitha bigint not null,
  lot_after_centi_pyitha bigint not null,

  pricing_divisor_pyitha integer not null,
  market_price_kyat bigint not null,
  gross_value_kyat bigint not null,
  labour_rate_kyat bigint not null,
  labour_total_kyat bigint not null,
  commission_rate numeric(7,4) not null,
  commission_total_kyat bigint not null,
  freight_kyat bigint not null,
  total_expense_kyat bigint not null,
  value_after_expense_kyat bigint not null,

  debt_advance_lot_id uuid
    references public.advance_lots(id)
      on update restrict on delete restrict,
  debt_selected_quantity numeric(20,3),
  debt_principal_kyat bigint not null default 0,
  debt_interest_kyat bigint not null default 0,
  debt_total_kyat bigint not null default 0,
  debt_elapsed_days integer not null default 0,
  debt_half_month_steps integer not null default 0,
  debt_remaining_principal_kyat bigint,
  debt_remaining_quantity numeric(20,3),

  payable_kyat bigint not null,
  payment_method text not null,
  payment_reference text,
  notes text,

  stock_before_centi_pyitha bigint not null,
  stock_after_centi_pyitha bigint not null,
  status text not null default 'POSTED',
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),

  constraint consignment_settlement_ref_valid check (
    settlement_ref ~ '^CS-[0-9]{8}-[0-9]{6,}$'
  ),
  constraint consignment_settlement_snapshot_present check (
    length(trim(farmer_name_snapshot)) between 1 and 160
    and length(trim(crop_name_snapshot)) between 1 and 120
  ),
  constraint consignment_settlement_lot_quantity_valid check (
    original_lot_centi_pyitha > 0
    and lot_before_centi_pyitha > 0
    and lot_before_centi_pyitha <= original_lot_centi_pyitha
    and settled_centi_pyitha > 0
    and lot_after_centi_pyitha >= 0
    and lot_before_centi_pyitha
      = settled_centi_pyitha + lot_after_centi_pyitha
  ),
  constraint consignment_settlement_price_valid check (
    pricing_divisor_pyitha > 0
    and market_price_kyat > 0
    and gross_value_kyat = round(
      settled_centi_pyitha::numeric
        / (100 * pricing_divisor_pyitha)
        * market_price_kyat
    )::bigint
    and gross_value_kyat > 0
  ),
  constraint consignment_settlement_expense_valid check (
    labour_rate_kyat >= 0
    and labour_total_kyat = round(
      settled_centi_pyitha::numeric / 3000 * labour_rate_kyat
    )::bigint
    and commission_rate between 0 and 100
    and commission_total_kyat = round(
      gross_value_kyat::numeric * commission_rate / 100
    )::bigint
    and freight_kyat >= 0
    and total_expense_kyat
      = labour_total_kyat + commission_total_kyat + freight_kyat
    and value_after_expense_kyat
      = gross_value_kyat - total_expense_kyat
    and value_after_expense_kyat >= 0
  ),
  constraint consignment_settlement_debt_valid check (
    debt_principal_kyat >= 0
    and debt_interest_kyat >= 0
    and debt_total_kyat = debt_principal_kyat + debt_interest_kyat
    and debt_elapsed_days >= 0
    and debt_half_month_steps >= 0
    and (
      (
        debt_advance_lot_id is null
        and debt_selected_quantity is null
        and debt_principal_kyat = 0
        and debt_interest_kyat = 0
        and debt_total_kyat = 0
        and debt_elapsed_days = 0
        and debt_half_month_steps = 0
        and debt_remaining_principal_kyat is null
        and debt_remaining_quantity is null
      )
      or
      (
        debt_advance_lot_id is not null
        and debt_principal_kyat > 0
        and debt_remaining_principal_kyat >= 0
      )
    )
  ),
  constraint consignment_settlement_payable_valid check (
    debt_total_kyat <= value_after_expense_kyat
    and payable_kyat = value_after_expense_kyat - debt_total_kyat
  ),
  constraint consignment_settlement_payment_valid check (
    payment_method in ('CASH', 'BANK', 'MOBILE')
    and (
      payable_kyat = 0
      or payment_method = 'CASH'
      or length(trim(payment_reference)) between 1 and 160
    )
  ),
  constraint consignment_settlement_stock_valid check (
    stock_before_centi_pyitha >= 0
    and stock_after_centi_pyitha
      = stock_before_centi_pyitha + settled_centi_pyitha
  ),
  constraint consignment_settlement_status_valid check (status = 'POSTED'),
  constraint consignment_settlement_notes_length check (
    notes is null or length(notes) <= 500
  )
);

create index if not exists consignment_settlements_date_idx
  on public.consignment_settlements(
    business_date desc, created_at desc, id
  );
create index if not exists consignment_settlements_lot_idx
  on public.consignment_settlements(
    consignment_lot_id, business_date, created_at, id
  );
create index if not exists consignment_settlements_farmer_idx
  on public.consignment_settlements(
    customer_id, business_date desc, created_at desc, id
  );

-- Custody lot headers are otherwise immutable.  Permit only the exact
-- server-side reduction made by the settlement transaction.
create or replace function public.guard_consignment_lot_mutation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE'
    and current_setting('app.consignment_post', true) = 'on'
    and old.status = 'OPEN'
    and old.available_weight_centi_pyitha > new.available_weight_centi_pyitha
    and new.available_weight_centi_pyitha >= 0
    and (
      (new.available_weight_centi_pyitha > 0 and new.status = 'OPEN')
      or (new.available_weight_centi_pyitha = 0 and new.status = 'CLOSED')
    )
    and (to_jsonb(new)
      - 'available_weight_centi_pyitha' - 'status' - 'updated_at')
      = (to_jsonb(old)
      - 'available_weight_centi_pyitha' - 'status' - 'updated_at') then
    return new;
  end if;

  raise exception 'Consignment lots can only change through custody workflows'
    using errcode = '42501';
end;
$$;

drop trigger if exists consignment_lots_guard_update_delete
  on public.consignment_lots;
create trigger consignment_lots_guard_update_delete
before update or delete on public.consignment_lots
for each row execute function public.guard_consignment_lot_mutation();

drop trigger if exists consignment_lots_prevent_truncate
  on public.consignment_lots;
create trigger consignment_lots_prevent_truncate
before truncate on public.consignment_lots
for each statement execute function public.guard_consignment_lot_mutation();

-- ---------------------------------------------------------------------------
-- Partial/full later settlement RPC.
-- ---------------------------------------------------------------------------

create or replace function public.settle_farmer_consignment(
  p_request_id uuid,
  p_consignment_lot_id uuid,
  p_sale_centi_pyitha bigint,
  p_market_price_kyat bigint,
  p_labour_rate_kyat bigint,
  p_commission_rate numeric,
  p_freight_kyat bigint,
  p_payment_method text,
  p_payment_reference text,
  p_debt_advance_lot_id uuid,
  p_debt_principal_kyat bigint,
  p_debt_quantity numeric,
  p_notes text
)
returns table(
  settlement_id uuid,
  settlement_ref text,
  business_date date,
  consignment_lot_id uuid,
  settled_centi_pyitha bigint,
  remaining_centi_pyitha bigint,
  gross_value_kyat bigint,
  total_expense_kyat bigint,
  debt_principal_kyat bigint,
  debt_interest_kyat bigint,
  debt_total_kyat bigint,
  payable_kyat bigint,
  stock_before_centi_pyitha bigint,
  stock_after_centi_pyitha bigint,
  idempotent boolean
)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_existing_tx public.finance_transactions%rowtype;
  v_existing public.consignment_settlements%rowtype;
  v_consignment public.consignment_lots%rowtype;
  v_crop public.crop_types%rowtype;
  v_advance public.advance_lots%rowtype;
  v_date date;
  v_method text := upper(trim(coalesce(p_payment_method, '')));
  v_reference text := nullif(trim(coalesce(p_payment_reference, '')), '');
  v_notes text := nullif(trim(coalesce(p_notes, '')), '');
  v_freight bigint := coalesce(p_freight_kyat, 0);
  v_payload jsonb;
  v_transaction_id uuid;
  v_settlement_id uuid;
  v_ref text;
  v_lot_before bigint;
  v_lot_after bigint;
  v_gross_value bigint;
  v_labour_total bigint;
  v_commission_total bigint;
  v_expense bigint;
  v_after_expense bigint;
  v_debt_principal bigint := 0;
  v_debt_interest bigint := 0;
  v_debt_total bigint := 0;
  v_debt_days integer := 0;
  v_debt_steps integer := 0;
  v_debt_quantity numeric(20,3);
  v_debt_remaining bigint;
  v_debt_remaining_quantity numeric(20,3);
  v_debt_status text;
  v_payable bigint;
  v_stock_before bigint;
  v_stock_after bigint;
begin
  perform public.require_staff_roles(array['owner']);

  if p_request_id is null or p_consignment_lot_id is null then
    raise exception 'Settlement request ID and consignment lot are required'
      using errcode = '22023';
  end if;

  v_payload := jsonb_build_object(
    'consignment_lot_id', p_consignment_lot_id,
    'sale_centi_pyitha', p_sale_centi_pyitha,
    'market_price_kyat', p_market_price_kyat,
    'labour_rate_kyat', p_labour_rate_kyat,
    'commission_rate', p_commission_rate,
    'freight_kyat', v_freight,
    'payment_method', v_method,
    'payment_reference', v_reference,
    'debt_advance_lot_id', p_debt_advance_lot_id,
    'debt_principal_kyat', p_debt_principal_kyat,
    'debt_quantity', p_debt_quantity,
    'notes', v_notes
  );

  select transactions.*
  into v_existing_tx
  from public.finance_transactions as transactions
  where transactions.request_id = p_request_id;

  if found then
    if v_existing_tx.document_type <> 'CONSIGNMENT_SETTLEMENT'
      or v_existing_tx.request_payload <> v_payload then
      raise exception 'Request ID was already used with different settlement data'
        using errcode = '23505';
    end if;

    select settlements.*
    into strict v_existing
    from public.consignment_settlements as settlements
    where settlements.transaction_id = v_existing_tx.id;

    return query select
      v_existing.id,
      v_existing.settlement_ref,
      v_existing.business_date,
      v_existing.consignment_lot_id,
      v_existing.settled_centi_pyitha,
      v_existing.lot_after_centi_pyitha,
      v_existing.gross_value_kyat,
      v_existing.total_expense_kyat,
      v_existing.debt_principal_kyat,
      v_existing.debt_interest_kyat,
      v_existing.debt_total_kyat,
      v_existing.payable_kyat,
      v_existing.stock_before_centi_pyitha,
      v_existing.stock_after_centi_pyitha,
      true;
    return;
  end if;

  v_date := public.assert_business_day_open();

  if p_sale_centi_pyitha is null or p_sale_centi_pyitha <= 0
    or p_market_price_kyat is null or p_market_price_kyat <= 0
    or p_labour_rate_kyat is null or p_labour_rate_kyat < 0
    or p_commission_rate is null or p_commission_rate < 0
    or p_commission_rate > 100
    or p_commission_rate <> round(p_commission_rate, 4)
    or v_freight < 0
    or v_method not in ('CASH', 'BANK', 'MOBILE')
    or (v_reference is not null and length(v_reference) > 160)
    or (v_notes is not null and length(v_notes) > 500) then
    raise exception 'Invalid consignment settlement input'
      using errcode = '22023';
  end if;

  select lots.*
  into v_consignment
  from public.consignment_lots as lots
  where lots.id = p_consignment_lot_id
  for update;

  if not found then
    raise exception 'Consignment lot not found' using errcode = 'P0002';
  end if;
  if v_consignment.status <> 'OPEN'
    or v_consignment.available_weight_centi_pyitha <= 0 then
    raise exception 'Only an open consignment lot may be settled'
      using errcode = '55000';
  end if;
  if p_sale_centi_pyitha > v_consignment.available_weight_centi_pyitha then
    raise exception 'Settlement weight exceeds consignment balance'
      using errcode = '22023';
  end if;

  select crops.*
  into v_crop
  from public.crop_types as crops
  where crops.crop_type_id = v_consignment.crop_type_id;

  if not found or v_crop.category <> 'BEAN'
    or v_crop.pricing_divisor_pyitha is null
    or v_crop.pricing_divisor_pyitha <= 0 then
    raise exception 'Consignment settlement requires a valid bean crop type'
      using errcode = '23503';
  end if;

  v_lot_before := v_consignment.available_weight_centi_pyitha;
  v_lot_after := v_lot_before - p_sale_centi_pyitha;
  v_gross_value := round(
    p_sale_centi_pyitha::numeric
      / (100 * v_crop.pricing_divisor_pyitha)
      * p_market_price_kyat
  )::bigint;
  v_labour_total := round(
    p_sale_centi_pyitha::numeric / 3000 * p_labour_rate_kyat
  )::bigint;
  v_commission_total := round(
    v_gross_value::numeric * p_commission_rate / 100
  )::bigint;
  v_expense := v_labour_total + v_commission_total + v_freight;
  v_after_expense := v_gross_value - v_expense;

  if v_gross_value <= 0 then
    raise exception 'Settlement value must be positive'
      using errcode = '22023';
  end if;
  if v_after_expense < 0 then
    raise exception 'Settlement expenses exceed crop value'
      using errcode = '22023';
  end if;

  if p_debt_advance_lot_id is not null then
    select lots.*
    into v_advance
    from public.advance_lots as lots
    where lots.id = p_debt_advance_lot_id
    for update;

    if not found
      or v_advance.customer_id <> v_consignment.customer_id
      or v_advance.status not in ('OPEN', 'PARTIAL')
      or v_advance.remaining_principal_kyat <= 0 then
      raise exception 'Selected open farmer advance lot not found'
        using errcode = '23503';
    end if;
    if v_date < v_advance.issued_date then
      raise exception 'Server business date is before advance issue date'
        using errcode = '22023';
    end if;

    if v_advance.advance_type = 'GOODS' then
      if p_debt_principal_kyat is not null then
        raise exception 'Goods debt offset uses quantity, not principal input'
          using errcode = '22023';
      end if;
      if p_debt_quantity is null or p_debt_quantity <= 0
        or p_debt_quantity <> round(p_debt_quantity, 3)
        or (v_advance.whole_units_only
          and p_debt_quantity <> trunc(p_debt_quantity))
        or p_debt_quantity > v_advance.remaining_quantity then
        raise exception 'Invalid goods debt quantity for consignment offset'
          using errcode = '22023';
      end if;

      v_debt_quantity := p_debt_quantity;
      if p_debt_quantity = v_advance.remaining_quantity then
        v_debt_principal := v_advance.remaining_principal_kyat;
        v_debt_remaining_quantity := 0;
      else
        v_debt_principal := round(
          p_debt_quantity * v_advance.unit_price_kyat
        )::bigint;
        v_debt_remaining_quantity
          := v_advance.remaining_quantity - p_debt_quantity;
        if v_debt_principal <= 0
          or v_debt_principal >= v_advance.remaining_principal_kyat then
          raise exception 'Partial goods offset would close principal inconsistently'
            using errcode = '22023';
        end if;
      end if;
    else
      if p_debt_quantity is not null then
        raise exception 'Cash debt offset uses principal, not quantity input'
          using errcode = '22023';
      end if;
      if p_debt_principal_kyat is null or p_debt_principal_kyat <= 0
        or p_debt_principal_kyat > v_advance.remaining_principal_kyat then
        raise exception 'Invalid cash debt principal for consignment offset'
          using errcode = '22023';
      end if;

      v_debt_principal := p_debt_principal_kyat;
      v_debt_quantity := null;
      v_debt_remaining_quantity := null;
    end if;

    v_debt_days := v_date - v_advance.issued_date;
    -- 1..15 days = half a month; 16..30 = one month; etc.
    v_debt_steps := case
      when v_debt_days = 0 then 0
      else (v_debt_days + 14) / 15
    end;
    v_debt_interest := round(
      v_debt_principal::numeric
        * v_advance.monthly_interest_rate / 100
        * v_debt_steps / 2
    )::bigint;
    v_debt_total := v_debt_principal + v_debt_interest;
    v_debt_remaining
      := v_advance.remaining_principal_kyat - v_debt_principal;

    if v_advance.advance_type = 'GOODS'
      and ((v_debt_remaining_quantity = 0) <> (v_debt_remaining = 0)) then
      raise exception 'Goods debt principal and quantity would close inconsistently'
        using errcode = '23514';
    end if;

    v_debt_status := case
      when v_debt_remaining = 0 then 'PAID'
      when v_debt_remaining < v_advance.original_principal_kyat
        then 'PARTIAL'
      else 'OPEN'
    end;
  elsif p_debt_principal_kyat is not null or p_debt_quantity is not null then
    raise exception 'Debt amount requires an advance lot'
      using errcode = '22023';
  end if;

  if v_debt_total > v_after_expense then
    raise exception 'Debt principal and interest exceed settlement proceeds'
      using errcode = '22023';
  end if;

  v_payable := v_after_expense - v_debt_total;
  if v_payable > 0 and v_method <> 'CASH' and v_reference is null then
    raise exception 'Bank or mobile payout reference is required'
      using errcode = '22023';
  end if;

  v_stock_before := public.crop_stock_quantity(
    v_crop.crop_type_id, v_consignment.location_id
  );
  v_stock_after := v_stock_before + p_sale_centi_pyitha;
  v_ref := public.next_finance_document_ref('CS', v_date);

  insert into public.finance_transactions(
    request_id, request_payload, document_ref, document_type,
    business_date, created_by
  ) values (
    p_request_id, v_payload, v_ref, 'CONSIGNMENT_SETTLEMENT',
    v_date, auth.uid()
  )
  returning id into v_transaction_id;

  insert into public.consignment_settlements(
    transaction_id, settlement_ref, consignment_lot_id, business_date,
    customer_id, farmer_name_snapshot, crop_type_id, crop_name_snapshot,
    location_id, original_lot_centi_pyitha, lot_before_centi_pyitha,
    settled_centi_pyitha, lot_after_centi_pyitha, pricing_divisor_pyitha,
    market_price_kyat, gross_value_kyat, labour_rate_kyat,
    labour_total_kyat, commission_rate, commission_total_kyat,
    freight_kyat, total_expense_kyat, value_after_expense_kyat,
    debt_advance_lot_id, debt_selected_quantity, debt_principal_kyat,
    debt_interest_kyat, debt_total_kyat, debt_elapsed_days,
    debt_half_month_steps, debt_remaining_principal_kyat,
    debt_remaining_quantity, payable_kyat, payment_method,
    payment_reference, notes, stock_before_centi_pyitha,
    stock_after_centi_pyitha, created_by
  ) values (
    v_transaction_id, v_ref, v_consignment.id, v_date,
    v_consignment.customer_id, v_consignment.customer_name,
    v_crop.crop_type_id, v_crop.name, v_consignment.location_id,
    v_consignment.original_net_weight_centi_pyitha, v_lot_before,
    p_sale_centi_pyitha, v_lot_after, v_crop.pricing_divisor_pyitha,
    p_market_price_kyat, v_gross_value, p_labour_rate_kyat,
    v_labour_total, p_commission_rate, v_commission_total,
    v_freight, v_expense, v_after_expense, p_debt_advance_lot_id,
    v_debt_quantity, v_debt_principal, v_debt_interest, v_debt_total,
    v_debt_days, v_debt_steps,
    case when p_debt_advance_lot_id is null then null
      else v_debt_remaining end,
    case when p_debt_advance_lot_id is null then null
      else v_debt_remaining_quantity end,
    v_payable, v_method, v_reference, v_notes,
    v_stock_before, v_stock_after, auth.uid()
  )
  returning id into v_settlement_id;

  if p_debt_advance_lot_id is not null then
    perform set_config('app.finance_post', 'on', true);
    update public.advance_lots
    set remaining_principal_kyat = v_debt_remaining,
      remaining_quantity = v_debt_remaining_quantity,
      status = v_debt_status,
      updated_at = now()
    where id = v_advance.id;

    insert into public.advance_repayments(
      transaction_id, repayment_ref, advance_lot_id, payment_date,
      quantity_before, selected_quantity, principal_before_kyat,
      principal_kyat, interest_kyat, total_received_kyat,
      elapsed_days, half_month_steps, monthly_interest_rate_snapshot,
      payment_method, payment_reference, notes, remaining_quantity,
      remaining_principal_kyat, created_by
    ) values (
      v_transaction_id, v_ref || '-RP', v_advance.id, v_date,
      v_advance.remaining_quantity, v_debt_quantity,
      v_advance.remaining_principal_kyat, v_debt_principal,
      v_debt_interest, v_debt_total, v_debt_days, v_debt_steps,
      v_advance.monthly_interest_rate, 'OFFSET', v_ref,
      'Consignment settlement offset', v_debt_remaining_quantity,
      v_debt_remaining, auth.uid()
    );
    perform set_config('app.finance_post', '', true);
  end if;

  insert into public.crop_stock_movements(
    transaction_id, movement_ref, business_date, crop_type_id, location_id,
    crop_name_snapshot, movement_type, quantity_delta_centi_pyitha,
    quantity_before_centi_pyitha, quantity_after_centi_pyitha, created_by
  ) values (
    v_transaction_id, v_ref, v_date, v_crop.crop_type_id,
    v_consignment.location_id, v_crop.name, 'PURCHASE_IN',
    p_sale_centi_pyitha, v_stock_before, v_stock_after, auth.uid()
  );

  if v_payable > 0 then
    insert into public.cash_ledger_entries(
      transaction_id, document_ref, business_date, direction, amount_kyat,
      payment_method, category, label, principal_kyat, interest_kyat,
      created_by
    ) values (
      v_transaction_id, v_ref, v_date, 'OUT', v_payable, v_method,
      'FARMER_PAYOUT',
      'အပ်ပဲဖြတ်ငွေရှင်း · ' || v_consignment.customer_name
        || ' · ' || v_crop.name,
      0, 0, auth.uid()
    );
  end if;

  perform set_config('app.consignment_post', 'on', true);
  update public.consignment_lots
  set available_weight_centi_pyitha = v_lot_after,
    status = case when v_lot_after = 0 then 'CLOSED' else 'OPEN' end,
    updated_at = now()
  where id = v_consignment.id;
  perform set_config('app.consignment_post', '', true);

  insert into public.consignment_movements(
    request_id, lot_id, movement_type, business_date,
    quantity_centi_pyitha, balance_after_centi_pyitha, notes,
    actor_user_id
  ) values (
    p_request_id, v_consignment.id, 'SALE_TRANSFER', v_date,
    p_sale_centi_pyitha, v_lot_after,
    'Consignment sale transfer · ' || v_ref, auth.uid()
  );

  insert into public.finance_audit_events(
    transaction_id, document_ref, action, payload, created_by
  ) values (
    v_transaction_id, v_ref, 'CONSIGNMENT_SETTLED', jsonb_build_object(
      'consignment_lot_id', v_consignment.id,
      'lot_ref', v_consignment.lot_ref,
      'settled_centi_pyitha', p_sale_centi_pyitha,
      'remaining_centi_pyitha', v_lot_after,
      'gross_value_kyat', v_gross_value,
      'expense_kyat', v_expense,
      'debt_principal_kyat', v_debt_principal,
      'debt_interest_kyat', v_debt_interest,
      'payable_kyat', v_payable,
      'stock_after', v_stock_after
    ), auth.uid()
  );

  return query select
    v_settlement_id,
    v_ref,
    v_date,
    v_consignment.id,
    p_sale_centi_pyitha,
    v_lot_after,
    v_gross_value,
    v_expense,
    v_debt_principal,
    v_debt_interest,
    v_debt_total,
    v_payable,
    v_stock_before,
    v_stock_after,
    false;
end;
$$;

-- ---------------------------------------------------------------------------
-- Immutability, RLS, grants and realtime.
-- ---------------------------------------------------------------------------

drop trigger if exists consignment_settlements_prevent_update_delete
  on public.consignment_settlements;
create trigger consignment_settlements_prevent_update_delete
before update or delete on public.consignment_settlements
for each row execute function public.prevent_finance_ledger_mutation();

drop trigger if exists consignment_settlements_prevent_truncate
  on public.consignment_settlements;
create trigger consignment_settlements_prevent_truncate
before truncate on public.consignment_settlements
for each statement execute function public.prevent_finance_ledger_mutation();

alter table public.consignment_settlements enable row level security;
alter table public.consignment_settlements force row level security;
revoke all on table public.consignment_settlements from anon, authenticated;
grant select on table public.consignment_settlements to authenticated;
grant all on table public.consignment_settlements to service_role;

drop policy if exists "Owner can read consignment settlements"
  on public.consignment_settlements;
create policy "Owner can read consignment settlements"
  on public.consignment_settlements
  for select
  to authenticated
  using (public.current_staff_has_role(array['owner']));

revoke all on function public.guard_consignment_lot_mutation()
  from public, anon, authenticated;
grant execute on function public.guard_consignment_lot_mutation()
  to service_role;

revoke all on function public.settle_farmer_consignment(
  uuid,uuid,bigint,bigint,bigint,numeric,bigint,text,text,
  uuid,bigint,numeric,text
) from public, anon, authenticated;
grant execute on function public.settle_farmer_consignment(
  uuid,uuid,bigint,bigint,bigint,numeric,bigint,text,text,
  uuid,bigint,numeric,text
) to authenticated, service_role;

alter table public.consignment_settlements replica identity full;

do $$
begin
  if exists (
    select 1 from pg_publication where pubname = 'supabase_realtime'
  ) and not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'consignment_settlements'
  ) then
    alter publication supabase_realtime
      add table public.consignment_settlements;
  end if;
end;
$$;

comment on table public.consignment_settlements is
  'Immutable partial/full purchase settlement of farmer-owned custody stock.';
comment on function public.settle_farmer_consignment(
  uuid,uuid,bigint,bigint,bigint,numeric,bigint,text,text,
  uuid,bigint,numeric,text
) is
  'Atomically transfers selected farmer consignment weight into owned crop stock, offsets optional debt, pays the farmer and preserves any remaining custody balance.';

notify pgrst, 'reload schema';

commit;
