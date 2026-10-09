-- Mi Mi Khine Pwal Yon: owner-only operational finance ledger.
--
-- This migration makes advances, partial repayments, input-product sales and
-- daily expenses authoritative in PostgreSQL. All writes go through atomic,
-- idempotent SECURITY DEFINER RPCs. Browser roles can only read rows allowed by
-- RLS; they cannot directly insert, update or delete ledger records.

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- Server document numbering and immutable transaction header
-- ---------------------------------------------------------------------------

create table if not exists public.finance_document_counters (
  business_date date not null,
  prefix text not null,
  last_value bigint not null default 0,
  primary key (business_date, prefix),
  constraint finance_document_counter_prefix_valid check (
    prefix in ('AD', 'RP', 'GS', 'ST', 'EX')
  ),
  constraint finance_document_counter_value_valid check (last_value >= 0)
);

create table if not exists public.finance_transactions (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null unique,
  request_payload jsonb not null,
  document_ref text not null unique,
  document_type text not null,
  business_date date not null default public.get_business_date(),
  status text not null default 'POSTED',
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),

  constraint finance_transaction_type_valid check (
    document_type in (
      'ADVANCE', 'ADVANCE_REPAYMENT', 'PRODUCT_SALE', 'STOCK_RECEIPT',
      'EXPENSE'
    )
  ),
  constraint finance_transaction_status_valid check (status = 'POSTED'),
  constraint finance_transaction_payload_valid check (
    jsonb_typeof(request_payload) = 'object'
  ),
  constraint finance_transaction_ref_valid check (
    document_ref ~ '^(AD|RP|GS|ST|EX)-[0-9]{8}-[0-9]{6,}$'
  )
);

create index if not exists finance_transactions_date_idx
  on public.finance_transactions (business_date desc, created_at desc, id);

-- The migration is intentionally safe to rerun after an earlier owner-finance
-- pilot. Replace the two enum-like checks with additive production values.
alter table public.finance_document_counters
  drop constraint if exists finance_document_counter_prefix_valid;
alter table public.finance_document_counters
  add constraint finance_document_counter_prefix_valid check (
    prefix in ('AD', 'RP', 'GS', 'ST', 'EX')
  );

alter table public.finance_transactions
  drop constraint if exists finance_transaction_type_valid;
alter table public.finance_transactions
  add constraint finance_transaction_type_valid check (
    document_type in (
      'ADVANCE', 'ADVANCE_REPAYMENT', 'PRODUCT_SALE', 'STOCK_RECEIPT',
      'EXPENSE'
    )
  );
alter table public.finance_transactions
  drop constraint if exists finance_transaction_ref_valid;
alter table public.finance_transactions
  add constraint finance_transaction_ref_valid check (
    document_ref ~ '^(AD|RP|GS|ST|EX)-[0-9]{8}-[0-9]{6,}$'
  );

-- ---------------------------------------------------------------------------
-- Advances and their partial repayments
-- ---------------------------------------------------------------------------

create table if not exists public.advance_lots (
  id uuid primary key default gen_random_uuid(),
  transaction_id uuid unique references public.finance_transactions (id)
    on update restrict on delete restrict,
  opening_balance_entry_id bigint unique references public.opening_balance_entries (id)
    on update restrict on delete restrict,
  advance_ref text not null unique,
  customer_id text not null references public.farmers (customer_id)
    on update restrict on delete restrict,
  farmer_name_snapshot text not null,
  advance_type text not null,
  product_id text references public.products (product_id)
    on update restrict on delete restrict,
  location_id text references public.stock_locations (location_id)
    on update restrict on delete restrict,
  product_name_snapshot text,
  unit_name_snapshot text not null,
  whole_units_only boolean not null default true,
  unit_price_kyat bigint not null,
  original_quantity numeric(20, 3),
  remaining_quantity numeric(20, 3),
  original_principal_kyat bigint not null,
  remaining_principal_kyat bigint not null,
  monthly_interest_rate numeric(7, 4) not null,
  issued_date date not null,
  status text not null default 'OPEN',
  notes text,
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint advance_lot_source_valid check (
    (transaction_id is not null and opening_balance_entry_id is null)
    or (transaction_id is null and opening_balance_entry_id is not null)
  ),
  constraint advance_lot_type_valid check (advance_type in ('CASH', 'GOODS')),
  constraint advance_lot_status_valid check (status in ('OPEN', 'PARTIAL', 'PAID')),
  constraint advance_lot_name_present check (
    length(trim(farmer_name_snapshot)) between 1 and 160
  ),
  constraint advance_lot_unit_present check (
    length(trim(unit_name_snapshot)) between 1 and 40
  ),
  constraint advance_lot_money_valid check (
    unit_price_kyat > 0
    and original_principal_kyat > 0
    and remaining_principal_kyat between 0 and original_principal_kyat
    and monthly_interest_rate between 0 and 100
  ),
  constraint advance_lot_notes_length check (
    notes is null or length(notes) <= 500
  ),
  constraint advance_lot_shape_valid check (
    (
      advance_type = 'CASH'
      and product_id is null
      and location_id is null
      and product_name_snapshot is null
      and unit_name_snapshot = 'ကျပ်'
      and unit_price_kyat = 1
      and original_quantity is null
      and remaining_quantity is null
    )
    or
    (
      advance_type = 'GOODS'
      and product_id is not null
      and location_id is not null
      and length(trim(product_name_snapshot)) between 1 and 160
      and original_quantity > 0
      and remaining_quantity between 0 and original_quantity
      and (not whole_units_only or original_quantity = trunc(original_quantity))
      and (not whole_units_only or remaining_quantity = trunc(remaining_quantity))
    )
  ),
  constraint advance_lot_status_balance_valid check (
    (status = 'OPEN'
        and remaining_principal_kyat = original_principal_kyat
        and (advance_type = 'CASH'
             or remaining_quantity = original_quantity))
    or (status = 'PARTIAL' and remaining_principal_kyat > 0
        and remaining_principal_kyat < original_principal_kyat
        and (advance_type = 'CASH' or remaining_quantity > 0))
    or (status = 'PAID' and remaining_principal_kyat = 0
        and (advance_type = 'CASH' or remaining_quantity = 0))
  )
);

alter table public.advance_lots
  drop constraint if exists advance_lot_status_balance_valid;
alter table public.advance_lots
  add constraint advance_lot_status_balance_valid check (
    (status = 'OPEN'
        and remaining_principal_kyat = original_principal_kyat
        and (advance_type = 'CASH'
             or remaining_quantity = original_quantity))
    or (status = 'PARTIAL' and remaining_principal_kyat > 0
        and remaining_principal_kyat < original_principal_kyat
        and (advance_type = 'CASH' or remaining_quantity > 0))
    or (status = 'PAID' and remaining_principal_kyat = 0
        and (advance_type = 'CASH' or remaining_quantity = 0))
  );

create index if not exists advance_lots_customer_open_idx
  on public.advance_lots (customer_id, issued_date, advance_ref)
  where status in ('OPEN', 'PARTIAL');
create index if not exists advance_lots_created_idx
  on public.advance_lots (created_at desc, id);

create table if not exists public.advance_repayments (
  id uuid primary key default gen_random_uuid(),
  transaction_id uuid not null unique references public.finance_transactions (id)
    on update restrict on delete restrict,
  repayment_ref text not null unique,
  advance_lot_id uuid not null references public.advance_lots (id)
    on update restrict on delete restrict,
  payment_date date not null,
  quantity_before numeric(20, 3),
  selected_quantity numeric(20, 3),
  principal_before_kyat bigint not null,
  principal_kyat bigint not null,
  interest_kyat bigint not null,
  total_received_kyat bigint not null,
  elapsed_days integer not null,
  half_month_steps integer not null,
  monthly_interest_rate_snapshot numeric(7, 4) not null,
  payment_method text not null,
  payment_reference text,
  notes text,
  remaining_quantity numeric(20, 3),
  remaining_principal_kyat bigint not null,
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),

  constraint advance_repayment_money_valid check (
    principal_before_kyat >= principal_kyat
    and principal_kyat > 0
    and interest_kyat >= 0
    and total_received_kyat = principal_kyat + interest_kyat
    and remaining_principal_kyat >= 0
  ),
  constraint advance_repayment_period_valid check (
    elapsed_days >= 0 and half_month_steps >= 0
    and monthly_interest_rate_snapshot between 0 and 100
  ),
  constraint advance_repayment_method_valid check (
    payment_method in ('CASH', 'BANK', 'MOBILE')
  ),
  constraint advance_repayment_reference_valid check (
    payment_method = 'CASH'
    or length(trim(payment_reference)) between 1 and 160
  ),
  constraint advance_repayment_notes_length check (
    notes is null or length(notes) <= 500
  )
);

create index if not exists advance_repayments_lot_idx
  on public.advance_repayments (advance_lot_id, payment_date, created_at);
create index if not exists advance_repayments_date_idx
  on public.advance_repayments (payment_date desc, created_at desc, id);

-- ---------------------------------------------------------------------------
-- Product stock movement, immediate sales, cashbook and expenses
-- ---------------------------------------------------------------------------

