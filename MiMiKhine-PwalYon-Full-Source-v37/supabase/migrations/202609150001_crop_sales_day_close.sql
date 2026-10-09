-- Mi Mi Khine Pwal Yon: authoritative crop settlement, owned crop stock,
-- wholesale crop sale, and immutable business-day close.
--
-- The weighing receipt remains the physical source.  Bean settlement prices
-- only the sale-reserved part of an immutable intake allocation.  Chili is
-- priced per bag from the immutable submitted bag rows.  Every financial and
-- stock effect is posted atomically under one idempotent request ID.

begin;

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- Extend the common finance envelope without weakening the earlier ledgers.
-- ---------------------------------------------------------------------------

alter table public.finance_document_counters
  drop constraint if exists finance_document_counter_prefix_valid;
alter table public.finance_document_counters
  add constraint finance_document_counter_prefix_valid check (
    prefix in ('AD', 'RP', 'GS', 'ST', 'EX', 'CS', 'SL', 'DC')
  );

alter table public.finance_transactions
  drop constraint if exists finance_transaction_type_valid;
alter table public.finance_transactions
  add constraint finance_transaction_type_valid check (
    document_type in (
      'ADVANCE', 'ADVANCE_REPAYMENT', 'PRODUCT_SALE', 'STOCK_RECEIPT',
      'EXPENSE', 'CROP_SETTLEMENT', 'CROP_SALE', 'DAY_CLOSE'
    )
  );
alter table public.finance_transactions
  drop constraint if exists finance_transaction_ref_valid;
alter table public.finance_transactions
  add constraint finance_transaction_ref_valid check (
    document_ref ~ '^(AD|RP|GS|ST|EX|CS|SL|DC)-[0-9]{8}-[0-9]{6,}$'
  );

alter table public.cash_ledger_entries
  drop constraint if exists cash_ledger_category_valid;
alter table public.cash_ledger_entries
  add constraint cash_ledger_category_valid check (
    category in (
      'ADVANCE', 'DEBT_REPAYMENT', 'PRODUCT_SALE', 'STOCK_PURCHASE',
      'EXPENSE', 'FARMER_PAYOUT', 'CROP_SALE'
    )
  );

-- A repayment deducted from crop proceeds is a real principal/interest
-- settlement but not a physical cash receipt.
alter table public.advance_repayments
  drop constraint if exists advance_repayment_method_valid;
alter table public.advance_repayments
  add constraint advance_repayment_method_valid check (
    payment_method in ('CASH', 'BANK', 'MOBILE', 'OFFSET')
  );
alter table public.advance_repayments
  drop constraint if exists advance_repayment_reference_valid;
alter table public.advance_repayments
  add constraint advance_repayment_reference_valid check (
    payment_method in ('CASH', 'OFFSET')
    or length(trim(payment_reference)) between 1 and 160
  );

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
  if v_prefix not in ('AD', 'RP', 'GS', 'ST', 'EX', 'CS', 'SL', 'DC') then
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

-- ---------------------------------------------------------------------------
-- Pwal-yon-owned crop stock and farmer purchase settlements.
-- Farmer-owned consignment_lots remain a separate custody ledger.
-- ---------------------------------------------------------------------------

create table if not exists public.crop_settlements (
  id uuid primary key default gen_random_uuid(),
  transaction_id uuid not null unique references public.finance_transactions(id)
    on update restrict on delete restrict,
  settlement_ref text not null unique,
  batch_id uuid not null unique references public.weighing_batches(id)
    on update restrict on delete restrict,
  allocation_id uuid unique references public.intake_allocations(id)
    on update restrict on delete restrict,
  business_date date not null,
  customer_id text not null references public.farmers(customer_id)
    on update restrict on delete restrict,
  farmer_name_snapshot text not null,
  crop_type_id text not null references public.crop_types(crop_type_id)
    on update restrict on delete restrict,
  crop_name_snapshot text not null,
  crop_category text not null,
  location_id text not null references public.stock_locations(location_id)
    on update restrict on delete restrict,
  source_gross_centi_pyitha bigint not null,
  purchased_centi_pyitha bigint not null,
  actual_bags integer not null,
  pricing_divisor_pyitha integer not null,
  market_price_kyat bigint,
  gross_value_kyat bigint not null,
  labour_basis text not null,
  labour_weight_centi_pyitha bigint not null,
  labour_rate_kyat bigint not null,
  labour_total_kyat bigint not null,
  commission_rate numeric(7,4) not null,
  commission_total_kyat bigint not null,
  freight_kyat bigint not null,
  total_expense_kyat bigint not null,
  value_after_expense_kyat bigint not null,
  debt_advance_lot_id uuid references public.advance_lots(id)
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

  constraint crop_settlement_ref_valid check (
    settlement_ref ~ '^CS-[0-9]{8}-[0-9]{6,}$'
  ),
  constraint crop_settlement_category_valid check (
    crop_category in ('BEAN', 'CHILI')
  ),
  constraint crop_settlement_source_valid check (
    (crop_category = 'BEAN' and allocation_id is not null
      and market_price_kyat is not null)
    or (crop_category = 'CHILI' and allocation_id is null
      and market_price_kyat is null)
  ),
  constraint crop_settlement_weight_valid check (
    source_gross_centi_pyitha > 0 and purchased_centi_pyitha > 0
    and purchased_centi_pyitha <= source_gross_centi_pyitha
    and actual_bags > 0 and pricing_divisor_pyitha > 0
  ),
  constraint crop_settlement_value_valid check (
    gross_value_kyat > 0 and labour_weight_centi_pyitha > 0
    and labour_rate_kyat >= 0 and labour_total_kyat >= 0
    and commission_rate between 0 and 100
    and commission_total_kyat >= 0 and freight_kyat >= 0
    and total_expense_kyat = labour_total_kyat
      + commission_total_kyat + freight_kyat
    and value_after_expense_kyat = gross_value_kyat - total_expense_kyat
    and value_after_expense_kyat >= 0
  ),
  constraint crop_settlement_labour_basis_valid check (
    labour_basis in ('SALE', 'RECEIPT')
  ),
  constraint crop_settlement_debt_valid check (
    debt_principal_kyat >= 0 and debt_interest_kyat >= 0
    and debt_total_kyat = debt_principal_kyat + debt_interest_kyat
    and debt_elapsed_days >= 0 and debt_half_month_steps >= 0
    and (
      (debt_advance_lot_id is null and debt_selected_quantity is null
        and debt_principal_kyat = 0 and debt_interest_kyat = 0
        and debt_total_kyat = 0 and debt_remaining_principal_kyat is null
        and debt_remaining_quantity is null)
      or
      (debt_advance_lot_id is not null and debt_principal_kyat > 0
        and debt_remaining_principal_kyat >= 0)
    )
  ),
  constraint crop_settlement_payable_valid check (
    debt_total_kyat <= value_after_expense_kyat
    and payable_kyat = value_after_expense_kyat - debt_total_kyat
  ),
  constraint crop_settlement_payment_valid check (
    payment_method in ('CASH', 'BANK', 'MOBILE')
    and (payable_kyat = 0 or payment_method = 'CASH'
      or length(trim(payment_reference)) between 1 and 160)
  ),
  constraint crop_settlement_stock_valid check (
    stock_before_centi_pyitha >= 0
    and stock_after_centi_pyitha
      = stock_before_centi_pyitha + purchased_centi_pyitha
  ),
  constraint crop_settlement_status_valid check (status = 'POSTED'),
  constraint crop_settlement_notes_length check (
    notes is null or length(notes) <= 500
  )
);

create index if not exists crop_settlements_date_idx
  on public.crop_settlements(business_date desc, created_at desc, id);
create index if not exists crop_settlements_farmer_idx
  on public.crop_settlements(customer_id, business_date desc, id);

create table if not exists public.crop_settlement_bag_prices (
  id uuid primary key default gen_random_uuid(),
  settlement_id uuid not null references public.crop_settlements(id)
    on update restrict on delete restrict,
  bag_id uuid not null unique references public.bag_weights(id)
    on update restrict on delete restrict,
  bag_no integer not null,
  gross_centi_pyitha integer not null,
  tare_centi_pyitha integer not null,
  net_centi_pyitha integer not null,
  condition text not null,
  moisture_pct numeric(5,2) not null,
  quality_grade text not null,
  unit_price_kyat bigint not null,
  bag_value_kyat bigint not null,
  created_at timestamptz not null default now(),

  constraint crop_settlement_bag_unique unique(settlement_id, bag_no),
  constraint crop_settlement_bag_weight_valid check (
    bag_no > 0 and gross_centi_pyitha > 0
    and tare_centi_pyitha >= 0 and tare_centi_pyitha < gross_centi_pyitha
    and net_centi_pyitha = gross_centi_pyitha - tare_centi_pyitha
  ),
  constraint crop_settlement_bag_meta_valid check (
    condition in ('WET', 'DRY') and moisture_pct between 0 and 100
    and quality_grade in ('A', 'B', 'C')
  ),
  constraint crop_settlement_bag_value_valid check (
    unit_price_kyat > 0
    and bag_value_kyat = round(net_centi_pyitha::numeric / 100
      * unit_price_kyat)::bigint
  )
);

create index if not exists crop_settlement_bag_prices_settlement_idx
  on public.crop_settlement_bag_prices(settlement_id, bag_no);

create table if not exists public.crop_stock_movements (
  id uuid primary key default gen_random_uuid(),
  transaction_id uuid not null unique references public.finance_transactions(id)
    on update restrict on delete restrict,
  movement_ref text not null,
  business_date date not null,
  crop_type_id text not null references public.crop_types(crop_type_id)
    on update restrict on delete restrict,
  location_id text not null references public.stock_locations(location_id)
    on update restrict on delete restrict,
  crop_name_snapshot text not null,
  movement_type text not null,
  quantity_delta_centi_pyitha bigint not null,
  quantity_before_centi_pyitha bigint not null,
  quantity_after_centi_pyitha bigint not null,
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),

  constraint crop_stock_movement_type_valid check (
    movement_type in ('PURCHASE_IN', 'WHOLESALE_OUT')
  ),
  constraint crop_stock_movement_quantity_valid check (
    quantity_before_centi_pyitha >= 0
    and quantity_after_centi_pyitha >= 0
    and quantity_after_centi_pyitha
      = quantity_before_centi_pyitha + quantity_delta_centi_pyitha
    and ((movement_type = 'PURCHASE_IN' and quantity_delta_centi_pyitha > 0)
      or (movement_type = 'WHOLESALE_OUT'
        and quantity_delta_centi_pyitha < 0))
  )
);

create index if not exists crop_stock_movements_balance_idx
  on public.crop_stock_movements(crop_type_id, location_id, created_at, id);
create index if not exists crop_stock_movements_date_idx
  on public.crop_stock_movements(business_date desc, created_at desc, id);

create or replace function public.crop_stock_quantity(
  p_crop_type_id text,
  p_location_id text
)
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((
    select sum(entries.weight_centi_pyitha)
    from public.opening_balance_entries as entries
    where entries.entry_type = 'CROP_STOCK'
      and entries.crop_type_id = p_crop_type_id
      and entries.location_id = p_location_id
  ), 0)::bigint + coalesce((
    select sum(movements.quantity_delta_centi_pyitha)
    from public.crop_stock_movements as movements
    where movements.crop_type_id = p_crop_type_id
      and movements.location_id = p_location_id
  ), 0)::bigint;
$$;

create or replace function public.get_crop_stock_balances()
returns table(
  crop_type_id text,
  crop_name text,
  crop_category text,
  location_id text,
  location_name text,
  quantity_centi_pyitha bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform public.require_staff_roles(array['owner']);
  return query
  select crops.crop_type_id, crops.name, crops.category,
    locations.location_id, locations.name,
    public.crop_stock_quantity(crops.crop_type_id, locations.location_id)
  from public.crop_types as crops
  cross join public.stock_locations as locations
  where crops.active and locations.active
  order by crops.name, locations.location_id;
end;
$$;

-- Allow exactly the server settlement transition on otherwise immutable
-- allocation rows and allocated weighing headers.
alter table public.intake_allocations
  drop constraint if exists intake_allocation_sale_pending;
alter table public.intake_allocations
  add constraint intake_allocation_sale_pending check (
    (sale_reserved_centi_pyitha > 0
      and sale_state in ('PENDING_SETTLEMENT', 'SETTLED'))
    or (sale_reserved_centi_pyitha = 0 and sale_state = 'NOT_APPLICABLE')
  );

create or replace function public.guard_intake_allocation_mutation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE'
    and current_setting('app.crop_post', true) = 'on'
    and old.sale_state = 'PENDING_SETTLEMENT'
    and new.sale_state = 'SETTLED'
    and (to_jsonb(new) - 'sale_state') = (to_jsonb(old) - 'sale_state') then
    return new;
  end if;
  raise exception 'Intake allocations are immutable outside crop settlement'
    using errcode = '42501';
end;
$$;

drop trigger if exists intake_allocations_no_mutation
  on public.intake_allocations;
create trigger intake_allocations_no_mutation
before update or delete on public.intake_allocations
for each row execute function public.guard_intake_allocation_mutation();

create or replace function public.guard_allocated_weighing_receipt()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if current_setting('app.crop_post', true) = 'on'
    and old.status = 'SUBMITTED' and new.status = 'SETTLED' then
    return new;
  end if;
  if (new.status, new.total_bags, new.total_gross_weight_centi_pyitha,
      new.customer_id, new.crop_type_id, new.business_date, new.intake_mode)
     is distinct from
     (old.status, old.total_bags, old.total_gross_weight_centi_pyitha,
      old.customer_id, old.crop_type_id, old.business_date, old.intake_mode)
    and (exists(select 1 from public.intake_allocations where batch_id = old.id)
      or exists(select 1 from public.consignment_lots where batch_id = old.id)) then
    raise exception 'Allocated receipt is immutable; use a linked correction workflow'
      using errcode = '55000';
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Wholesale crop sales and buyer receivable snapshot.
-- ---------------------------------------------------------------------------

create table if not exists public.wholesale_crop_sales (
  id uuid primary key default gen_random_uuid(),
  transaction_id uuid not null unique references public.finance_transactions(id)
    on update restrict on delete restrict,
  sale_ref text not null unique,
  business_date date not null,
  buyer_name text not null,
  crop_type_id text not null references public.crop_types(crop_type_id)
    on update restrict on delete restrict,
  crop_name_snapshot text not null,
  location_id text not null references public.stock_locations(location_id)
    on update restrict on delete restrict,
  weight_centi_pyitha bigint not null,
  actual_bags integer not null,
  pricing_divisor_pyitha integer not null,
  rate_kyat bigint not null,
  gross_value_kyat bigint not null,
  freight_kyat bigint not null,
  net_value_kyat bigint not null,
  received_kyat bigint not null,
  receivable_kyat bigint not null,
  payment_method text not null,
  payment_reference text,
  notes text,
  stock_before_centi_pyitha bigint not null,
  stock_after_centi_pyitha bigint not null,
  status text not null default 'POSTED',
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),

  constraint wholesale_crop_sale_ref_valid check (
    sale_ref ~ '^SL-[0-9]{8}-[0-9]{6,}$'
  ),
  constraint wholesale_crop_sale_buyer_present check (
    length(trim(buyer_name)) between 1 and 160
  ),
  constraint wholesale_crop_sale_value_valid check (
    weight_centi_pyitha > 0 and actual_bags >= 0
    and pricing_divisor_pyitha > 0 and rate_kyat > 0
    and gross_value_kyat = round(weight_centi_pyitha::numeric
      / (100 * pricing_divisor_pyitha) * rate_kyat)::bigint
    and freight_kyat >= 0 and freight_kyat <= gross_value_kyat
    and net_value_kyat = gross_value_kyat - freight_kyat
    and received_kyat >= 0 and received_kyat <= net_value_kyat
    and receivable_kyat = net_value_kyat - received_kyat
  ),
  constraint wholesale_crop_sale_method_valid check (
    payment_method in ('CASH', 'BANK', 'MOBILE', 'CREDIT')
    and ((payment_method = 'CREDIT' and received_kyat = 0
          and receivable_kyat = net_value_kyat)
      or (payment_method <> 'CREDIT' and received_kyat = net_value_kyat
          and receivable_kyat = 0))
  ),
  constraint wholesale_crop_sale_reference_valid check (
    payment_method in ('CASH', 'CREDIT')
    or length(trim(payment_reference)) between 1 and 160
  ),
  constraint wholesale_crop_sale_stock_valid check (
    stock_before_centi_pyitha >= weight_centi_pyitha
    and stock_after_centi_pyitha
      = stock_before_centi_pyitha - weight_centi_pyitha
  ),
  constraint wholesale_crop_sale_status_valid check (status = 'POSTED'),
  constraint wholesale_crop_sale_notes_length check (
    notes is null or length(notes) <= 500
  )
);