create table if not exists public.product_stock_movements (
  id uuid primary key default gen_random_uuid(),
  transaction_id uuid not null unique references public.finance_transactions (id)
    on update restrict on delete restrict,
  movement_ref text not null,
  business_date date not null default public.get_business_date(),
  product_id text not null references public.products (product_id)
    on update restrict on delete restrict,
  location_id text not null references public.stock_locations (location_id)
    on update restrict on delete restrict,
  product_name_snapshot text not null,
  unit_name_snapshot text not null,
  movement_type text not null,
  quantity_delta numeric(20, 3) not null,
  quantity_before numeric(20, 3) not null,
  quantity_after numeric(20, 3) not null,
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),

  constraint product_stock_movement_type_valid check (
    movement_type in ('IN_PURCHASE', 'OUT_ADVANCE', 'OUT_SALE')
  ),
  constraint product_stock_movement_quantity_valid check (
    quantity_before >= 0
    and quantity_after >= 0
    and quantity_after = quantity_before + quantity_delta
    and (
      (movement_type = 'IN_PURCHASE' and quantity_delta > 0)
      or
      (movement_type in ('OUT_ADVANCE', 'OUT_SALE') and quantity_delta < 0)
    )
  ),
  constraint product_stock_movement_snapshot_valid check (
    length(trim(product_name_snapshot)) between 1 and 160
    and length(trim(unit_name_snapshot)) between 1 and 40
  )
);

create index if not exists product_stock_movements_balance_idx
  on public.product_stock_movements (product_id, location_id, created_at, id);
create index if not exists product_stock_movements_date_idx
  on public.product_stock_movements (business_date desc, created_at desc, id);

alter table public.product_stock_movements
  drop constraint if exists product_stock_movement_type_valid;
alter table public.product_stock_movements
  add constraint product_stock_movement_type_valid check (
    movement_type in ('IN_PURCHASE', 'OUT_ADVANCE', 'OUT_SALE')
  );
alter table public.product_stock_movements
  drop constraint if exists product_stock_movement_quantity_valid;
alter table public.product_stock_movements
  add constraint product_stock_movement_quantity_valid check (
    quantity_before >= 0
    and quantity_after >= 0
    and quantity_after = quantity_before + quantity_delta
    and (
      (movement_type = 'IN_PURCHASE' and quantity_delta > 0)
      or
      (movement_type in ('OUT_ADVANCE', 'OUT_SALE') and quantity_delta < 0)
    )
  );

-- `product_sales` already belongs to the earlier Stage 4 sales ledger in some
-- deployed databases. Keep this focused owner-finance posting table under an
-- unambiguous name so the migration is additive and never mutates legacy rows.
create table if not exists public.finance_product_sales (
  id uuid primary key default gen_random_uuid(),
  transaction_id uuid not null unique references public.finance_transactions (id)
    on update restrict on delete restrict,
  sale_ref text not null unique,
  business_date date not null default public.get_business_date(),
  customer_type text not null,
  customer_id text references public.farmers (customer_id)
    on update restrict on delete restrict,
  buyer_name text not null,
  product_id text not null references public.products (product_id)
    on update restrict on delete restrict,
  location_id text not null references public.stock_locations (location_id)
    on update restrict on delete restrict,
  product_name_snapshot text not null,
  unit_name_snapshot text not null,
  quantity numeric(20, 3) not null,
  unit_price_kyat bigint not null,
  total_kyat bigint not null,
  payment_method text not null,
  payment_reference text,
  notes text,
  stock_before numeric(20, 3) not null,
  stock_after numeric(20, 3) not null,
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),

  constraint product_sale_customer_type_valid check (
    customer_type in ('WALK_IN', 'FARMER')
  ),
  constraint product_sale_customer_shape_valid check (
    (customer_type = 'FARMER' and customer_id is not null)
    or (customer_type = 'WALK_IN' and customer_id is null)
  ),
  constraint product_sale_buyer_present check (
    length(trim(buyer_name)) between 1 and 160
  ),
  constraint product_sale_values_valid check (
    quantity > 0 and unit_price_kyat > 0
    and total_kyat = round(quantity * unit_price_kyat)::bigint
    and stock_before >= quantity
    and stock_after = stock_before - quantity
  ),
  constraint product_sale_method_valid check (
    payment_method in ('CASH', 'BANK', 'MOBILE')
  ),
  constraint product_sale_reference_valid check (
    payment_method = 'CASH'
    or length(trim(payment_reference)) between 1 and 160
  ),
  constraint product_sale_notes_length check (
    notes is null or length(notes) <= 500
  )
);

create index if not exists finance_product_sales_date_idx
  on public.finance_product_sales (business_date desc, created_at desc, id);

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.finance_product_sales'::regclass
      and conname = 'product_sale_customer_shape_valid'
  ) then
    alter table public.finance_product_sales
      add constraint product_sale_customer_shape_valid check (
        (customer_type = 'FARMER' and customer_id is not null)
        or (customer_type = 'WALK_IN' and customer_id is null)
      );
  end if;
end;
$$;

create table if not exists public.finance_stock_receipts (
  id uuid primary key default gen_random_uuid(),
  transaction_id uuid not null unique references public.finance_transactions (id)
    on update restrict on delete restrict,
  receipt_ref text not null unique,
  business_date date not null default public.get_business_date(),
  supplier_name text not null,
  product_id text not null references public.products (product_id)
    on update restrict on delete restrict,
  location_id text not null references public.stock_locations (location_id)
    on update restrict on delete restrict,
  product_name_snapshot text not null,
  unit_name_snapshot text not null,
  whole_units_only boolean not null,
  quantity numeric(20, 3) not null,
  unit_cost_kyat bigint not null,
  total_kyat bigint not null,
  payment_method text not null,
  payment_reference text,
  notes text,
  stock_before numeric(20, 3) not null,
  stock_after numeric(20, 3) not null,
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),

  constraint finance_stock_receipt_supplier_present check (
    length(trim(supplier_name)) between 1 and 160
  ),
  constraint finance_stock_receipt_snapshot_valid check (
    length(trim(product_name_snapshot)) between 1 and 160
    and length(trim(unit_name_snapshot)) between 1 and 40
  ),
  constraint finance_stock_receipt_values_valid check (
    quantity > 0 and unit_cost_kyat > 0
    and total_kyat = round(quantity * unit_cost_kyat)::bigint
    and stock_before >= 0
    and stock_after = stock_before + quantity
    and (not whole_units_only or quantity = trunc(quantity))
  ),
  constraint finance_stock_receipt_method_valid check (
    payment_method in ('CASH', 'BANK', 'MOBILE')
  ),
  constraint finance_stock_receipt_reference_valid check (
    payment_method = 'CASH'
    or length(trim(payment_reference)) between 1 and 160
  ),
  constraint finance_stock_receipt_notes_length check (
    notes is null or length(notes) <= 500
  )
);

create index if not exists finance_stock_receipts_date_idx
  on public.finance_stock_receipts (business_date desc, created_at desc, id);

create table if not exists public.business_expenses (
  id uuid primary key default gen_random_uuid(),
  transaction_id uuid not null unique references public.finance_transactions (id)
    on update restrict on delete restrict,
  expense_ref text not null unique,
  business_date date not null default public.get_business_date(),
  category text not null,
  amount_kyat bigint not null,
  payment_method text not null,
  payment_reference text,
  notes text,
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),

  constraint business_expense_category_present check (
    length(trim(category)) between 1 and 100
  ),
  constraint business_expense_amount_positive check (amount_kyat > 0),
  constraint business_expense_method_valid check (
    payment_method in ('CASH', 'BANK', 'MOBILE')
  ),
  constraint business_expense_reference_valid check (
    payment_method = 'CASH'
    or length(trim(payment_reference)) between 1 and 160
  ),
  constraint business_expense_notes_length check (
    notes is null or length(notes) <= 500
  )
);

create index if not exists business_expenses_date_idx
  on public.business_expenses (business_date desc, created_at desc, id);

create table if not exists public.cash_ledger_entries (
  id uuid primary key default gen_random_uuid(),
  transaction_id uuid not null unique references public.finance_transactions (id)
    on update restrict on delete restrict,
  document_ref text not null,
  business_date date not null default public.get_business_date(),
  direction text not null,
  amount_kyat bigint not null,
  payment_method text not null,
  category text not null,
  label text not null,
  principal_kyat bigint not null default 0,
  interest_kyat bigint not null default 0,
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),

  constraint cash_ledger_direction_valid check (direction in ('IN', 'OUT')),
  constraint cash_ledger_amount_positive check (amount_kyat > 0),
  constraint cash_ledger_method_valid check (
    payment_method in ('CASH', 'BANK', 'MOBILE')
  ),
  constraint cash_ledger_category_valid check (
    category in (
      'ADVANCE', 'DEBT_REPAYMENT', 'PRODUCT_SALE', 'STOCK_PURCHASE',
      'EXPENSE'
    )
  ),
  constraint cash_ledger_breakdown_valid check (
    principal_kyat >= 0 and interest_kyat >= 0
    and (
      category <> 'DEBT_REPAYMENT'
      or amount_kyat = principal_kyat + interest_kyat
    )
  ),
  constraint cash_ledger_label_present check (
    length(trim(label)) between 1 and 300
  )
);

create index if not exists cash_ledger_date_idx
  on public.cash_ledger_entries (business_date desc, created_at desc, id);

alter table public.cash_ledger_entries
  drop constraint if exists cash_ledger_category_valid;
alter table public.cash_ledger_entries
  add constraint cash_ledger_category_valid check (
    category in (
      'ADVANCE', 'DEBT_REPAYMENT', 'PRODUCT_SALE', 'STOCK_PURCHASE',
      'EXPENSE'
    )
  );

create table if not exists public.finance_audit_events (
  id bigint generated always as identity primary key,
  transaction_id uuid references public.finance_transactions (id)
    on update restrict on delete restrict,
  document_ref text not null,
  action text not null,
  payload jsonb not null default '{}'::jsonb,
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),

  constraint finance_audit_action_present check (
    length(trim(action)) between 1 and 100
  )
);

create index if not exists finance_audit_created_idx
  on public.finance_audit_events (created_at desc, id desc);

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

create or replace function public.next_finance_document_ref(
  p_prefix text,
  p_business_date date
)
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_prefix text := upper(trim(coalesce(p_prefix, '')));
  v_value bigint;
begin
  if v_prefix not in ('AD', 'RP', 'GS', 'ST', 'EX') then
    raise exception 'Unsupported finance document prefix: %', p_prefix
      using errcode = '22023';
  end if;
  if p_business_date is null then
    raise exception 'Business date is required' using errcode = '22023';
  end if;

  insert into public.finance_document_counters (
    business_date, prefix, last_value
  ) values (
    p_business_date, v_prefix, 1
  )
  on conflict (business_date, prefix) do update
    set last_value = public.finance_document_counters.last_value + 1
  returning last_value into v_value;

  return v_prefix || '-' || to_char(p_business_date, 'YYYYMMDD') || '-'
    || lpad(v_value::text, 6, '0');
end;
$$;

create or replace function public.product_stock_quantity(
  p_product_id text,
  p_location_id text
)
returns numeric
language sql
stable
security definer
set search_path = ''
as $$
  select
    coalesce((
      select sum(entries.quantity)
      from public.opening_balance_entries as entries
      where entries.entry_type = 'PRODUCT_STOCK'
        and entries.product_id = p_product_id
        and entries.location_id = p_location_id
    ), 0)::numeric
    + coalesce((
      select sum(movements.quantity_delta)
      from public.product_stock_movements as movements
      where movements.product_id = p_product_id
        and movements.location_id = p_location_id
    ), 0)::numeric;
$$;