create index if not exists wholesale_crop_sales_date_idx
  on public.wholesale_crop_sales(business_date desc, created_at desc, id);
create index if not exists wholesale_crop_sales_buyer_idx
  on public.wholesale_crop_sales(lower(buyer_name), business_date desc, id);

create table if not exists public.buyer_receivable_lots (
  id uuid primary key default gen_random_uuid(),
  sale_id uuid not null unique references public.wholesale_crop_sales(id)
    on update restrict on delete restrict,
  sale_ref text not null unique,
  business_date date not null,
  buyer_name text not null,
  opening_kyat bigint not null,
  remaining_kyat bigint not null,
  status text not null default 'OPEN',
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),

  constraint buyer_receivable_value_valid check (
    opening_kyat > 0 and remaining_kyat between 0 and opening_kyat
  ),
  constraint buyer_receivable_status_valid check (
    (status = 'OPEN' and remaining_kyat > 0)
    or (status = 'PAID' and remaining_kyat = 0)
  )
);

create index if not exists buyer_receivable_lots_open_idx
  on public.buyer_receivable_lots(status, business_date desc, id);

-- ---------------------------------------------------------------------------
-- Immutable day close and posting lock.
-- ---------------------------------------------------------------------------

create table if not exists public.business_day_closes (
  id uuid primary key default gen_random_uuid(),
  transaction_id uuid not null unique references public.finance_transactions(id)
    on update restrict on delete restrict,
  day_close_ref text not null unique,
  business_date date not null unique,
  previous_close_date date,
  opening_cash_kyat bigint not null,
  physical_cash_in_kyat bigint not null,
  physical_cash_out_kyat bigint not null,
  non_cash_in_kyat bigint not null,
  non_cash_out_kyat bigint not null,
  expected_cash_kyat bigint not null,
  counted_cash_kyat bigint not null,
  variance_kyat bigint not null,
  pending_draft_batches integer not null,
  pending_unallocated_batches integer not null,
  pending_settlements integer not null,
  status text not null default 'CLOSED',
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),

  constraint business_day_close_ref_valid check (
    day_close_ref ~ '^DC-[0-9]{8}-[0-9]{6,}$'
  ),
  constraint business_day_close_money_valid check (
    opening_cash_kyat >= 0 and physical_cash_in_kyat >= 0
    and physical_cash_out_kyat >= 0 and non_cash_in_kyat >= 0
    and non_cash_out_kyat >= 0
    and expected_cash_kyat
      = opening_cash_kyat + physical_cash_in_kyat - physical_cash_out_kyat
    and expected_cash_kyat >= 0 and counted_cash_kyat >= 0
    and variance_kyat = counted_cash_kyat - expected_cash_kyat
    and variance_kyat = 0
  ),
  constraint business_day_close_pending_valid check (
    pending_draft_batches = 0 and pending_unallocated_batches = 0
    and pending_settlements = 0
  ),
  constraint business_day_close_status_valid check (status = 'CLOSED')
);

create index if not exists business_day_closes_created_idx
  on public.business_day_closes(created_at desc, id);

create or replace function public.assert_business_day_open()
returns date
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare v_date date;
begin
  -- Every operational post holds a shared lock until its transaction ends.
  -- Day Close takes the matching exclusive lock, so a close can never miss a
  -- concurrent cash, stock, weighing, or allocation write.
  perform 1 from public.business_settings where singleton for share;
  v_date := public.get_business_date();
  if exists(select 1 from public.business_day_closes where business_date = v_date) then
    raise exception 'Business day % is already closed', v_date
      using errcode = '55000';
  end if;
  return v_date;
end;
$$;

create or replace function public.guard_closed_business_day_posting()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform 1 from public.business_settings where singleton for share;
  if exists(
    select 1 from public.business_day_closes as closes
    where closes.business_date = new.business_date
  ) then
    raise exception 'Business day % is already closed', new.business_date
      using errcode = '55000';
  end if;
  return new;
end;
$$;

drop trigger if exists finance_transactions_closed_day_guard
  on public.finance_transactions;
create trigger finance_transactions_closed_day_guard
before insert on public.finance_transactions
for each row execute function public.guard_closed_business_day_posting();

drop trigger if exists weighing_batches_closed_day_guard
  on public.weighing_batches;
create trigger weighing_batches_closed_day_guard
before insert on public.weighing_batches
for each row execute function public.guard_closed_business_day_posting();

create or replace function public.guard_current_business_day_open()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.assert_business_day_open();
  return new;
end;
$$;

drop trigger if exists zz_bag_weights_closed_day_guard on public.bag_weights;
create trigger zz_bag_weights_closed_day_guard
before insert or update on public.bag_weights
for each row execute function public.guard_current_business_day_open();

drop trigger if exists intake_allocations_closed_day_guard
  on public.intake_allocations;
create trigger intake_allocations_closed_day_guard
before insert on public.intake_allocations
for each row execute function public.guard_current_business_day_open();

-- ---------------------------------------------------------------------------
-- Crop settlement RPC.
-- ---------------------------------------------------------------------------