create or replace function public.get_product_stock_balances()
returns table (
  product_id text,
  location_id text,
  quantity numeric
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform public.require_staff_roles(array['owner']);
  return query
  select
    products.product_id,
    locations.location_id,
    public.product_stock_quantity(products.product_id, locations.location_id)
  from public.products as products
  cross join public.stock_locations as locations
  where products.active = true
    and locations.active = true
  order by products.product_id, locations.location_id;
end;
$$;

create or replace function public.get_farmer_debt_balances()
returns table (
  customer_id text,
  remaining_principal_kyat bigint,
  open_lot_count integer
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform public.require_staff_roles(array['owner']);
  return query
  select
    farmers.customer_id,
    coalesce(sum(lots.remaining_principal_kyat), 0)::bigint,
    count(lots.id) filter (where lots.status in ('OPEN', 'PARTIAL'))::integer
  from public.farmers as farmers
  left join public.advance_lots as lots
    on lots.customer_id = farmers.customer_id
    and lots.status in ('OPEN', 'PARTIAL')
  group by farmers.customer_id
  order by farmers.customer_id;
end;
$$;

create or replace function public.get_daily_cash_flow()
returns table (
  business_date date,
  cash_in_kyat bigint,
  cash_out_kyat bigint,
  net_kyat bigint,
  physical_cash_in_kyat bigint,
  physical_cash_out_kyat bigint,
  advance_cash_kyat bigint,
  expense_cash_kyat bigint,
  expense_total_kyat bigint,
  product_sales_total_kyat bigint,
  product_sales_cash_kyat bigint,
  product_sales_non_cash_kyat bigint,
  non_cash_in_kyat bigint,
  non_cash_out_kyat bigint,
  entry_count bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_business_date date := public.get_business_date();
begin
  perform public.require_staff_roles(array['owner']);

  return query
  with days as (
    select series.day::date as business_date
    from generate_series(
      (v_business_date - 6)::timestamp,
      v_business_date::timestamp,
      interval '1 day'
    ) as series(day)
  ), totals as (
    select
      days.business_date,
      coalesce(sum(entries.amount_kyat)
        filter (where entries.direction = 'IN'), 0)::bigint as cash_in_kyat,
      coalesce(sum(entries.amount_kyat)
        filter (where entries.direction = 'OUT'), 0)::bigint as cash_out_kyat,
      coalesce(sum(entries.amount_kyat) filter (
        where entries.direction = 'IN' and entries.payment_method = 'CASH'
      ), 0)::bigint as physical_cash_in_kyat,
      coalesce(sum(entries.amount_kyat) filter (
        where entries.direction = 'OUT' and entries.payment_method = 'CASH'
      ), 0)::bigint as physical_cash_out_kyat,
      coalesce(sum(entries.amount_kyat) filter (
        where entries.category = 'ADVANCE'
          and entries.direction = 'OUT'
          and entries.payment_method = 'CASH'
      ), 0)::bigint as advance_cash_kyat,
      coalesce(sum(entries.amount_kyat) filter (
        where entries.category = 'EXPENSE'
          and entries.direction = 'OUT'
          and entries.payment_method = 'CASH'
      ), 0)::bigint as expense_cash_kyat,
      coalesce(sum(entries.amount_kyat) filter (
        where entries.category = 'EXPENSE'
          and entries.direction = 'OUT'
      ), 0)::bigint as expense_total_kyat,
      coalesce(sum(entries.amount_kyat) filter (
        where entries.category = 'PRODUCT_SALE'
          and entries.direction = 'IN'
      ), 0)::bigint as product_sales_total_kyat,
      coalesce(sum(entries.amount_kyat) filter (
        where entries.category = 'PRODUCT_SALE'
          and entries.direction = 'IN'
          and entries.payment_method = 'CASH'
      ), 0)::bigint as product_sales_cash_kyat,
      coalesce(sum(entries.amount_kyat) filter (
        where entries.category = 'PRODUCT_SALE'
          and entries.direction = 'IN'
          and entries.payment_method <> 'CASH'
      ), 0)::bigint as product_sales_non_cash_kyat,
      coalesce(sum(entries.amount_kyat) filter (
        where entries.direction = 'IN' and entries.payment_method <> 'CASH'
      ), 0)::bigint as non_cash_in_kyat,
      coalesce(sum(entries.amount_kyat) filter (
        where entries.direction = 'OUT' and entries.payment_method <> 'CASH'
      ), 0)::bigint as non_cash_out_kyat,
      count(entries.id)::bigint as entry_count
    from days
    left join public.cash_ledger_entries as entries
      on entries.business_date = days.business_date
    group by days.business_date
  )
  select
    totals.business_date,
    totals.cash_in_kyat,
    totals.cash_out_kyat,
    totals.cash_in_kyat - totals.cash_out_kyat,
    totals.physical_cash_in_kyat,
    totals.physical_cash_out_kyat,
    totals.advance_cash_kyat,
    totals.expense_cash_kyat,
    totals.expense_total_kyat,
    totals.product_sales_total_kyat,
    totals.product_sales_cash_kyat,
    totals.product_sales_non_cash_kyat,
    totals.non_cash_in_kyat,
    totals.non_cash_out_kyat,
    totals.entry_count
  from totals
  order by totals.business_date;
end;
$$;

-- ---------------------------------------------------------------------------
-- Atomic write RPCs
-- ---------------------------------------------------------------------------

create or replace function public.issue_advance(
  p_request_id uuid,
  p_customer_id text,
  p_advance_type text,
  p_principal_kyat bigint,
  p_monthly_interest_rate numeric,
  p_product_id text,
  p_quantity numeric,
  p_unit_price_kyat bigint,
  p_location_id text,
  p_notes text
)
returns table (
  advance_id uuid,
  advance_ref text,
  business_date date,
  original_principal_kyat bigint,
  original_quantity numeric,
  stock_before numeric,
  stock_after numeric,
  idempotent boolean
)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_existing_tx public.finance_transactions%rowtype;
  v_existing_lot public.advance_lots%rowtype;
  v_existing_move public.product_stock_movements%rowtype;
  v_farmer public.farmers%rowtype;
  v_product public.products%rowtype;
  v_location public.stock_locations%rowtype;
  v_type text := upper(trim(coalesce(p_advance_type, '')));
  v_business_date date := public.get_business_date();
  v_transaction_id uuid;
  v_ref text;
  v_lot_id uuid;
  v_principal bigint;
  v_before numeric(20, 3);
  v_after numeric(20, 3);
  v_payload jsonb;
begin
  perform public.require_staff_roles(array['owner']);

  if p_request_id is null then
    raise exception 'Advance request ID is required' using errcode = '22023';
  end if;

  v_payload := jsonb_build_object(
    'customer_id', trim(coalesce(p_customer_id, '')),
    'advance_type', upper(trim(coalesce(p_advance_type, ''))),
    'principal_kyat', p_principal_kyat,
    'monthly_interest_rate', p_monthly_interest_rate,
    'product_id', nullif(trim(coalesce(p_product_id, '')), ''),
    'quantity', p_quantity,
    'unit_price_kyat', p_unit_price_kyat,
    'location_id', nullif(trim(coalesce(p_location_id, '')), ''),
    'notes', nullif(trim(coalesce(p_notes, '')), '')
  );

  select transactions.* into v_existing_tx
  from public.finance_transactions as transactions
  where transactions.request_id = p_request_id;
  if found then
    if v_existing_tx.document_type <> 'ADVANCE' then
      raise exception 'Request ID already belongs to another finance operation'
        using errcode = '23505';
    end if;
    if v_existing_tx.request_payload <> v_payload then
      raise exception 'Request ID was already used with different advance data'
        using errcode = '23505';
    end if;
    select lots.* into strict v_existing_lot
    from public.advance_lots as lots
    where lots.transaction_id = v_existing_tx.id;
    select movements.* into v_existing_move
    from public.product_stock_movements as movements
    where movements.transaction_id = v_existing_tx.id;
    return query select
      v_existing_lot.id,
      v_existing_lot.advance_ref,
      v_existing_tx.business_date,
      v_existing_lot.original_principal_kyat,
      v_existing_lot.original_quantity,
      v_existing_move.quantity_before,
      v_existing_move.quantity_after,
      true;
    return;
  end if;

  select farmers.* into v_farmer
  from public.farmers as farmers
  where farmers.customer_id = trim(coalesce(p_customer_id, ''))
    and farmers.active = true;
  if not found then
    raise exception 'Active farmer not found' using errcode = '23503';
  end if;
  if v_farmer.risk_level = 'BLACKLISTED' then
    raise exception 'Blacklisted farmer cannot receive a new advance'
      using errcode = '42501';
  end if;
  if v_type not in ('CASH', 'GOODS') then
    raise exception 'Advance type must be CASH or GOODS' using errcode = '22023';
  end if;
  if p_monthly_interest_rate is null
    or p_monthly_interest_rate < 0
    or p_monthly_interest_rate > 100
    or p_monthly_interest_rate <> round(p_monthly_interest_rate, 4) then
    raise exception 'Monthly interest rate must be from 0 to 100 with up to four decimals'
      using errcode = '22023';
  end if;
  if p_notes is not null and length(p_notes) > 500 then
    raise exception 'Advance notes cannot exceed 500 characters' using errcode = '22023';
  end if;

  v_before := null;
  v_after := null;
  if v_type = 'CASH' then
    if p_principal_kyat is null or p_principal_kyat <= 0 then
      raise exception 'Cash advance principal must be a positive whole kyat amount'
        using errcode = '22023';
    end if;
    v_principal := p_principal_kyat;
  else
    select products.* into v_product
    from public.products as products
    where products.product_id = trim(coalesce(p_product_id, ''))
      and products.active = true
    for update;
    if not found then
      raise exception 'Active product not found' using errcode = '23503';
    end if;
    select locations.* into v_location
    from public.stock_locations as locations
    where locations.location_id = trim(coalesce(p_location_id, ''))
      and locations.active = true;
    if not found then
      raise exception 'Active stock location not found' using errcode = '23503';
    end if;
    if p_quantity is null or p_quantity <= 0
      or p_quantity <> round(p_quantity, 3) then
      raise exception 'Goods quantity must be positive with up to three decimals'
        using errcode = '22023';
    end if;
    if v_product.whole_units_only and p_quantity <> trunc(p_quantity) then
      raise exception 'Product requires a whole-unit quantity' using errcode = '22023';
    end if;
    if p_unit_price_kyat is null or p_unit_price_kyat <= 0 then
      raise exception 'Goods unit price must be a positive whole kyat amount'
        using errcode = '22023';
    end if;
    if round(p_quantity * p_unit_price_kyat) > 9223372036854775807 then
      raise exception 'Advance principal is too large' using errcode = '22003';
    end if;
    v_principal := round(p_quantity * p_unit_price_kyat)::bigint;
    v_before := public.product_stock_quantity(v_product.product_id, v_location.location_id);
    if p_quantity > v_before then
      raise exception 'Insufficient product stock' using errcode = '22023';
    end if;
    v_after := v_before - p_quantity;
  end if;

  v_ref := public.next_finance_document_ref('AD', v_business_date);
  insert into public.finance_transactions (
    request_id, request_payload, document_ref, document_type, business_date,
    created_by
  ) values (
    p_request_id, v_payload, v_ref, 'ADVANCE', v_business_date, auth.uid()
  ) returning id into v_transaction_id;

  insert into public.advance_lots (
    transaction_id, advance_ref, customer_id, farmer_name_snapshot,
    advance_type, product_id, location_id, product_name_snapshot,
    unit_name_snapshot, whole_units_only, unit_price_kyat,
    original_quantity, remaining_quantity, original_principal_kyat,
    remaining_principal_kyat, monthly_interest_rate, issued_date, status,
    notes, created_by
  ) values (
    v_transaction_id, v_ref, v_farmer.customer_id, v_farmer.full_name,
    v_type,
    case when v_type = 'GOODS' then v_product.product_id else null end,
    case when v_type = 'GOODS' then v_location.location_id else null end,
    case when v_type = 'GOODS' then v_product.name else null end,
    case when v_type = 'GOODS' then v_product.unit_name else 'ကျပ်' end,
    case when v_type = 'GOODS' then v_product.whole_units_only else true end,
    case when v_type = 'GOODS' then p_unit_price_kyat else 1 end,
    case when v_type = 'GOODS' then p_quantity else null end,
    case when v_type = 'GOODS' then p_quantity else null end,
    v_principal, v_principal, p_monthly_interest_rate, v_business_date,
    'OPEN', nullif(trim(coalesce(p_notes, '')), ''), auth.uid()
  ) returning id into v_lot_id;

  if v_type = 'GOODS' then
    insert into public.product_stock_movements (
      transaction_id, movement_ref, business_date, product_id, location_id,
      product_name_snapshot, unit_name_snapshot, movement_type,
      quantity_delta, quantity_before, quantity_after, created_by
    ) values (
      v_transaction_id, v_ref, v_business_date, v_product.product_id,
      v_location.location_id, v_product.name, v_product.unit_name,
      'OUT_ADVANCE', -p_quantity, v_before, v_after, auth.uid()
    );
  else
    insert into public.cash_ledger_entries (
      transaction_id, document_ref, business_date, direction, amount_kyat,
      payment_method, category, label, principal_kyat, interest_kyat,
      created_by
    ) values (
      v_transaction_id, v_ref, v_business_date, 'OUT', v_principal,
      'CASH', 'ADVANCE', 'တောင်သူ စိုက်ထုတ်ငွေ · ' || v_farmer.full_name,
      v_principal, 0, auth.uid()
    );
  end if;

  insert into public.finance_audit_events (
    transaction_id, document_ref, action, payload, created_by
  ) values (
    v_transaction_id, v_ref, 'ADVANCE_ISSUED', jsonb_build_object(
      'customer_id', v_farmer.customer_id,
      'advance_type', v_type,
      'product_id', case when v_type = 'GOODS' then v_product.product_id else null end,
      'location_id', case when v_type = 'GOODS' then v_location.location_id else null end,
      'quantity', case when v_type = 'GOODS' then p_quantity else null end,
      'principal_kyat', v_principal,
      'monthly_interest_rate', p_monthly_interest_rate
    ), auth.uid()
  );

  return query select
    v_lot_id, v_ref, v_business_date, v_principal,
    case when v_type = 'GOODS' then p_quantity else null end,
    v_before, v_after, false;
end;
$$;

create or replace function public.repay_advance(
  p_request_id uuid,
  p_advance_lot_id uuid,
  p_principal_kyat bigint,
  p_quantity numeric,
  p_payment_method text,
  p_payment_reference text,
  p_notes text
)
returns table (
  repayment_id uuid,
  repayment_ref text,
  advance_ref text,
  payment_date date,
  elapsed_days integer,
  half_month_steps integer,
  principal_kyat bigint,
  interest_kyat bigint,
  total_received_kyat bigint,
  remaining_principal_kyat bigint,
  remaining_quantity numeric,
  idempotent boolean
)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_existing_tx public.finance_transactions%rowtype;
  v_existing_payment public.advance_repayments%rowtype;
  v_lot public.advance_lots%rowtype;
  v_method text := upper(trim(coalesce(p_payment_method, '')));
  v_business_date date := public.get_business_date();
  v_transaction_id uuid;
  v_ref text;
  v_payment_id uuid;
  v_days integer;
  v_steps integer;
  v_principal bigint;
  v_interest bigint;
  v_total bigint;
  v_quantity numeric(20, 3);
  v_remaining_principal bigint;
  v_remaining_quantity numeric(20, 3);
  v_status text;
  v_payload jsonb;
begin
  perform public.require_staff_roles(array['owner']);

  if p_request_id is null then
    raise exception 'Repayment request ID is required' using errcode = '22023';
  end if;
  v_payload := jsonb_build_object(
    'advance_lot_id', p_advance_lot_id,
    'principal_kyat', p_principal_kyat,
    'quantity', p_quantity,
    'payment_method', upper(trim(coalesce(p_payment_method, ''))),
    'payment_reference', nullif(trim(coalesce(p_payment_reference, '')), ''),
    'notes', nullif(trim(coalesce(p_notes, '')), '')
  );

  select transactions.* into v_existing_tx
  from public.finance_transactions as transactions
  where transactions.request_id = p_request_id;
  if found then
    if v_existing_tx.document_type <> 'ADVANCE_REPAYMENT' then
      raise exception 'Request ID already belongs to another finance operation'
        using errcode = '23505';
    end if;
    if v_existing_tx.request_payload <> v_payload then
      raise exception 'Request ID was already used with different repayment data'
        using errcode = '23505';
    end if;
    select payments.* into strict v_existing_payment
    from public.advance_repayments as payments
    where payments.transaction_id = v_existing_tx.id;
    select lots.* into strict v_lot
    from public.advance_lots as lots
    where lots.id = v_existing_payment.advance_lot_id;
    return query select
      v_existing_payment.id, v_existing_payment.repayment_ref,
      v_lot.advance_ref, v_existing_payment.payment_date,
      v_existing_payment.elapsed_days, v_existing_payment.half_month_steps,
      v_existing_payment.principal_kyat, v_existing_payment.interest_kyat,
      v_existing_payment.total_received_kyat,
      v_existing_payment.remaining_principal_kyat,
      v_existing_payment.remaining_quantity, true;
    return;
  end if;

  if p_advance_lot_id is null then
    raise exception 'Advance lot is required' using errcode = '22023';
  end if;
  select lots.* into v_lot
  from public.advance_lots as lots
  where lots.id = p_advance_lot_id
  for update;
  if not found then
    raise exception 'Advance lot not found' using errcode = '23503';
  end if;
  if v_lot.status = 'PAID' or v_lot.remaining_principal_kyat <= 0 then
    raise exception 'Advance lot is already paid' using errcode = '22023';
  end if;
  if v_business_date < v_lot.issued_date then
    raise exception 'Server business date is before advance issue date'
      using errcode = '22023';
  end if;
  if v_method not in ('CASH', 'BANK', 'MOBILE') then
    raise exception 'Payment method must be CASH, BANK or MOBILE'
      using errcode = '22023';
  end if;
  if v_method <> 'CASH'
    and length(trim(coalesce(p_payment_reference, ''))) not between 1 and 160 then
    raise exception 'Bank or mobile payment reference is required'
      using errcode = '22023';
  end if;
  if p_notes is not null and length(p_notes) > 500 then
    raise exception 'Repayment notes cannot exceed 500 characters'
      using errcode = '22023';
  end if;

  if v_lot.advance_type = 'GOODS' then
    if p_quantity is null or p_quantity <= 0
      or p_quantity <> round(p_quantity, 3) then
      raise exception 'Repayment quantity must be positive with up to three decimals'
        using errcode = '22023';
    end if;
    if v_lot.whole_units_only and p_quantity <> trunc(p_quantity) then
      raise exception 'Product requires a whole-unit repayment quantity'
        using errcode = '22023';
    end if;
    if p_quantity > v_lot.remaining_quantity then
      raise exception 'Repayment quantity exceeds the remaining quantity'
        using errcode = '22023';
    end if;
    v_quantity := p_quantity;
    if p_quantity = v_lot.remaining_quantity then
      v_principal := v_lot.remaining_principal_kyat;
      v_remaining_quantity := 0;
    else
      v_principal := round(p_quantity * v_lot.unit_price_kyat)::bigint;
      if v_principal <= 0 then
        raise exception 'Partial goods repayment is too small to represent one whole kyat of principal'
          using errcode = '22023';
      end if;
      if v_principal >= v_lot.remaining_principal_kyat then
        raise exception 'Partial goods repayment would exhaust principal before quantity; repay the full remaining quantity'
          using errcode = '22023';
      end if;
      v_remaining_quantity := v_lot.remaining_quantity - p_quantity;
    end if;
    if v_principal <= 0 or v_principal > v_lot.remaining_principal_kyat then
      raise exception 'Repayment principal exceeds the remaining principal'
        using errcode = '22023';
    end if;
  else
    if p_principal_kyat is null or p_principal_kyat <= 0
      or p_principal_kyat > v_lot.remaining_principal_kyat then
      raise exception 'Cash repayment principal must be positive and not exceed the remaining principal'
        using errcode = '22023';
    end if;
    v_principal := p_principal_kyat;
    v_quantity := null;
    v_remaining_quantity := null;
  end if;

  v_days := v_business_date - v_lot.issued_date;
  v_steps := case when v_days = 0 then 0 else (v_days + 14) / 15 end;
  v_interest := round(
    v_principal::numeric * v_lot.monthly_interest_rate / 100
      * v_steps / 2
  )::bigint;
  v_total := v_principal + v_interest;
  v_remaining_principal := v_lot.remaining_principal_kyat - v_principal;
  if v_lot.advance_type = 'GOODS'
    and ((v_remaining_quantity = 0) <> (v_remaining_principal = 0)) then
    raise exception 'Goods repayment principal and quantity would close inconsistently'
      using errcode = '23514';
  end if;
  v_status := case
    when v_lot.advance_type = 'GOODS'
      and v_remaining_quantity = 0 and v_remaining_principal = 0 then 'PAID'
    when v_lot.advance_type = 'GOODS' then 'PARTIAL'
    when v_remaining_principal = 0 then 'PAID'
    when v_remaining_principal < v_lot.original_principal_kyat then 'PARTIAL'
    else 'OPEN'
  end;

  v_ref := public.next_finance_document_ref('RP', v_business_date);
  insert into public.finance_transactions (
    request_id, request_payload, document_ref, document_type, business_date,
    created_by
  ) values (
    p_request_id, v_payload, v_ref, 'ADVANCE_REPAYMENT', v_business_date,
    auth.uid()
  ) returning id into v_transaction_id;

  perform set_config('app.finance_post', 'on', true);
  update public.advance_lots as lots set
    remaining_principal_kyat = v_remaining_principal,
    remaining_quantity = v_remaining_quantity,
    status = v_status,
    updated_at = now()
  where lots.id = v_lot.id;

  insert into public.advance_repayments (
    transaction_id, repayment_ref, advance_lot_id, payment_date,
    quantity_before, selected_quantity, principal_before_kyat,
    principal_kyat, interest_kyat, total_received_kyat,
    elapsed_days, half_month_steps, monthly_interest_rate_snapshot,
    payment_method, payment_reference, notes, remaining_quantity,
    remaining_principal_kyat, created_by
  ) values (
    v_transaction_id, v_ref, v_lot.id, v_business_date,
    v_lot.remaining_quantity, v_quantity, v_lot.remaining_principal_kyat,
    v_principal, v_interest, v_total, v_days, v_steps,
    v_lot.monthly_interest_rate, v_method,
    nullif(trim(coalesce(p_payment_reference, '')), ''),
    nullif(trim(coalesce(p_notes, '')), ''),
    v_remaining_quantity, v_remaining_principal, auth.uid()
  ) returning id into v_payment_id;

  insert into public.cash_ledger_entries (
    transaction_id, document_ref, business_date, direction, amount_kyat,
    payment_method, category, label, principal_kyat, interest_kyat,
    created_by
  ) values (
    v_transaction_id, v_ref, v_business_date, 'IN', v_total, v_method,
    'DEBT_REPAYMENT', 'စိုက်ထုတ်ဆပ်ငွေ · ' || v_lot.farmer_name_snapshot
      || ' · ' || coalesce(v_lot.product_name_snapshot, 'ငွေသား'),
    v_principal, v_interest, auth.uid()
  );

  insert into public.finance_audit_events (
    transaction_id, document_ref, action, payload, created_by
  ) values (
    v_transaction_id, v_ref, 'ADVANCE_REPAID', jsonb_build_object(
      'advance_lot_id', v_lot.id,
      'advance_ref', v_lot.advance_ref,
      'quantity', v_quantity,
      'principal_kyat', v_principal,
      'interest_kyat', v_interest,
      'elapsed_days', v_days,
      'half_month_steps', v_steps,
      'remaining_principal_kyat', v_remaining_principal,
      'remaining_quantity', v_remaining_quantity
    ), auth.uid()
  );

  return query select
    v_payment_id, v_ref, v_lot.advance_ref, v_business_date,
    v_days, v_steps, v_principal, v_interest, v_total,
    v_remaining_principal, v_remaining_quantity, false;
end;
$$;

create or replace function public.record_product_sale(
  p_request_id uuid,
  p_customer_type text,
  p_customer_id text,
  p_buyer_name text,
  p_product_id text,
  p_location_id text,
  p_quantity numeric,
  p_unit_price_kyat bigint,
  p_payment_method text,
  p_payment_reference text,
  p_notes text
)
returns table (
  sale_id uuid,
  sale_ref text,
  business_date date,
  total_kyat bigint,
  stock_before numeric,
  stock_after numeric,
  idempotent boolean
)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_existing_tx public.finance_transactions%rowtype;
  v_existing_sale public.finance_product_sales%rowtype;
  v_product public.products%rowtype;
  v_location public.stock_locations%rowtype;
  v_farmer public.farmers%rowtype;
  v_customer_type text := upper(trim(coalesce(p_customer_type, '')));
  v_method text := upper(trim(coalesce(p_payment_method, '')));
  v_buyer_name text := trim(coalesce(p_buyer_name, ''));
  v_customer_id text := nullif(trim(coalesce(p_customer_id, '')), '');
  v_business_date date := public.get_business_date();
  v_transaction_id uuid;
  v_ref text;
  v_sale_id uuid;
  v_total bigint;
  v_before numeric(20, 3);
  v_after numeric(20, 3);
  v_payload jsonb;
begin
  perform public.require_staff_roles(array['owner']);
  if p_request_id is null then
    raise exception 'Product-sale request ID is required' using errcode = '22023';
  end if;

  v_payload := jsonb_build_object(
    'customer_type', upper(trim(coalesce(p_customer_type, ''))),
    'customer_id', nullif(trim(coalesce(p_customer_id, '')), ''),
    'buyer_name', trim(coalesce(p_buyer_name, '')),
    'product_id', trim(coalesce(p_product_id, '')),
    'location_id', trim(coalesce(p_location_id, '')),
    'quantity', p_quantity,
    'unit_price_kyat', p_unit_price_kyat,
    'payment_method', upper(trim(coalesce(p_payment_method, ''))),
    'payment_reference', nullif(trim(coalesce(p_payment_reference, '')), ''),
    'notes', nullif(trim(coalesce(p_notes, '')), '')
  );

  select transactions.* into v_existing_tx
  from public.finance_transactions as transactions
  where transactions.request_id = p_request_id;
  if found then
    if v_existing_tx.document_type <> 'PRODUCT_SALE' then
      raise exception 'Request ID already belongs to another finance operation'
        using errcode = '23505';
    end if;
    if v_existing_tx.request_payload <> v_payload then
      raise exception 'Request ID was already used with different product-sale data'
        using errcode = '23505';
    end if;
    select sales.* into strict v_existing_sale
    from public.finance_product_sales as sales
    where sales.transaction_id = v_existing_tx.id;
    return query select
      v_existing_sale.id, v_existing_sale.sale_ref,
      v_existing_sale.business_date, v_existing_sale.total_kyat,
      v_existing_sale.stock_before, v_existing_sale.stock_after, true;
    return;
  end if;

  if v_customer_type not in ('WALK_IN', 'FARMER') then
    raise exception 'Customer type must be WALK_IN or FARMER' using errcode = '22023';
  end if;
  if v_customer_type = 'FARMER' then
    if v_customer_id is null then
      raise exception 'Farmer customer ID is required' using errcode = '22023';
    end if;
    select farmers.* into v_farmer
    from public.farmers as farmers
    where farmers.customer_id = v_customer_id and farmers.active = true;
    if not found then
      raise exception 'Active farmer not found' using errcode = '23503';
    end if;
    v_buyer_name := v_farmer.full_name;
  else
    v_customer_id := null;
    if length(v_buyer_name) not between 1 and 160 then
      raise exception 'Buyer name must contain 1 to 160 characters'
        using errcode = '22023';
    end if;
  end if;
  if v_method not in ('CASH', 'BANK', 'MOBILE') then
    raise exception 'Payment method must be CASH, BANK or MOBILE'
      using errcode = '22023';
  end if;
  if v_method <> 'CASH'
    and length(trim(coalesce(p_payment_reference, ''))) not between 1 and 160 then
    raise exception 'Bank or mobile payment reference is required'
      using errcode = '22023';
  end if;
  if p_notes is not null and length(p_notes) > 500 then
    raise exception 'Product-sale notes cannot exceed 500 characters'
      using errcode = '22023';
  end if;

  select products.* into v_product
  from public.products as products
  where products.product_id = trim(coalesce(p_product_id, ''))
    and products.active = true
  for update;
  if not found then
    raise exception 'Active product not found' using errcode = '23503';
  end if;
  select locations.* into v_location
  from public.stock_locations as locations
  where locations.location_id = trim(coalesce(p_location_id, ''))
    and locations.active = true;
  if not found then
    raise exception 'Active stock location not found' using errcode = '23503';
  end if;
  if p_quantity is null or p_quantity <= 0
    or p_quantity <> round(p_quantity, 3) then
    raise exception 'Sale quantity must be positive with up to three decimals'
      using errcode = '22023';
  end if;
  if v_product.whole_units_only and p_quantity <> trunc(p_quantity) then
    raise exception 'Product requires a whole-unit quantity' using errcode = '22023';
  end if;
  if p_unit_price_kyat is null or p_unit_price_kyat <= 0 then
    raise exception 'Sale unit price must be a positive whole kyat amount'
      using errcode = '22023';
  end if;
  if round(p_quantity * p_unit_price_kyat) > 9223372036854775807 then
    raise exception 'Product-sale total is too large' using errcode = '22003';
  end if;

  v_total := round(p_quantity * p_unit_price_kyat)::bigint;
  v_before := public.product_stock_quantity(v_product.product_id, v_location.location_id);
  if p_quantity > v_before then
    raise exception 'Insufficient product stock' using errcode = '22023';
  end if;
  v_after := v_before - p_quantity;

  v_ref := public.next_finance_document_ref('GS', v_business_date);
  insert into public.finance_transactions (
    request_id, request_payload, document_ref, document_type, business_date,
    created_by
  ) values (
    p_request_id, v_payload, v_ref, 'PRODUCT_SALE', v_business_date, auth.uid()
  ) returning id into v_transaction_id;

  insert into public.finance_product_sales (
    transaction_id, sale_ref, business_date, customer_type, customer_id,
    buyer_name, product_id, location_id, product_name_snapshot,
    unit_name_snapshot, quantity, unit_price_kyat, total_kyat,
    payment_method, payment_reference, notes, stock_before, stock_after,
    created_by
  ) values (
    v_transaction_id, v_ref, v_business_date, v_customer_type, v_customer_id,
    v_buyer_name, v_product.product_id, v_location.location_id,
    v_product.name, v_product.unit_name, p_quantity, p_unit_price_kyat,
    v_total, v_method, nullif(trim(coalesce(p_payment_reference, '')), ''),
    nullif(trim(coalesce(p_notes, '')), ''), v_before, v_after, auth.uid()
  ) returning id into v_sale_id;

  insert into public.product_stock_movements (
    transaction_id, movement_ref, business_date, product_id, location_id,
    product_name_snapshot, unit_name_snapshot, movement_type,
    quantity_delta, quantity_before, quantity_after, created_by
  ) values (
    v_transaction_id, v_ref, v_business_date, v_product.product_id,
    v_location.location_id, v_product.name, v_product.unit_name,
    'OUT_SALE', -p_quantity, v_before, v_after, auth.uid()
  );

  insert into public.cash_ledger_entries (
    transaction_id, document_ref, business_date, direction, amount_kyat,
    payment_method, category, label, principal_kyat, interest_kyat,
    created_by
  ) values (
    v_transaction_id, v_ref, v_business_date, 'IN', v_total, v_method,
    'PRODUCT_SALE', 'ကုန်ပစ္စည်းလက်ငင်းအရောင်း · ' || v_buyer_name
      || ' · ' || v_product.name, 0, 0, auth.uid()
  );

  insert into public.finance_audit_events (
    transaction_id, document_ref, action, payload, created_by
  ) values (
    v_transaction_id, v_ref, 'PRODUCT_SOLD', jsonb_build_object(
      'customer_type', v_customer_type,
      'customer_id', v_customer_id,
      'buyer_name', v_buyer_name,
      'product_id', v_product.product_id,
      'location_id', v_location.location_id,
      'quantity', p_quantity,
      'unit_price_kyat', p_unit_price_kyat,
      'total_kyat', v_total,
      'stock_before', v_before,
      'stock_after', v_after
    ), auth.uid()
  );

  return query select
    v_sale_id, v_ref, v_business_date, v_total, v_before, v_after, false;
end;
$$;

create or replace function public.record_stock_receipt(
  p_request_id uuid,
  p_supplier_name text,
  p_product_id text,
  p_location_id text,
  p_quantity numeric,
  p_unit_cost_kyat bigint,
  p_payment_method text,
  p_payment_reference text,
  p_notes text
)
returns table (
  receipt_id uuid,
  receipt_ref text,
  business_date date,
  total_kyat bigint,
  stock_before numeric,
  stock_after numeric,
  idempotent boolean
)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_existing_tx public.finance_transactions%rowtype;
  v_existing_receipt public.finance_stock_receipts%rowtype;
  v_product public.products%rowtype;
  v_location public.stock_locations%rowtype;
  v_supplier text := trim(coalesce(p_supplier_name, ''));
  v_method text := upper(trim(coalesce(p_payment_method, '')));
  v_business_date date := public.get_business_date();
  v_transaction_id uuid;
  v_ref text;
  v_receipt_id uuid;
  v_total bigint;
  v_before numeric(20, 3);
  v_after numeric(20, 3);
  v_payload jsonb;
begin
  perform public.require_staff_roles(array['owner']);
  if p_request_id is null then
    raise exception 'Stock-receipt request ID is required' using errcode = '22023';
  end if;

  v_payload := jsonb_build_object(
    'supplier_name', trim(coalesce(p_supplier_name, '')),
    'product_id', trim(coalesce(p_product_id, '')),
    'location_id', trim(coalesce(p_location_id, '')),
    'quantity', p_quantity,
    'unit_cost_kyat', p_unit_cost_kyat,
    'payment_method', upper(trim(coalesce(p_payment_method, ''))),
    'payment_reference', nullif(trim(coalesce(p_payment_reference, '')), ''),
    'notes', nullif(trim(coalesce(p_notes, '')), '')
  );

  select transactions.* into v_existing_tx
  from public.finance_transactions as transactions
  where transactions.request_id = p_request_id;
  if found then
    if v_existing_tx.document_type <> 'STOCK_RECEIPT' then
      raise exception 'Request ID already belongs to another finance operation'
        using errcode = '23505';
    end if;
    if v_existing_tx.request_payload <> v_payload then
      raise exception 'Request ID was already used with different stock-receipt data'
        using errcode = '23505';
    end if;
    select receipts.* into strict v_existing_receipt
    from public.finance_stock_receipts as receipts
    where receipts.transaction_id = v_existing_tx.id;
    return query select
      v_existing_receipt.id, v_existing_receipt.receipt_ref,
      v_existing_receipt.business_date, v_existing_receipt.total_kyat,
      v_existing_receipt.stock_before, v_existing_receipt.stock_after, true;
    return;
  end if;

  if length(v_supplier) not between 1 and 160 then
    raise exception 'Supplier name must contain 1 to 160 characters'
      using errcode = '22023';
  end if;
  if v_method not in ('CASH', 'BANK', 'MOBILE') then
    raise exception 'Payment method must be CASH, BANK or MOBILE'
      using errcode = '22023';
  end if;
  if v_method <> 'CASH'
    and length(trim(coalesce(p_payment_reference, ''))) not between 1 and 160 then
    raise exception 'Bank or mobile payment reference is required'
      using errcode = '22023';
  end if;
  if p_notes is not null and length(p_notes) > 500 then
    raise exception 'Stock-receipt notes cannot exceed 500 characters'
      using errcode = '22023';
  end if;

  select products.* into v_product
  from public.products as products
  where products.product_id = trim(coalesce(p_product_id, ''))
    and products.active = true
  for update;
  if not found then
    raise exception 'Active product not found' using errcode = '23503';
  end if;
  select locations.* into v_location
  from public.stock_locations as locations
  where locations.location_id = trim(coalesce(p_location_id, ''))
    and locations.active = true;
  if not found then
    raise exception 'Active stock location not found' using errcode = '23503';
  end if;
  if p_quantity is null or p_quantity <= 0
    or p_quantity <> round(p_quantity, 3) then
    raise exception 'Stock-receipt quantity must be positive with up to three decimals'
      using errcode = '22023';
  end if;
  if v_product.whole_units_only and p_quantity <> trunc(p_quantity) then
    raise exception 'Product requires a whole-unit quantity' using errcode = '22023';
  end if;
  if p_unit_cost_kyat is null or p_unit_cost_kyat <= 0 then
    raise exception 'Stock-receipt unit cost must be a positive whole kyat amount'
      using errcode = '22023';
  end if;
  if round(p_quantity * p_unit_cost_kyat) > 9223372036854775807 then
    raise exception 'Stock-receipt total is too large' using errcode = '22003';
  end if;

  v_total := round(p_quantity * p_unit_cost_kyat)::bigint;
  v_before := public.product_stock_quantity(v_product.product_id, v_location.location_id);
  v_after := v_before + p_quantity;

  v_ref := public.next_finance_document_ref('ST', v_business_date);
  insert into public.finance_transactions (
    request_id, request_payload, document_ref, document_type, business_date,
    created_by
  ) values (
    p_request_id, v_payload, v_ref, 'STOCK_RECEIPT', v_business_date, auth.uid()
  ) returning id into v_transaction_id;

  insert into public.finance_stock_receipts (
    transaction_id, receipt_ref, business_date, supplier_name, product_id,
    location_id, product_name_snapshot, unit_name_snapshot, whole_units_only,
    quantity, unit_cost_kyat, total_kyat, payment_method, payment_reference,
    notes, stock_before, stock_after, created_by
  ) values (
    v_transaction_id, v_ref, v_business_date, v_supplier, v_product.product_id,
    v_location.location_id, v_product.name, v_product.unit_name,
    v_product.whole_units_only, p_quantity, p_unit_cost_kyat, v_total,
    v_method, nullif(trim(coalesce(p_payment_reference, '')), ''),
    nullif(trim(coalesce(p_notes, '')), ''), v_before, v_after, auth.uid()
  ) returning id into v_receipt_id;

  insert into public.product_stock_movements (
    transaction_id, movement_ref, business_date, product_id, location_id,
    product_name_snapshot, unit_name_snapshot, movement_type,
    quantity_delta, quantity_before, quantity_after, created_by
  ) values (
    v_transaction_id, v_ref, v_business_date, v_product.product_id,
    v_location.location_id, v_product.name, v_product.unit_name,
    'IN_PURCHASE', p_quantity, v_before, v_after, auth.uid()
  );

  insert into public.cash_ledger_entries (
    transaction_id, document_ref, business_date, direction, amount_kyat,
    payment_method, category, label, principal_kyat, interest_kyat,
    created_by
  ) values (
    v_transaction_id, v_ref, v_business_date, 'OUT', v_total, v_method,
    'STOCK_PURCHASE', 'ကုန်ပစ္စည်းဝယ်သွင်း · ' || v_supplier
      || ' · ' || v_product.name, 0, 0, auth.uid()
  );

  insert into public.finance_audit_events (
    transaction_id, document_ref, action, payload, created_by
  ) values (
    v_transaction_id, v_ref, 'STOCK_RECEIVED', jsonb_build_object(
      'supplier_name', v_supplier,
      'product_id', v_product.product_id,
      'location_id', v_location.location_id,
      'quantity', p_quantity,
      'unit_cost_kyat', p_unit_cost_kyat,
      'total_kyat', v_total,
      'stock_before', v_before,
      'stock_after', v_after
    ), auth.uid()
  );

  return query select
    v_receipt_id, v_ref, v_business_date, v_total, v_before, v_after, false;
end;
$$;

create or replace function public.record_business_expense(
  p_request_id uuid,
  p_category text,
  p_amount_kyat bigint,
  p_payment_method text,
  p_payment_reference text,
  p_notes text
)
returns table (
  expense_id uuid,
  expense_ref text,
  business_date date,
  amount_kyat bigint,
  idempotent boolean
)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_existing_tx public.finance_transactions%rowtype;
  v_existing_expense public.business_expenses%rowtype;
  v_method text := upper(trim(coalesce(p_payment_method, '')));
  v_category text := trim(coalesce(p_category, ''));
  v_business_date date := public.get_business_date();
  v_transaction_id uuid;
  v_ref text;
  v_expense_id uuid;
  v_payload jsonb;
begin
  perform public.require_staff_roles(array['owner']);
  if p_request_id is null then
    raise exception 'Expense request ID is required' using errcode = '22023';
  end if;

  v_payload := jsonb_build_object(
    'category', trim(coalesce(p_category, '')),
    'amount_kyat', p_amount_kyat,
    'payment_method', upper(trim(coalesce(p_payment_method, ''))),
    'payment_reference', nullif(trim(coalesce(p_payment_reference, '')), ''),
    'notes', nullif(trim(coalesce(p_notes, '')), '')
  );

  select transactions.* into v_existing_tx
  from public.finance_transactions as transactions
  where transactions.request_id = p_request_id;
  if found then
    if v_existing_tx.document_type <> 'EXPENSE' then
      raise exception 'Request ID already belongs to another finance operation'
        using errcode = '23505';
    end if;
    if v_existing_tx.request_payload <> v_payload then
      raise exception 'Request ID was already used with different expense data'
        using errcode = '23505';
    end if;
    select expenses.* into strict v_existing_expense
    from public.business_expenses as expenses
    where expenses.transaction_id = v_existing_tx.id;
    return query select
      v_existing_expense.id, v_existing_expense.expense_ref,
      v_existing_expense.business_date, v_existing_expense.amount_kyat, true;
    return;
  end if;

  if length(v_category) not between 1 and 100 then
    raise exception 'Expense category must contain 1 to 100 characters'
      using errcode = '22023';
  end if;
  if p_amount_kyat is null or p_amount_kyat <= 0 then
    raise exception 'Expense must be a positive whole kyat amount'
      using errcode = '22023';
  end if;
  if v_method not in ('CASH', 'BANK', 'MOBILE') then
    raise exception 'Payment method must be CASH, BANK or MOBILE'
      using errcode = '22023';
  end if;
  if v_method <> 'CASH'
    and length(trim(coalesce(p_payment_reference, ''))) not between 1 and 160 then
    raise exception 'Bank or mobile payment reference is required'
      using errcode = '22023';
  end if;
  if p_notes is not null and length(p_notes) > 500 then
    raise exception 'Expense notes cannot exceed 500 characters'
      using errcode = '22023';
  end if;

  v_ref := public.next_finance_document_ref('EX', v_business_date);
  insert into public.finance_transactions (
    request_id, request_payload, document_ref, document_type, business_date,
    created_by
  ) values (
    p_request_id, v_payload, v_ref, 'EXPENSE', v_business_date, auth.uid()
  ) returning id into v_transaction_id;

  insert into public.business_expenses (
    transaction_id, expense_ref, business_date, category, amount_kyat,
    payment_method, payment_reference, notes, created_by
  ) values (
    v_transaction_id, v_ref, v_business_date, v_category, p_amount_kyat,
    v_method, nullif(trim(coalesce(p_payment_reference, '')), ''),
    nullif(trim(coalesce(p_notes, '')), ''), auth.uid()
  ) returning id into v_expense_id;

  insert into public.cash_ledger_entries (
    transaction_id, document_ref, business_date, direction, amount_kyat,
    payment_method, category, label, principal_kyat, interest_kyat,
    created_by
  ) values (
    v_transaction_id, v_ref, v_business_date, 'OUT', p_amount_kyat,
    v_method, 'EXPENSE', v_category || case
      when nullif(trim(coalesce(p_notes, '')), '') is null then ''
      else ' · ' || trim(p_notes)
    end, 0, 0, auth.uid()
  );

  insert into public.finance_audit_events (
    transaction_id, document_ref, action, payload, created_by
  ) values (
    v_transaction_id, v_ref, 'EXPENSE_RECORDED', jsonb_build_object(
      'category', v_category,
      'amount_kyat', p_amount_kyat,
      'payment_method', v_method
    ), auth.uid()
  );

  return query select
    v_expense_id, v_ref, v_business_date, p_amount_kyat, false;
end;
$$;

-- ---------------------------------------------------------------------------
-- Opening farmer debts become individually repayable advance lots
-- ---------------------------------------------------------------------------

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
begin
  if new.entry_type <> 'FARMER_DEBT' then
    return new;
  end if;
  select farmers.full_name into strict v_farmer_name
  from public.farmers as farmers
  where farmers.customer_id = new.customer_id;
  select imports.created_by, imports.import_ref
    into strict v_created_by, v_import_ref
  from public.opening_balance_imports as imports
  where imports.id = new.import_id;

  insert into public.advance_lots (
    opening_balance_entry_id, advance_ref, customer_id,
    farmer_name_snapshot, advance_type, product_name_snapshot,
    unit_name_snapshot, whole_units_only, unit_price_kyat,
    original_quantity, remaining_quantity, original_principal_kyat,
    remaining_principal_kyat, monthly_interest_rate, issued_date, status,
    notes, created_by
  ) values (
    new.id, 'AD-OB-' || lpad(new.id::text, 8, '0'), new.customer_id,
    v_farmer_name, 'CASH', null, 'ကျပ်', true, 1, null, null,
    new.principal_kyat, new.principal_kyat, new.monthly_interest_rate,
    new.opening_date, 'OPEN', concat_ws(' · ', 'Opening Balance', v_import_ref, new.notes),
    v_created_by
  ) on conflict (opening_balance_entry_id) do nothing;

  return new;
end;
$$;

drop trigger if exists opening_balance_entry_create_advance_lot
  on public.opening_balance_entries;
create trigger opening_balance_entry_create_advance_lot
after insert on public.opening_balance_entries
for each row execute function public.create_opening_advance_lot();

insert into public.advance_lots (
  opening_balance_entry_id, advance_ref, customer_id,
  farmer_name_snapshot, advance_type, product_name_snapshot,
  unit_name_snapshot, whole_units_only, unit_price_kyat,
  original_quantity, remaining_quantity, original_principal_kyat,
  remaining_principal_kyat, monthly_interest_rate, issued_date, status,
  notes, created_by
)
select
  entries.id,
  'AD-OB-' || lpad(entries.id::text, 8, '0'),
  entries.customer_id,
  farmers.full_name,
  'CASH', null, 'ကျပ်', true, 1, null, null,
  entries.principal_kyat,
  entries.principal_kyat,
  entries.monthly_interest_rate,
  entries.opening_date,
  'OPEN',
  concat_ws(' · ', 'Opening Balance', imports.import_ref, entries.notes),
  imports.created_by
from public.opening_balance_entries as entries
join public.opening_balance_imports as imports on imports.id = entries.import_id
join public.farmers as farmers on farmers.customer_id = entries.customer_id
where entries.entry_type = 'FARMER_DEBT'
on conflict (opening_balance_entry_id) do nothing;

-- ---------------------------------------------------------------------------
-- Immutability, RLS, grants and realtime
-- ---------------------------------------------------------------------------

create or replace function public.prevent_finance_ledger_mutation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  raise exception 'Finance ledger is append-only' using errcode = '42501';
end;
$$;

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
  raise exception 'Advance lots can only change through the repayment workflow'
    using errcode = '42501';
end;
$$;

drop trigger if exists advance_lots_guard_update_delete on public.advance_lots;
create trigger advance_lots_guard_update_delete
before update or delete on public.advance_lots
for each row execute function public.guard_advance_lot_mutation();

drop trigger if exists advance_lots_prevent_truncate on public.advance_lots;
create trigger advance_lots_prevent_truncate
before truncate on public.advance_lots
for each statement execute function public.guard_advance_lot_mutation();

do $$
declare
  v_table text;
begin
  foreach v_table in array array[
    'finance_transactions', 'advance_repayments', 'product_stock_movements',
    'finance_product_sales', 'finance_stock_receipts', 'business_expenses',
    'cash_ledger_entries', 'finance_audit_events'
  ]
  loop
    execute format('drop trigger if exists %I on public.%I',
      v_table || '_prevent_update_delete', v_table);
    execute format(
      'create trigger %I before update or delete on public.%I for each row execute function public.prevent_finance_ledger_mutation()',
      v_table || '_prevent_update_delete', v_table
    );
    execute format('drop trigger if exists %I on public.%I',
      v_table || '_prevent_truncate', v_table);
    execute format(
      'create trigger %I before truncate on public.%I for each statement execute function public.prevent_finance_ledger_mutation()',
      v_table || '_prevent_truncate', v_table
    );
  end loop;
end;
$$;

do $$
declare
  v_table text;
begin
  foreach v_table in array array[
    'finance_document_counters', 'finance_transactions', 'advance_lots',
    'advance_repayments', 'product_stock_movements', 'finance_product_sales',
    'finance_stock_receipts', 'business_expenses', 'cash_ledger_entries',
    'finance_audit_events'
  ]
  loop
    execute format('alter table public.%I enable row level security', v_table);
    execute format('alter table public.%I force row level security', v_table);
    execute format('revoke all on table public.%I from anon, authenticated', v_table);
    execute format('grant all on table public.%I to service_role', v_table);
  end loop;
end;
$$;

grant select on table public.finance_transactions to authenticated;
grant select on table public.advance_lots to authenticated;
grant select on table public.advance_repayments to authenticated;
grant select on table public.product_stock_movements to authenticated;
grant select on table public.finance_product_sales to authenticated;
grant select on table public.finance_stock_receipts to authenticated;
grant select on table public.business_expenses to authenticated;
grant select on table public.cash_ledger_entries to authenticated;
grant select on table public.finance_audit_events to authenticated;

revoke all on sequence public.finance_audit_events_id_seq from anon, authenticated;
grant all on sequence public.finance_audit_events_id_seq to service_role;

drop policy if exists "Owner can read finance transactions"
  on public.finance_transactions;
create policy "Owner can read finance transactions"
on public.finance_transactions for select to authenticated
using (public.current_staff_has_role(array['owner']));

drop policy if exists "Owner can read advance lots" on public.advance_lots;
create policy "Owner can read advance lots"
on public.advance_lots for select to authenticated
using (public.current_staff_has_role(array['owner']));

drop policy if exists "Owner can read advance repayments"
  on public.advance_repayments;
create policy "Owner can read advance repayments"
on public.advance_repayments for select to authenticated
using (public.current_staff_has_role(array['owner']));

drop policy if exists "Owner can read product stock movements"
  on public.product_stock_movements;
create policy "Owner can read product stock movements"
on public.product_stock_movements for select to authenticated
using (public.current_staff_has_role(array['owner']));

drop policy if exists "Owner can read finance product sales"
  on public.finance_product_sales;
create policy "Owner can read finance product sales"
on public.finance_product_sales for select to authenticated
using (public.current_staff_has_role(array['owner']));

drop policy if exists "Owner can read finance stock receipts"
  on public.finance_stock_receipts;
create policy "Owner can read finance stock receipts"
on public.finance_stock_receipts for select to authenticated
using (public.current_staff_has_role(array['owner']));

drop policy if exists "Owner can read business expenses"
  on public.business_expenses;
create policy "Owner can read business expenses"
on public.business_expenses for select to authenticated
using (public.current_staff_has_role(array['owner']));

drop policy if exists "Owner can read cash ledger" on public.cash_ledger_entries;
create policy "Owner can read cash ledger"
on public.cash_ledger_entries for select to authenticated
using (public.current_staff_has_role(array['owner']));

drop policy if exists "Owner can read finance audit" on public.finance_audit_events;
create policy "Owner can read finance audit"
on public.finance_audit_events for select to authenticated
using (public.current_staff_has_role(array['owner']));

revoke all on function public.next_finance_document_ref(text, date)
  from public, anon, authenticated;
revoke all on function public.product_stock_quantity(text, text)
  from public, anon, authenticated;
revoke all on function public.create_opening_advance_lot()
  from public, anon, authenticated;
revoke all on function public.prevent_finance_ledger_mutation()
  from public, anon, authenticated;
revoke all on function public.guard_advance_lot_mutation()
  from public, anon, authenticated;
grant execute on function public.next_finance_document_ref(text, date) to service_role;
grant execute on function public.product_stock_quantity(text, text) to service_role;
grant execute on function public.create_opening_advance_lot() to service_role;
grant execute on function public.prevent_finance_ledger_mutation() to service_role;
grant execute on function public.guard_advance_lot_mutation() to service_role;

revoke all on function public.get_product_stock_balances()
  from public, anon, authenticated;
revoke all on function public.get_farmer_debt_balances()
  from public, anon, authenticated;
revoke all on function public.get_daily_cash_flow()
  from public, anon, authenticated;
revoke all on function public.issue_advance(
  uuid, text, text, bigint, numeric, text, numeric, bigint, text, text
) from public, anon, authenticated;
revoke all on function public.repay_advance(
  uuid, uuid, bigint, numeric, text, text, text
) from public, anon, authenticated;
revoke all on function public.record_product_sale(
  uuid, text, text, text, text, text, numeric, bigint, text, text, text
) from public, anon, authenticated;
revoke all on function public.record_stock_receipt(
  uuid, text, text, text, numeric, bigint, text, text, text
) from public, anon, authenticated;
revoke all on function public.record_business_expense(
  uuid, text, bigint, text, text, text
) from public, anon, authenticated;

grant execute on function public.get_product_stock_balances()
  to authenticated, service_role;
grant execute on function public.get_farmer_debt_balances()
  to authenticated, service_role;
grant execute on function public.get_daily_cash_flow()
  to authenticated, service_role;
grant execute on function public.issue_advance(
  uuid, text, text, bigint, numeric, text, numeric, bigint, text, text
) to authenticated, service_role;
grant execute on function public.repay_advance(
  uuid, uuid, bigint, numeric, text, text, text
) to authenticated, service_role;
grant execute on function public.record_product_sale(
  uuid, text, text, text, text, text, numeric, bigint, text, text, text
) to authenticated, service_role;
grant execute on function public.record_stock_receipt(
  uuid, text, text, text, numeric, bigint, text, text, text
) to authenticated, service_role;
grant execute on function public.record_business_expense(
  uuid, text, bigint, text, text, text
) to authenticated, service_role;

alter table public.advance_lots replica identity full;
alter table public.advance_repayments replica identity full;
alter table public.product_stock_movements replica identity full;
alter table public.finance_product_sales replica identity full;
alter table public.finance_stock_receipts replica identity full;
alter table public.business_expenses replica identity full;
alter table public.cash_ledger_entries replica identity full;

do $$
declare
  v_table text;
begin
  foreach v_table in array array[
    'advance_lots', 'advance_repayments', 'product_stock_movements',
    'finance_product_sales', 'finance_stock_receipts', 'business_expenses',
    'cash_ledger_entries'
  ]
  loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', v_table);
    exception
      when duplicate_object then null;
    end;
  end loop;
end;
$$;