create or replace function public.settle_crop_intake(
  p_request_id uuid,
  p_batch_id uuid,
  p_location_id text,
  p_market_price_kyat bigint,
  p_labour_basis text,
  p_labour_rate_kyat bigint,
  p_commission_rate numeric,
  p_freight_kyat bigint,
  p_payment_method text,
  p_payment_reference text,
  p_debt_advance_lot_id uuid,
  p_debt_principal_kyat bigint,
  p_debt_quantity numeric,
  p_chili_bag_prices jsonb,
  p_notes text
)
returns table(
  settlement_id uuid,
  settlement_ref text,
  business_date date,
  crop_category text,
  purchased_centi_pyitha bigint,
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
  v_existing public.crop_settlements%rowtype;
  v_batch public.weighing_batches%rowtype;
  v_allocation public.intake_allocations%rowtype;
  v_crop public.crop_types%rowtype;
  v_lot public.advance_lots%rowtype;
  v_date date;
  v_category text;
  v_location text := trim(coalesce(p_location_id, ''));
  v_labour_basis text := upper(trim(coalesce(p_labour_basis, '')));
  v_method text := upper(trim(coalesce(p_payment_method, '')));
  v_reference text := nullif(trim(coalesce(p_payment_reference, '')), '');
  v_notes text := nullif(trim(coalesce(p_notes, '')), '');
  v_payload jsonb;
  v_transaction_id uuid;
  v_settlement_id uuid;
  v_ref text;
  v_source_gross bigint;
  v_purchased bigint;
  v_actual_bags integer;
  v_divisor integer;
  v_gross_value bigint;
  v_labour_weight bigint;
  v_labour_total bigint;
  v_commission_total bigint;
  v_freight bigint := coalesce(p_freight_kyat, 0);
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
  v_price_count integer;
begin
  perform public.require_staff_roles(array['owner']);
  if p_request_id is null or p_batch_id is null then
    raise exception 'Settlement request ID and batch are required'
      using errcode = '22023';
  end if;

  v_payload := jsonb_build_object(
    'batch_id', p_batch_id,
    'location_id', v_location,
    'market_price_kyat', p_market_price_kyat,
    'labour_basis', v_labour_basis,
    'labour_rate_kyat', p_labour_rate_kyat,
    'commission_rate', p_commission_rate,
    'freight_kyat', p_freight_kyat,
    'payment_method', v_method,
    'payment_reference', v_reference,
    'debt_advance_lot_id', p_debt_advance_lot_id,
    'debt_principal_kyat', p_debt_principal_kyat,
    'debt_quantity', p_debt_quantity,
    'chili_bag_prices', p_chili_bag_prices,
    'notes', v_notes
  );

  select transactions.* into v_existing_tx
  from public.finance_transactions as transactions
  where transactions.request_id = p_request_id;
  if found then
    if v_existing_tx.document_type <> 'CROP_SETTLEMENT'
      or v_existing_tx.request_payload <> v_payload then
      raise exception 'Request ID was already used with different settlement data'
        using errcode = '23505';
    end if;
    select settlements.* into strict v_existing
    from public.crop_settlements as settlements
    where settlements.transaction_id = v_existing_tx.id;
    return query select v_existing.id, v_existing.settlement_ref,
      v_existing.business_date, v_existing.crop_category,
      v_existing.purchased_centi_pyitha, v_existing.gross_value_kyat,
      v_existing.total_expense_kyat, v_existing.debt_principal_kyat,
      v_existing.debt_interest_kyat, v_existing.debt_total_kyat,
      v_existing.payable_kyat, v_existing.stock_before_centi_pyitha,
      v_existing.stock_after_centi_pyitha, true;
    return;
  end if;

  v_date := public.assert_business_day_open();
  if v_location = '' or v_labour_basis not in ('SALE', 'RECEIPT')
    or p_labour_rate_kyat is null or p_labour_rate_kyat < 0
    or p_commission_rate is null or p_commission_rate < 0
    or p_commission_rate > 100
    or p_commission_rate <> round(p_commission_rate, 4)
    or v_freight < 0 or v_method not in ('CASH', 'BANK', 'MOBILE')
    or (v_notes is not null and length(v_notes) > 500) then
    raise exception 'Invalid settlement cost or payment input'
      using errcode = '22023';
  end if;
  if not exists(select 1 from public.stock_locations
    where location_id = v_location and active) then
    raise exception 'Active stock location not found' using errcode = '23503';
  end if;

  select batches.* into v_batch from public.weighing_batches as batches
  where batches.id = p_batch_id for update;
  if not found then
    raise exception 'Weighing batch not found' using errcode = '23503';
  end if;
  if v_batch.status <> 'SUBMITTED' then
    raise exception 'Only a submitted weighing batch may be settled'
      using errcode = '55000';
  end if;
  if exists(select 1 from public.crop_settlements where batch_id = v_batch.id) then
    raise exception 'Weighing batch is already settled' using errcode = '23505';
  end if;

  select crops.* into v_crop from public.crop_types as crops
  where crops.crop_type_id = v_batch.crop_type_id and crops.active
  for update;
  if not found or v_crop.category not in ('BEAN', 'CHILI') then
    raise exception 'Active bean or chili crop type is required'
      using errcode = '23503';
  end if;
  v_category := v_crop.category;
  v_source_gross := v_batch.total_gross_weight_centi_pyitha;
  v_actual_bags := v_batch.total_bags;
  v_divisor := v_crop.pricing_divisor_pyitha;

  if v_category = 'BEAN' then
    select allocations.* into v_allocation
    from public.intake_allocations as allocations
    where allocations.batch_id = v_batch.id for update;
    if not found or v_allocation.sale_reserved_centi_pyitha <= 0
      or v_allocation.sale_state <> 'PENDING_SETTLEMENT' then
      raise exception 'Bean receipt has no pending sale-reserved allocation'
        using errcode = '55000';
    end if;
    if v_allocation.location_id <> v_location then
      raise exception 'Settlement location must match intake allocation location'
        using errcode = '23514';
    end if;
    if p_market_price_kyat is null or p_market_price_kyat <= 0 then
      raise exception 'Bean market price must be a positive whole kyat amount'
        using errcode = '22023';
    end if;
    if p_chili_bag_prices is not null
      and p_chili_bag_prices <> '[]'::jsonb then
      raise exception 'Bean settlement cannot contain chili bag prices'
        using errcode = '22023';
    end if;
    v_purchased := v_allocation.sale_reserved_centi_pyitha;
    v_gross_value := round(v_purchased::numeric / (100 * v_divisor)
      * p_market_price_kyat)::bigint;
    v_labour_weight := case when v_labour_basis = 'RECEIPT'
      then v_allocation.net_centi_pyitha else v_purchased end;
  else
    if v_labour_basis <> 'SALE' then
      raise exception 'Chili labour basis must be SALE' using errcode = '22023';
    end if;
    if p_market_price_kyat is not null then
      raise exception 'Chili must be priced per bag' using errcode = '22023';
    end if;
    if p_chili_bag_prices is null
      or jsonb_typeof(p_chili_bag_prices) <> 'array' then
      raise exception 'Chili bag price array is required' using errcode = '22023';
    end if;
    if exists(select 1 from public.intake_allocations where batch_id = v_batch.id)
      or exists(select 1 from public.consignment_lots where batch_id = v_batch.id) then
      raise exception 'Allocated or consigned chili receipt needs a dedicated allocation workflow'
        using errcode = '55000';
    end if;
    with prices as (
      select * from jsonb_to_recordset(p_chili_bag_prices)
        as x(bag_no integer, tare_centi_pyitha integer,
          unit_price_kyat bigint)
    ), checked as (
      select bags.id, bags.bag_no, bags.weight_centi_pyitha,
        bags.condition, bags.moisture_pct, bags.quality_grade,
        prices.tare_centi_pyitha, prices.unit_price_kyat
      from public.bag_weights as bags
      left join prices on prices.bag_no = bags.bag_no
      where bags.batch_id = v_batch.id and bags.status <> 'VOID'
    )
    select count(*)::integer,
      coalesce(sum(weight_centi_pyitha - tare_centi_pyitha), 0)::bigint,
      coalesce(sum(round((weight_centi_pyitha - tare_centi_pyitha)::numeric
        / 100 * unit_price_kyat)), 0)::bigint
    into v_price_count, v_purchased, v_gross_value
    from checked
    where tare_centi_pyitha is not null and unit_price_kyat is not null
      and tare_centi_pyitha >= 0
      and tare_centi_pyitha < weight_centi_pyitha
      and unit_price_kyat > 0
      and condition in ('WET', 'DRY') and moisture_pct between 0 and 100
      and quality_grade in ('A', 'B', 'C');

    if v_price_count <> v_actual_bags
      or jsonb_array_length(p_chili_bag_prices) <> v_actual_bags
      or (select count(distinct (entry->>'bag_no')::integer)
          from jsonb_array_elements(p_chili_bag_prices) entry)
        <> v_actual_bags then
      raise exception 'Every submitted chili bag needs one valid tare and price'
        using errcode = '22023';
    end if;
    v_labour_weight := v_purchased;
  end if;

  if v_purchased <= 0 or v_gross_value <= 0 or v_labour_weight <= 0 then
    raise exception 'Settlement weight and value must be positive'
      using errcode = '22023';
  end if;
  v_labour_total := round(v_labour_weight::numeric / 3000
    * p_labour_rate_kyat)::bigint;
  v_commission_total := round(v_gross_value::numeric
    * p_commission_rate / 100)::bigint;
  v_expense := v_labour_total + v_commission_total + v_freight;
  v_after_expense := v_gross_value - v_expense;
  if v_after_expense < 0 then
    raise exception 'Settlement expenses exceed crop value'
      using errcode = '22023';
  end if;

  if p_debt_advance_lot_id is not null then
    select lots.* into v_lot from public.advance_lots as lots
    where lots.id = p_debt_advance_lot_id for update;
    if not found or v_lot.customer_id <> v_batch.customer_id
      or v_lot.status not in ('OPEN', 'PARTIAL')
      or v_lot.remaining_principal_kyat <= 0 then
      raise exception 'Selected open farmer advance lot not found'
        using errcode = '23503';
    end if;
    if v_date < v_lot.issued_date then
      raise exception 'Server business date is before advance issue date'
        using errcode = '22023';
    end if;
    if v_lot.advance_type = 'GOODS' then
      if p_debt_quantity is null or p_debt_quantity <= 0
        or p_debt_quantity <> round(p_debt_quantity, 3)
        or (v_lot.whole_units_only and p_debt_quantity <> trunc(p_debt_quantity))
        or p_debt_quantity > v_lot.remaining_quantity then
        raise exception 'Invalid goods debt quantity for crop offset'
          using errcode = '22023';
      end if;
      v_debt_quantity := p_debt_quantity;
      if p_debt_quantity = v_lot.remaining_quantity then
        v_debt_principal := v_lot.remaining_principal_kyat;
        v_debt_remaining_quantity := 0;
      else
        v_debt_principal := round(p_debt_quantity * v_lot.unit_price_kyat)::bigint;
        v_debt_remaining_quantity := v_lot.remaining_quantity - p_debt_quantity;
        if v_debt_principal <= 0
          or v_debt_principal >= v_lot.remaining_principal_kyat then
          raise exception 'Partial goods offset would close principal inconsistently'
            using errcode = '22023';
        end if;
      end if;
    else
      if p_debt_principal_kyat is null or p_debt_principal_kyat <= 0
        or p_debt_principal_kyat > v_lot.remaining_principal_kyat then
        raise exception 'Invalid cash debt principal for crop offset'
          using errcode = '22023';
      end if;
      v_debt_principal := p_debt_principal_kyat;
      v_debt_quantity := null;
      v_debt_remaining_quantity := null;
    end if;
    v_debt_days := v_date - v_lot.issued_date;
    v_debt_steps := case when v_debt_days = 0 then 0
      else (v_debt_days + 14) / 15 end;
    v_debt_interest := round(v_debt_principal::numeric
      * v_lot.monthly_interest_rate / 100 * v_debt_steps / 2)::bigint;
    v_debt_total := v_debt_principal + v_debt_interest;
    v_debt_remaining := v_lot.remaining_principal_kyat - v_debt_principal;
    if v_lot.advance_type = 'GOODS'
      and ((v_debt_remaining_quantity = 0) <> (v_debt_remaining = 0)) then
      raise exception 'Goods debt principal and quantity would close inconsistently'
        using errcode = '23514';
    end if;
    v_debt_status := case
      when v_debt_remaining = 0 then 'PAID'
      when v_debt_remaining < v_lot.original_principal_kyat then 'PARTIAL'
      else 'OPEN' end;
  elsif p_debt_principal_kyat is not null or p_debt_quantity is not null then
    raise exception 'Debt amount requires an advance lot' using errcode = '22023';
  end if;

  if v_debt_total > v_after_expense then
    raise exception 'Debt principal and interest exceed settlement proceeds'
      using errcode = '22023';
  end if;
  v_payable := v_after_expense - v_debt_total;
  if v_payable > 0 and v_method <> 'CASH'
    and v_reference is null then
    raise exception 'Bank or mobile payout reference is required'
      using errcode = '22023';
  end if;

  v_stock_before := public.crop_stock_quantity(v_crop.crop_type_id, v_location);
  v_stock_after := v_stock_before + v_purchased;
  v_ref := public.next_finance_document_ref('CS', v_date);
  insert into public.finance_transactions(
    request_id, request_payload, document_ref, document_type,
    business_date, created_by
  ) values (
    p_request_id, v_payload, v_ref, 'CROP_SETTLEMENT', v_date, auth.uid()
  ) returning id into v_transaction_id;

  insert into public.crop_settlements(
    transaction_id, settlement_ref, batch_id, allocation_id, business_date,
    customer_id, farmer_name_snapshot, crop_type_id, crop_name_snapshot,
    crop_category, location_id, source_gross_centi_pyitha,
    purchased_centi_pyitha, actual_bags, pricing_divisor_pyitha,
    market_price_kyat, gross_value_kyat, labour_basis,
    labour_weight_centi_pyitha, labour_rate_kyat, labour_total_kyat,
    commission_rate, commission_total_kyat, freight_kyat,
    total_expense_kyat, value_after_expense_kyat, debt_advance_lot_id,
    debt_selected_quantity, debt_principal_kyat, debt_interest_kyat,
    debt_total_kyat, debt_elapsed_days, debt_half_month_steps,
    debt_remaining_principal_kyat, debt_remaining_quantity, payable_kyat,
    payment_method, payment_reference, notes,
    stock_before_centi_pyitha, stock_after_centi_pyitha, created_by
  ) values (
    v_transaction_id, v_ref, v_batch.id, v_allocation.id, v_date,
    v_batch.customer_id, v_batch.customer_name, v_crop.crop_type_id,
    v_crop.name, v_category, v_location, v_source_gross, v_purchased,
    v_actual_bags, v_divisor,
    case when v_category = 'BEAN' then p_market_price_kyat else null end,
    v_gross_value, v_labour_basis, v_labour_weight, p_labour_rate_kyat,
    v_labour_total, p_commission_rate, v_commission_total, v_freight,
    v_expense, v_after_expense, p_debt_advance_lot_id, v_debt_quantity,
    v_debt_principal, v_debt_interest, v_debt_total, v_debt_days,
    v_debt_steps, case when p_debt_advance_lot_id is null then null
      else v_debt_remaining end,
    case when p_debt_advance_lot_id is null then null
      else v_debt_remaining_quantity end,
    v_payable, v_method, v_reference, v_notes,
    v_stock_before, v_stock_after, auth.uid()
  ) returning id into v_settlement_id;

  if v_category = 'CHILI' then
    insert into public.crop_settlement_bag_prices(
      settlement_id, bag_id, bag_no, gross_centi_pyitha,
      tare_centi_pyitha, net_centi_pyitha, condition, moisture_pct,
      quality_grade, unit_price_kyat, bag_value_kyat
    )
    select v_settlement_id, bags.id, bags.bag_no, bags.weight_centi_pyitha,
      prices.tare_centi_pyitha,
      bags.weight_centi_pyitha - prices.tare_centi_pyitha,
      bags.condition, bags.moisture_pct, bags.quality_grade,
      prices.unit_price_kyat,
      round((bags.weight_centi_pyitha - prices.tare_centi_pyitha)::numeric
        / 100 * prices.unit_price_kyat)::bigint
    from public.bag_weights as bags
    join jsonb_to_recordset(p_chili_bag_prices)
      as prices(bag_no integer, tare_centi_pyitha integer,
        unit_price_kyat bigint)
      on prices.bag_no = bags.bag_no
    where bags.batch_id = v_batch.id and bags.status <> 'VOID';
  end if;

  if p_debt_advance_lot_id is not null then
    perform set_config('app.finance_post', 'on', true);
    update public.advance_lots set
      remaining_principal_kyat = v_debt_remaining,
      remaining_quantity = v_debt_remaining_quantity,
      status = v_debt_status,
      updated_at = now()
    where id = v_lot.id;

    insert into public.advance_repayments(
      transaction_id, repayment_ref, advance_lot_id, payment_date,
      quantity_before, selected_quantity, principal_before_kyat,
      principal_kyat, interest_kyat, total_received_kyat,
      elapsed_days, half_month_steps, monthly_interest_rate_snapshot,
      payment_method, payment_reference, notes, remaining_quantity,
      remaining_principal_kyat, created_by
    ) values (
      v_transaction_id, v_ref || '-RP', v_lot.id, v_date,
      v_lot.remaining_quantity, v_debt_quantity,
      v_lot.remaining_principal_kyat, v_debt_principal,
      v_debt_interest, v_debt_total, v_debt_days, v_debt_steps,
      v_lot.monthly_interest_rate, 'OFFSET', v_ref,
      'Crop settlement offset', v_debt_remaining_quantity,
      v_debt_remaining, auth.uid()
    );
  end if;

  insert into public.crop_stock_movements(
    transaction_id, movement_ref, business_date, crop_type_id, location_id,
    crop_name_snapshot, movement_type, quantity_delta_centi_pyitha,
    quantity_before_centi_pyitha, quantity_after_centi_pyitha, created_by
  ) values (
    v_transaction_id, v_ref, v_date, v_crop.crop_type_id, v_location,
    v_crop.name, 'PURCHASE_IN', v_purchased, v_stock_before,
    v_stock_after, auth.uid()
  );

  if v_payable > 0 then
    insert into public.cash_ledger_entries(
      transaction_id, document_ref, business_date, direction, amount_kyat,
      payment_method, category, label, principal_kyat, interest_kyat,
      created_by
    ) values (
      v_transaction_id, v_ref, v_date, 'OUT', v_payable, v_method,
      'FARMER_PAYOUT', 'တောင်သူသီးနှံငွေရှင်း · ' || v_batch.customer_name
        || ' · ' || v_crop.name, 0, 0, auth.uid()
    );
  end if;

  insert into public.finance_audit_events(
    transaction_id, document_ref, action, payload, created_by
  ) values (
    v_transaction_id, v_ref, 'CROP_SETTLED', jsonb_build_object(
      'batch_id', v_batch.id, 'crop_category', v_category,
      'purchased_centi_pyitha', v_purchased,
      'gross_value_kyat', v_gross_value, 'expense_kyat', v_expense,
      'debt_principal_kyat', v_debt_principal,
      'debt_interest_kyat', v_debt_interest,
      'payable_kyat', v_payable, 'stock_after', v_stock_after
    ), auth.uid()
  );

  perform set_config('app.crop_post', 'on', true);
  if v_category = 'BEAN' then
    update public.intake_allocations set sale_state = 'SETTLED'
    where id = v_allocation.id;
  end if;
  update public.weighing_batches set status = 'SETTLED',
    settled_by = auth.uid(), settled_at = now()
  where id = v_batch.id;
  perform set_config('app.crop_post', '', true);

  return query select v_settlement_id, v_ref, v_date, v_category,
    v_purchased, v_gross_value, v_expense, v_debt_principal,
    v_debt_interest, v_debt_total, v_payable,
    v_stock_before, v_stock_after, false;
end;
$$;

-- ---------------------------------------------------------------------------
-- Wholesale crop sale RPC.
-- ---------------------------------------------------------------------------

create or replace function public.record_wholesale_crop_sale(
  p_request_id uuid,
  p_buyer_name text,
  p_crop_type_id text,
  p_location_id text,
  p_weight_centi_pyitha bigint,
  p_actual_bags integer,
  p_pricing_divisor_pyitha integer,
  p_rate_kyat bigint,
  p_freight_kyat bigint,
  p_received_kyat bigint,
  p_payment_method text,
  p_payment_reference text,
  p_notes text
)
returns table(
  sale_id uuid,
  sale_ref text,
  business_date date,
  gross_value_kyat bigint,
  net_value_kyat bigint,
  received_kyat bigint,
  receivable_kyat bigint,
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
  v_existing public.wholesale_crop_sales%rowtype;
  v_crop public.crop_types%rowtype;
  v_date date;
  v_buyer text := trim(coalesce(p_buyer_name, ''));
  v_location text := trim(coalesce(p_location_id, ''));
  v_method text := upper(trim(coalesce(p_payment_method, '')));
  v_reference text := nullif(trim(coalesce(p_payment_reference, '')), '');
  v_notes text := nullif(trim(coalesce(p_notes, '')), '');
  v_payload jsonb;
  v_transaction_id uuid;
  v_sale_id uuid;
  v_ref text;
  v_gross bigint;
  v_net bigint;
  v_receivable bigint;
  v_before bigint;
  v_after bigint;
begin
  perform public.require_staff_roles(array['owner']);
  if p_request_id is null then
    raise exception 'Crop-sale request ID is required' using errcode = '22023';
  end if;
  v_payload := jsonb_build_object(
    'buyer_name', v_buyer, 'crop_type_id', trim(coalesce(p_crop_type_id,'')),
    'location_id', v_location, 'weight_centi_pyitha', p_weight_centi_pyitha,
    'actual_bags', p_actual_bags,
    'pricing_divisor_pyitha', p_pricing_divisor_pyitha,
    'rate_kyat', p_rate_kyat, 'freight_kyat', p_freight_kyat,
    'received_kyat', p_received_kyat, 'payment_method', v_method,
    'payment_reference', v_reference, 'notes', v_notes
  );
  select transactions.* into v_existing_tx
  from public.finance_transactions as transactions
  where transactions.request_id = p_request_id;
  if found then
    if v_existing_tx.document_type <> 'CROP_SALE'
      or v_existing_tx.request_payload <> v_payload then
      raise exception 'Request ID was already used with different crop-sale data'
        using errcode = '23505';
    end if;
    select sales.* into strict v_existing from public.wholesale_crop_sales sales
    where sales.transaction_id = v_existing_tx.id;
    return query select v_existing.id, v_existing.sale_ref,
      v_existing.business_date, v_existing.gross_value_kyat,
      v_existing.net_value_kyat, v_existing.received_kyat,
      v_existing.receivable_kyat, v_existing.stock_before_centi_pyitha,
      v_existing.stock_after_centi_pyitha, true;
    return;
  end if;

  v_date := public.assert_business_day_open();
  if length(v_buyer) not between 1 and 160 or v_location = ''
    or p_weight_centi_pyitha is null or p_weight_centi_pyitha <= 0
    or p_actual_bags is null or p_actual_bags < 0
    or p_pricing_divisor_pyitha is null or p_pricing_divisor_pyitha <= 0
    or p_rate_kyat is null or p_rate_kyat <= 0
    or p_freight_kyat is null or p_freight_kyat < 0
    or p_received_kyat is null or p_received_kyat < 0
    or v_method not in ('CASH', 'BANK', 'MOBILE', 'CREDIT')
    or (v_notes is not null and length(v_notes) > 500) then
    raise exception 'Invalid wholesale crop-sale input' using errcode = '22023';
  end if;
  if not exists(select 1 from public.stock_locations
      where location_id = v_location and active) then
    raise exception 'Active stock location not found' using errcode = '23503';
  end if;
  select crops.* into v_crop from public.crop_types crops
  where crops.crop_type_id = trim(coalesce(p_crop_type_id,''))
    and crops.active for update;
  if not found then
    raise exception 'Active crop type not found' using errcode = '23503';
  end if;
  v_gross := round(p_weight_centi_pyitha::numeric
    / (100 * p_pricing_divisor_pyitha) * p_rate_kyat)::bigint;
  if p_freight_kyat > v_gross then
    raise exception 'Sale freight exceeds gross value' using errcode = '22023';
  end if;
  v_net := v_gross - p_freight_kyat;
  if (v_method = 'CREDIT' and p_received_kyat <> 0)
    or (v_method <> 'CREDIT' and p_received_kyat <> v_net) then
    raise exception 'Immediate payment must equal net value; CREDIT must receive zero'
      using errcode = '22023';
  end if;
  if v_method in ('BANK', 'MOBILE') and v_reference is null then
    raise exception 'Bank or mobile sale reference is required'
      using errcode = '22023';
  end if;
  v_receivable := v_net - p_received_kyat;
  v_before := public.crop_stock_quantity(v_crop.crop_type_id, v_location);
  if p_weight_centi_pyitha > v_before then
    raise exception 'Insufficient owned crop stock' using errcode = '22023';
  end if;
  v_after := v_before - p_weight_centi_pyitha;
  v_ref := public.next_finance_document_ref('SL', v_date);

  insert into public.finance_transactions(
    request_id, request_payload, document_ref, document_type,
    business_date, created_by
  ) values (
    p_request_id, v_payload, v_ref, 'CROP_SALE', v_date, auth.uid()
  ) returning id into v_transaction_id;
  insert into public.wholesale_crop_sales(
    transaction_id, sale_ref, business_date, buyer_name, crop_type_id,
    crop_name_snapshot, location_id, weight_centi_pyitha, actual_bags,
    pricing_divisor_pyitha, rate_kyat, gross_value_kyat, freight_kyat,
    net_value_kyat, received_kyat, receivable_kyat, payment_method,
    payment_reference, notes, stock_before_centi_pyitha,
    stock_after_centi_pyitha, created_by
  ) values (
    v_transaction_id, v_ref, v_date, v_buyer, v_crop.crop_type_id,
    v_crop.name, v_location, p_weight_centi_pyitha, p_actual_bags,
    p_pricing_divisor_pyitha, p_rate_kyat, v_gross, p_freight_kyat,
    v_net, p_received_kyat, v_receivable, v_method, v_reference, v_notes,
    v_before, v_after, auth.uid()
  ) returning id into v_sale_id;
  if v_receivable > 0 then
    insert into public.buyer_receivable_lots(
      sale_id, sale_ref, business_date, buyer_name,
      opening_kyat, remaining_kyat, created_by
    ) values (
      v_sale_id, v_ref, v_date, v_buyer,
      v_receivable, v_receivable, auth.uid()
    );
  end if;
  insert into public.crop_stock_movements(
    transaction_id, movement_ref, business_date, crop_type_id, location_id,
    crop_name_snapshot, movement_type, quantity_delta_centi_pyitha,
    quantity_before_centi_pyitha, quantity_after_centi_pyitha, created_by
  ) values (
    v_transaction_id, v_ref, v_date, v_crop.crop_type_id, v_location,
    v_crop.name, 'WHOLESALE_OUT', -p_weight_centi_pyitha,
    v_before, v_after, auth.uid()
  );
  if p_received_kyat > 0 then
    insert into public.cash_ledger_entries(
      transaction_id, document_ref, business_date, direction, amount_kyat,
      payment_method, category, label, principal_kyat, interest_kyat,
      created_by
    ) values (
      v_transaction_id, v_ref, v_date, 'IN', p_received_kyat, v_method,
      'CROP_SALE', 'သီးနှံလက်ကားအရောင်း · ' || v_buyer
        || ' · ' || v_crop.name, 0, 0, auth.uid()
    );
  end if;
  insert into public.finance_audit_events(
    transaction_id, document_ref, action, payload, created_by
  ) values (
    v_transaction_id, v_ref, 'WHOLESALE_CROP_SOLD', jsonb_build_object(
      'buyer_name', v_buyer, 'crop_type_id', v_crop.crop_type_id,
      'location_id', v_location, 'weight_centi_pyitha', p_weight_centi_pyitha,
      'net_value_kyat', v_net, 'received_kyat', p_received_kyat,
      'receivable_kyat', v_receivable, 'stock_after', v_after
    ), auth.uid()
  );
  return query select v_sale_id, v_ref, v_date, v_gross, v_net,
    p_received_kyat, v_receivable, v_before, v_after, false;
end;
$$;

-- ---------------------------------------------------------------------------
-- Day-close preview and close RPC.
-- ---------------------------------------------------------------------------

create or replace function public.get_day_close_preview()
returns table(
  business_date date,
  previous_close_date date,
  opening_cash_kyat bigint,
  opening_cash_required boolean,
  physical_cash_in_kyat bigint,
  physical_cash_out_kyat bigint,
  non_cash_in_kyat bigint,
  non_cash_out_kyat bigint,
  expected_cash_kyat bigint,
  pending_draft_batches integer,
  pending_unallocated_batches integer,
  pending_settlements integer,
  pending_total integer,
  is_closed boolean,
  day_close_ref text,
  counted_cash_kyat bigint,
  variance_kyat bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_date date := public.get_business_date();
  v_previous public.business_day_closes%rowtype;
  v_closed public.business_day_closes%rowtype;
  v_opening bigint := 0;
  v_cash_in bigint := 0;
  v_cash_out bigint := 0;
  v_non_cash_in bigint := 0;
  v_non_cash_out bigint := 0;
  v_drafts integer := 0;
  v_unallocated integer := 0;
  v_settlements integer := 0;
begin
  perform public.require_staff_roles(array['owner']);
  select closes.* into v_closed from public.business_day_closes closes
  where closes.business_date = v_date;
  if found then
    return query select v_closed.business_date, v_closed.previous_close_date,
      v_closed.opening_cash_kyat, false,
      v_closed.physical_cash_in_kyat, v_closed.physical_cash_out_kyat,
      v_closed.non_cash_in_kyat, v_closed.non_cash_out_kyat,
      v_closed.expected_cash_kyat, v_closed.pending_draft_batches,
      v_closed.pending_unallocated_batches, v_closed.pending_settlements,
      0, true, v_closed.day_close_ref, v_closed.counted_cash_kyat,
      v_closed.variance_kyat;
    return;
  end if;
  select closes.* into v_previous from public.business_day_closes closes
  where closes.business_date < v_date
  order by closes.business_date desc limit 1;
  if found then v_opening := v_previous.counted_cash_kyat; end if;

  select
    coalesce(sum(amount_kyat) filter (
      where direction='IN' and payment_method='CASH'),0)::bigint,
    coalesce(sum(amount_kyat) filter (
      where direction='OUT' and payment_method='CASH'),0)::bigint,
    coalesce(sum(amount_kyat) filter (
      where direction='IN' and payment_method<>'CASH'),0)::bigint,
    coalesce(sum(amount_kyat) filter (
      where direction='OUT' and payment_method<>'CASH'),0)::bigint
  into v_cash_in, v_cash_out, v_non_cash_in, v_non_cash_out
  from public.cash_ledger_entries as entries
  where entries.business_date = v_date;

  select count(*)::integer into v_drafts
  from public.weighing_batches batches
  where batches.business_date = v_date and batches.status = 'DRAFT'
    and batches.total_bags > 0;

  select count(*)::integer into v_unallocated
  from public.weighing_batches batches
  join public.crop_types crops on crops.crop_type_id = batches.crop_type_id
  where batches.business_date = v_date and batches.status = 'SUBMITTED'
    and crops.category = 'BEAN'
    and not exists(select 1 from public.intake_allocations allocations
      where allocations.batch_id = batches.id)
    and not exists(select 1 from public.consignment_lots lots
      where lots.batch_id = batches.id)
    and not exists(select 1 from public.crop_settlements settlements
      where settlements.batch_id = batches.id);

  select count(*)::integer into v_settlements
  from public.weighing_batches batches
  join public.crop_types crops on crops.crop_type_id = batches.crop_type_id
  where batches.business_date = v_date and batches.status = 'SUBMITTED'
    and not exists(select 1 from public.crop_settlements settlements
      where settlements.batch_id = batches.id)
    and (
      crops.category = 'CHILI'
      or exists(select 1 from public.intake_allocations allocations
        where allocations.batch_id = batches.id
          and allocations.sale_reserved_centi_pyitha > 0
          and allocations.sale_state = 'PENDING_SETTLEMENT')
    );

  return query select v_date,
    case when v_previous.id is null then null else v_previous.business_date end,
    v_opening, v_previous.id is null, v_cash_in, v_cash_out,
    v_non_cash_in, v_non_cash_out, v_opening + v_cash_in - v_cash_out,
    v_drafts, v_unallocated, v_settlements,
    v_drafts + v_unallocated + v_settlements,
    false, null::text, null::bigint, null::bigint;
end;
$$;

create or replace function public.close_business_day(
  p_request_id uuid,
  p_opening_cash_kyat bigint,
  p_counted_cash_kyat bigint
)
returns table(
  day_close_id uuid,
  day_close_ref text,
  business_date date,
  opening_cash_kyat bigint,
  physical_cash_in_kyat bigint,
  physical_cash_out_kyat bigint,
  expected_cash_kyat bigint,
  counted_cash_kyat bigint,
  variance_kyat bigint,
  idempotent boolean
)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_existing_tx public.finance_transactions%rowtype;
  v_existing public.business_day_closes%rowtype;
  v_previous public.business_day_closes%rowtype;
  v_date date;
  v_opening bigint;
  v_cash_in bigint;
  v_cash_out bigint;
  v_non_cash_in bigint;
  v_non_cash_out bigint;
  v_expected bigint;
  v_drafts integer;
  v_unallocated integer;
  v_settlements integer;
  v_payload jsonb;
  v_transaction_id uuid;
  v_close_id uuid;
  v_ref text;
begin
  perform public.require_staff_roles(array['owner']);
  if p_request_id is null or p_counted_cash_kyat is null
    or p_counted_cash_kyat < 0 then
    raise exception 'Close request and nonnegative counted cash are required'
      using errcode = '22023';
  end if;
  v_payload := jsonb_build_object(
    'opening_cash_kyat', p_opening_cash_kyat,
    'counted_cash_kyat', p_counted_cash_kyat
  );
  select transactions.* into v_existing_tx
  from public.finance_transactions transactions
  where transactions.request_id = p_request_id;
  if found then
    if v_existing_tx.document_type <> 'DAY_CLOSE'
      or v_existing_tx.request_payload <> v_payload then
      raise exception 'Request ID was already used with different day-close data'
        using errcode = '23505';
    end if;
    select closes.* into strict v_existing from public.business_day_closes closes
    where closes.transaction_id = v_existing_tx.id;
    return query select v_existing.id, v_existing.day_close_ref,
      v_existing.business_date, v_existing.opening_cash_kyat,
      v_existing.physical_cash_in_kyat,
      v_existing.physical_cash_out_kyat, v_existing.expected_cash_kyat,
      v_existing.counted_cash_kyat, v_existing.variance_kyat, true;
    return;
  end if;

  -- Serializes the close against the shared lock taken by every posting path.
  perform 1 from public.business_settings where singleton for update;
  v_date := public.get_business_date();
  if exists(select 1 from public.business_day_closes as closes
    where closes.business_date = v_date) then
    raise exception 'Business day % is already closed', v_date
      using errcode = '55000';
  end if;
  select closes.* into v_previous from public.business_day_closes closes
  where closes.business_date < v_date order by closes.business_date desc limit 1;
  if found then
    v_opening := v_previous.counted_cash_kyat;
    if p_opening_cash_kyat is not null and p_opening_cash_kyat <> v_opening then
      raise exception 'Opening cash must equal previous counted cash'
        using errcode = '23514';
    end if;
  else
    if p_opening_cash_kyat is null or p_opening_cash_kyat < 0 then
      raise exception 'Opening cash is required for the first day close'
        using errcode = '22023';
    end if;
    v_opening := p_opening_cash_kyat;
  end if;

  select preview.physical_cash_in_kyat, preview.physical_cash_out_kyat,
    preview.non_cash_in_kyat, preview.non_cash_out_kyat,
    preview.pending_draft_batches, preview.pending_unallocated_batches,
    preview.pending_settlements
  into v_cash_in, v_cash_out, v_non_cash_in, v_non_cash_out,
    v_drafts, v_unallocated, v_settlements
  from public.get_day_close_preview() preview;
  if v_drafts + v_unallocated + v_settlements > 0 then
    raise exception 'Day close blocked by pending operations: draft %, unallocated %, settlement %',
      v_drafts, v_unallocated, v_settlements using errcode = '55000';
  end if;
  v_expected := v_opening + v_cash_in - v_cash_out;
  if v_expected < 0 then
    raise exception 'Expected physical cash cannot be negative'
      using errcode = '23514';
  end if;
  if p_counted_cash_kyat <> v_expected then
    raise exception 'Counted cash must equal server expected cash (% vs %)',
      p_counted_cash_kyat, v_expected using errcode = '23514';
  end if;

  v_ref := public.next_finance_document_ref('DC', v_date);
  insert into public.finance_transactions(
    request_id, request_payload, document_ref, document_type,
    business_date, created_by
  ) values (
    p_request_id, v_payload, v_ref, 'DAY_CLOSE', v_date, auth.uid()
  ) returning id into v_transaction_id;
  insert into public.business_day_closes(
    transaction_id, day_close_ref, business_date, previous_close_date,
    opening_cash_kyat, physical_cash_in_kyat, physical_cash_out_kyat,
    non_cash_in_kyat, non_cash_out_kyat, expected_cash_kyat,
    counted_cash_kyat, variance_kyat, pending_draft_batches,
    pending_unallocated_batches, pending_settlements, created_by
  ) values (
    v_transaction_id, v_ref, v_date,
    case when v_previous.id is null then null else v_previous.business_date end,
    v_opening, v_cash_in, v_cash_out, v_non_cash_in, v_non_cash_out,
    v_expected, p_counted_cash_kyat, 0, 0, 0, 0, auth.uid()
  ) returning id into v_close_id;
  insert into public.finance_audit_events(
    transaction_id, document_ref, action, payload, created_by
  ) values (
    v_transaction_id, v_ref, 'BUSINESS_DAY_CLOSED', jsonb_build_object(
      'business_date', v_date, 'opening_cash_kyat', v_opening,
      'physical_cash_in_kyat', v_cash_in,
      'physical_cash_out_kyat', v_cash_out,
      'expected_cash_kyat', v_expected,
      'counted_cash_kyat', p_counted_cash_kyat
    ), auth.uid()
  );
  return query select v_close_id, v_ref, v_date, v_opening,
    v_cash_in, v_cash_out, v_expected, p_counted_cash_kyat,
    0::bigint, false;
end;
$$;

-- ---------------------------------------------------------------------------
-- Immutability, owner-only reads, RPC grants and realtime.
-- ---------------------------------------------------------------------------

do $$
declare v_table text;
begin
  foreach v_table in array array[
    'crop_settlements', 'crop_settlement_bag_prices',
    'crop_stock_movements', 'wholesale_crop_sales',
    'buyer_receivable_lots', 'business_day_closes'
  ] loop
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
    execute format('alter table public.%I enable row level security', v_table);
    execute format('alter table public.%I force row level security', v_table);
    execute format('revoke all on table public.%I from anon, authenticated', v_table);
    execute format('grant select on table public.%I to authenticated', v_table);
    execute format('grant all on table public.%I to service_role', v_table);
    execute format('drop policy if exists %I on public.%I',
      'Owner can read ' || v_table, v_table);
    execute format(
      'create policy %I on public.%I for select to authenticated using (public.current_staff_has_role(array[''owner'']))',
      'Owner can read ' || v_table, v_table
    );
  end loop;
end;
$$;

revoke all on function public.next_finance_document_ref(text,date)
  from public, anon, authenticated;
revoke all on function public.crop_stock_quantity(text,text)
  from public, anon, authenticated;
revoke all on function public.assert_business_day_open()
  from public, anon, authenticated;
revoke all on function public.guard_closed_business_day_posting()
  from public, anon, authenticated;
revoke all on function public.guard_current_business_day_open()
  from public, anon, authenticated;
revoke all on function public.guard_intake_allocation_mutation()
  from public, anon, authenticated;
revoke all on function public.get_crop_stock_balances()
  from public, anon, authenticated;
revoke all on function public.get_day_close_preview()
  from public, anon, authenticated;
revoke all on function public.settle_crop_intake(
  uuid,uuid,text,bigint,text,bigint,numeric,bigint,text,text,
  uuid,bigint,numeric,jsonb,text
) from public, anon, authenticated;
revoke all on function public.record_wholesale_crop_sale(
  uuid,text,text,text,bigint,integer,integer,bigint,bigint,bigint,
  text,text,text
) from public, anon, authenticated;
revoke all on function public.close_business_day(uuid,bigint,bigint)
  from public, anon, authenticated;

grant execute on function public.next_finance_document_ref(text,date)
  to service_role;
grant execute on function public.crop_stock_quantity(text,text)
  to service_role;
grant execute on function public.assert_business_day_open()
  to service_role;
grant execute on function public.guard_closed_business_day_posting()
  to service_role;
grant execute on function public.guard_current_business_day_open()
  to service_role;
grant execute on function public.guard_intake_allocation_mutation()
  to service_role;
grant execute on function public.get_crop_stock_balances()
  to authenticated, service_role;
grant execute on function public.get_day_close_preview()
  to authenticated, service_role;
grant execute on function public.settle_crop_intake(
  uuid,uuid,text,bigint,text,bigint,numeric,bigint,text,text,
  uuid,bigint,numeric,jsonb,text
) to authenticated, service_role;
grant execute on function public.record_wholesale_crop_sale(
  uuid,text,text,text,bigint,integer,integer,bigint,bigint,bigint,
  text,text,text
) to authenticated, service_role;
grant execute on function public.close_business_day(uuid,bigint,bigint)
  to authenticated, service_role;

do $$
declare v_table text;
begin
  foreach v_table in array array[
    'crop_settlements', 'crop_settlement_bag_prices',
    'crop_stock_movements', 'wholesale_crop_sales',
    'buyer_receivable_lots', 'business_day_closes'
  ] loop
    execute format('alter table public.%I replica identity full', v_table);
    begin
      execute format('alter publication supabase_realtime add table public.%I', v_table);
    exception when duplicate_object then null;
    end;
  end loop;
end;
$$;

comment on table public.crop_settlements is
  'Authoritative farmer crop purchase; bean uses sale-reserved allocation and chili uses per-bag prices.';
comment on table public.crop_stock_movements is
  'Append-only pwal-yon-owned crop inventory. Farmer consignment is never included.';
comment on table public.business_day_closes is
  'Immutable physical-cash reconciliation; a closed business date rejects later operational postings.';

notify pgrst, 'reload schema';
commit;
