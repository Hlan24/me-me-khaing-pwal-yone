-- Farmer-owned bean consignment (အပ်ပဲ) intake and custody ledger.
--
-- A submitted weighing receipt remains the immutable source of gross weight.
-- Accepting it as consignment creates a separate farmer-owned custody lot;
-- it does not turn the beans into pwal-yon-owned inventory and it does not
-- create a cash settlement.

begin;

alter table public.weighing_batches
  add column if not exists intake_mode text not null default 'DIRECT_SALE',
  add column if not exists intake_mode_set_at timestamptz,
  add column if not exists intake_mode_set_by uuid
    references auth.users (id) on delete set null;

alter table public.weighing_batches
  drop constraint if exists weighing_batches_intake_mode_valid;
alter table public.weighing_batches
  add constraint weighing_batches_intake_mode_valid check (
    intake_mode in ('DIRECT_SALE', 'FARMER_CONSIGNMENT')
  ) not valid;
alter table public.weighing_batches
  validate constraint weighing_batches_intake_mode_valid;

create index if not exists weighing_batches_intake_pending_idx
  on public.weighing_batches (
    business_date desc,
    submitted_at desc,
    id desc
  )
  where intake_mode = 'FARMER_CONSIGNMENT'
    and status = 'SUBMITTED';

comment on column public.weighing_batches.intake_mode is
  'DIRECT_SALE is normal purchase/settlement; FARMER_CONSIGNMENT remains farmer-owned custody stock.';

create table if not exists public.consignment_document_counters (
  business_date date primary key,
  last_value bigint not null default 0,
  updated_at timestamptz not null default now(),

  constraint consignment_document_counter_nonnegative check (last_value >= 0)
);

create or replace function public.next_consignment_lot_ref(
  p_business_date date
)
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_date date := coalesce(p_business_date, public.get_business_date());
  v_value bigint;
begin
  insert into public.consignment_document_counters (
    business_date,
    last_value,
    updated_at
  )
  values (v_date, 1, now())
  on conflict (business_date)
  do update set
    last_value = public.consignment_document_counters.last_value + 1,
    updated_at = now()
  returning last_value into v_value;

  return 'AP-'
    || to_char(v_date, 'YYYYMMDD')
    || '-'
    || lpad(v_value::text, 4, '0');
end;
$$;

revoke all on function public.next_consignment_lot_ref(date) from public;
grant execute on function public.next_consignment_lot_ref(date) to service_role;

create table if not exists public.consignment_lots (
  id uuid primary key default gen_random_uuid(),
  lot_ref text not null unique,
  acceptance_request_id uuid not null unique,
  batch_id uuid not null unique
    references public.weighing_batches (id) on update restrict on delete restrict,
  business_date date not null,
  customer_id text not null
    references public.farmers (customer_id) on update restrict on delete restrict,
  customer_name text not null,
  crop_type_id text not null
    references public.crop_types (crop_type_id) on update restrict on delete restrict,
  crop_name text not null,
  location_id text not null
    references public.stock_locations (location_id) on update restrict on delete restrict,
  actual_bags integer not null,
  gross_weight_centi_pyitha bigint not null,
  moisture_deduction_centi_pyitha bigint not null default 0,
  waste_deduction_centi_pyitha bigint not null default 0,
  tare_deduction_centi_pyitha bigint not null default 0,
  original_net_weight_centi_pyitha bigint not null,
  available_weight_centi_pyitha bigint not null,
  status text not null default 'OPEN',
  notes text,
  accepted_by uuid not null references auth.users (id) on delete restrict,
  accepted_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint consignment_lots_ref_valid check (
    lot_ref ~ '^AP-[0-9]{8}-[0-9]{4,}$'
  ),
  constraint consignment_lots_snapshot_present check (
    length(trim(customer_name)) between 1 and 160
    and length(trim(crop_name)) between 1 and 120
  ),
  constraint consignment_lots_bags_positive check (actual_bags > 0),
  constraint consignment_lots_gross_positive check (
    gross_weight_centi_pyitha > 0
  ),
  constraint consignment_lots_deductions_nonnegative check (
    moisture_deduction_centi_pyitha >= 0
    and waste_deduction_centi_pyitha >= 0
    and tare_deduction_centi_pyitha >= 0
  ),
  constraint consignment_lots_net_formula check (
    original_net_weight_centi_pyitha
      = gross_weight_centi_pyitha
        - moisture_deduction_centi_pyitha
        - waste_deduction_centi_pyitha
        - tare_deduction_centi_pyitha
    and original_net_weight_centi_pyitha > 0
  ),
  constraint consignment_lots_available_valid check (
    available_weight_centi_pyitha between 0
      and original_net_weight_centi_pyitha
  ),
  constraint consignment_lots_status_valid check (
    status in ('OPEN', 'CLOSED', 'VOID')
  ),
  constraint consignment_lots_status_balance_valid check (
    (status = 'OPEN' and available_weight_centi_pyitha > 0)
    or (status in ('CLOSED', 'VOID') and available_weight_centi_pyitha = 0)
  ),
  constraint consignment_lots_notes_length check (
    notes is null or char_length(notes) <= 500
  )
);

create index if not exists consignment_lots_farmer_open_idx
  on public.consignment_lots (
    customer_id,
    status,
    business_date desc,
    id desc
  );
create index if not exists consignment_lots_crop_location_open_idx
  on public.consignment_lots (
    crop_type_id,
    location_id,
    status,
    business_date desc
  );

create table if not exists public.consignment_movements (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null unique,
  lot_id uuid not null
    references public.consignment_lots (id) on update restrict on delete restrict,
  movement_type text not null,
  business_date date not null,
  quantity_centi_pyitha bigint not null,
  balance_after_centi_pyitha bigint not null,
  notes text,
  actor_user_id uuid not null references auth.users (id) on delete restrict,
  occurred_at timestamptz not null default now(),

  constraint consignment_movements_type_valid check (
    movement_type in (
      'DEPOSIT',
      'WITHDRAWAL',
      'SALE_TRANSFER',
      'ADJUSTMENT_IN',
      'ADJUSTMENT_OUT'
    )
  ),
  constraint consignment_movements_quantity_positive check (
    quantity_centi_pyitha > 0
  ),
  constraint consignment_movements_balance_nonnegative check (
    balance_after_centi_pyitha >= 0
  ),
  constraint consignment_movements_notes_length check (
    notes is null or char_length(notes) <= 500
  )
);

create unique index if not exists consignment_one_deposit_per_lot_idx
  on public.consignment_movements (lot_id)
  where movement_type = 'DEPOSIT';
create index if not exists consignment_movements_lot_time_idx
  on public.consignment_movements (lot_id, occurred_at desc, id desc);

create or replace function public.prevent_consignment_movement_mutation()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  raise exception 'Consignment movements are append-only'
    using errcode = '55000';
end;
$$;

revoke all on function public.prevent_consignment_movement_mutation()
  from public;

drop trigger if exists consignment_movements_prevent_update_delete
  on public.consignment_movements;
create trigger consignment_movements_prevent_update_delete
before update or delete on public.consignment_movements
for each row execute function public.prevent_consignment_movement_mutation();

drop trigger if exists consignment_movements_prevent_truncate
  on public.consignment_movements;
create trigger consignment_movements_prevent_truncate
before truncate on public.consignment_movements
for each statement execute function public.prevent_consignment_movement_mutation();

create or replace function public.set_weighing_intake_mode(
  p_batch_id uuid,
  p_intake_mode text
)
returns public.weighing_batches
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_mode text := upper(trim(coalesce(p_intake_mode, '')));
  v_batch public.weighing_batches%rowtype;
  v_crop_category text;
begin
  perform public.require_staff_roles(
    array['owner', 'admin', 'weigher', 'accountant']
  );

  if p_batch_id is null
    or v_mode not in ('DIRECT_SALE', 'FARMER_CONSIGNMENT') then
    raise exception 'Invalid weighing intake mode'
      using errcode = '22023';
  end if;

  select batch.*
  into v_batch
  from public.weighing_batches as batch
  where batch.id = p_batch_id
  for update;

  if not found then
    raise exception 'Weighing batch not found'
      using errcode = 'P0002';
  end if;

  if v_batch.created_by <> auth.uid()
    and not public.current_staff_has_role(array['owner', 'admin']) then
    raise exception 'Only the batch creator or a supervisor may set intake mode'
      using errcode = '42501';
  end if;

  if v_batch.intake_mode = v_mode then
    return v_batch;
  end if;

  if v_batch.status <> 'DRAFT' then
    raise exception 'Submitted intake mode is immutable'
      using errcode = '55000';
  end if;

  if exists (
    select 1
    from public.bag_weights as bag
    where bag.batch_id = v_batch.id
  ) then
    raise exception 'Set intake mode before the first bag'
      using errcode = '55000';
  end if;

  if v_mode = 'FARMER_CONSIGNMENT' then
    select crop.category
    into v_crop_category
    from public.crop_types as crop
    where crop.crop_type_id = v_batch.crop_type_id
      and crop.active = true;

    if v_crop_category is distinct from 'BEAN' then
      raise exception 'Farmer consignment is currently available for beans only'
        using errcode = '22023';
    end if;
  end if;

  update public.weighing_batches as batch
  set
    intake_mode = v_mode,
    intake_mode_set_at = now(),
    intake_mode_set_by = auth.uid(),
    updated_at = now()
  where batch.id = v_batch.id
  returning batch.* into v_batch;

  return v_batch;
end;
$$;

create or replace function public.accept_farmer_consignment(
  p_batch_id uuid,
  p_location_id text,
  p_moisture_deduction_centi_pyitha bigint,
  p_waste_deduction_centi_pyitha bigint,
  p_tare_deduction_centi_pyitha bigint,
  p_notes text,
  p_request_id uuid
)
returns public.consignment_lots
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_batch public.weighing_batches%rowtype;
  v_existing public.consignment_lots%rowtype;
  v_lot public.consignment_lots%rowtype;
  v_moisture bigint := coalesce(p_moisture_deduction_centi_pyitha, 0);
  v_waste bigint := coalesce(p_waste_deduction_centi_pyitha, 0);
  v_tare bigint := coalesce(p_tare_deduction_centi_pyitha, 0);
  v_net bigint;
  v_notes text := nullif(btrim(coalesce(p_notes, '')), '');
begin
  perform public.require_staff_roles(array['owner', 'admin', 'accountant']);

  if p_batch_id is null or p_request_id is null then
    raise exception 'Batch id and request id are required'
      using errcode = '22023';
  end if;

  if p_location_id is null or btrim(p_location_id) = '' then
    raise exception 'An active stock location is required'
      using errcode = '22023';
  end if;

  if v_moisture < 0 or v_waste < 0 or v_tare < 0 then
    raise exception 'Consignment deductions cannot be negative'
      using errcode = '22023';
  end if;

  if v_notes is not null and char_length(v_notes) > 500 then
    raise exception 'Consignment notes are too long'
      using errcode = '22001';
  end if;

  select lot.*
  into v_existing
  from public.consignment_lots as lot
  where lot.acceptance_request_id = p_request_id;

  if found then
    if v_existing.batch_id <> p_batch_id
      or v_existing.location_id <> p_location_id
      or v_existing.moisture_deduction_centi_pyitha <> v_moisture
      or v_existing.waste_deduction_centi_pyitha <> v_waste
      or v_existing.tare_deduction_centi_pyitha <> v_tare then
      raise exception 'Consignment request id was reused with different data'
        using errcode = '23514';
    end if;
    return v_existing;
  end if;

  select batch.*
  into v_batch
  from public.weighing_batches as batch
  where batch.id = p_batch_id
  for update;

  if not found then
    raise exception 'Weighing batch not found'
      using errcode = 'P0002';
  end if;

  if v_batch.status <> 'SUBMITTED' then
    raise exception 'Only a submitted weighing batch may become consignment'
      using errcode = '55000';
  end if;

  if v_batch.intake_mode <> 'FARMER_CONSIGNMENT' then
    raise exception 'This weighing batch is not marked as farmer consignment'
      using errcode = '55000';
  end if;

  if not exists (
    select 1
    from public.crop_types as crop
    where crop.crop_type_id = v_batch.crop_type_id
      and crop.category = 'BEAN'
      and crop.active = true
  ) then
    raise exception 'Farmer consignment is currently available for beans only'
      using errcode = '22023';
  end if;

  if not exists (
    select 1
    from public.stock_locations as location
    where location.location_id = p_location_id
      and location.active = true
  ) then
    raise exception 'Active stock location not found'
      using errcode = '23503';
  end if;

  select lot.*
  into v_existing
  from public.consignment_lots as lot
  where lot.batch_id = v_batch.id;

  if found then
    if v_existing.location_id = p_location_id
      and v_existing.moisture_deduction_centi_pyitha = v_moisture
      and v_existing.waste_deduction_centi_pyitha = v_waste
      and v_existing.tare_deduction_centi_pyitha = v_tare then
      return v_existing;
    end if;
    raise exception 'This weighing batch already has a different consignment lot'
      using errcode = '23505';
  end if;

  if v_batch.total_bags <= 0
    or v_batch.total_gross_weight_centi_pyitha <= 0 then
    raise exception 'Submitted weighing totals are empty'
      using errcode = '23514';
  end if;

  v_net := v_batch.total_gross_weight_centi_pyitha
    - v_moisture
    - v_waste
    - v_tare;

  if v_net <= 0 then
    raise exception 'Deductions must be less than gross weight'
      using errcode = '22023';
  end if;

  insert into public.consignment_lots (
    lot_ref,
    acceptance_request_id,
    batch_id,
    business_date,
    customer_id,
    customer_name,
    crop_type_id,
    crop_name,
    location_id,
    actual_bags,
    gross_weight_centi_pyitha,
    moisture_deduction_centi_pyitha,
    waste_deduction_centi_pyitha,
    tare_deduction_centi_pyitha,
    original_net_weight_centi_pyitha,
    available_weight_centi_pyitha,
    status,
    notes,
    accepted_by
  )
  values (
    public.next_consignment_lot_ref(v_batch.business_date),
    p_request_id,
    v_batch.id,
    v_batch.business_date,
    v_batch.customer_id,
    v_batch.customer_name,
    v_batch.crop_type_id,
    v_batch.crop_name,
    p_location_id,
    v_batch.total_bags,
    v_batch.total_gross_weight_centi_pyitha,
    v_moisture,
    v_waste,
    v_tare,
    v_net,
    v_net,
    'OPEN',
    v_notes,
    auth.uid()
  )
  returning * into v_lot;

  insert into public.consignment_movements (
    request_id,
    lot_id,
    movement_type,
    business_date,
    quantity_centi_pyitha,
    balance_after_centi_pyitha,
    notes,
    actor_user_id
  )
  values (
    p_request_id,
    v_lot.id,
    'DEPOSIT',
    v_lot.business_date,
    v_lot.original_net_weight_centi_pyitha,
    v_lot.available_weight_centi_pyitha,
    v_notes,
    auth.uid()
  );

  return v_lot;
end;
$$;

revoke all on function public.set_weighing_intake_mode(uuid, text)
  from public;
revoke all on function public.accept_farmer_consignment(
  uuid, text, bigint, bigint, bigint, text, uuid
) from public;

grant execute on function public.set_weighing_intake_mode(uuid, text)
  to authenticated;
grant execute on function public.accept_farmer_consignment(
  uuid, text, bigint, bigint, bigint, text, uuid
) to authenticated;

grant execute on function public.set_weighing_intake_mode(uuid, text)
  to service_role;
grant execute on function public.accept_farmer_consignment(
  uuid, text, bigint, bigint, bigint, text, uuid
) to service_role;

alter table public.consignment_document_counters enable row level security;
alter table public.consignment_document_counters force row level security;
alter table public.consignment_lots enable row level security;
alter table public.consignment_lots force row level security;
alter table public.consignment_movements enable row level security;
alter table public.consignment_movements force row level security;

revoke all privileges on table public.consignment_document_counters
  from anon, authenticated;
revoke all privileges on table public.consignment_lots
  from anon, authenticated;
revoke all privileges on table public.consignment_movements
  from anon, authenticated;

grant select on table public.consignment_lots to authenticated;
grant select on table public.consignment_movements to authenticated;

drop policy if exists "Active staff can read consignment lots"
  on public.consignment_lots;
create policy "Active staff can read consignment lots"
  on public.consignment_lots
  for select
  to authenticated
  using (public.current_staff_is_active());

drop policy if exists "Active staff can read consignment movements"
  on public.consignment_movements;
create policy "Active staff can read consignment movements"
  on public.consignment_movements
  for select
  to authenticated
  using (public.current_staff_is_active());

alter table public.weighing_batches replica identity full;
alter table public.consignment_lots replica identity full;
alter table public.consignment_movements replica identity full;

do $$
begin
  if exists (
    select 1 from pg_publication where pubname = 'supabase_realtime'
  ) and not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'consignment_lots'
  ) then
    alter publication supabase_realtime
      add table public.consignment_lots;
  end if;

  if exists (
    select 1 from pg_publication where pubname = 'supabase_realtime'
  ) and not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'consignment_movements'
  ) then
    alter publication supabase_realtime
      add table public.consignment_movements;
  end if;
end;
$$;

comment on table public.consignment_lots is
  'Farmer-owned beans held in warehouse custody; never mix with pwal-yon-owned inventory.';
comment on table public.consignment_movements is
  'Append-only custody quantity ledger. This first slice posts DEPOSIT; later sale/withdrawal RPCs append movements.';
comment on function public.accept_farmer_consignment(
  uuid, text, bigint, bigint, bigint, text, uuid
) is
  'Accepts one submitted FARMER_CONSIGNMENT weighing batch as an idempotent farmer-owned custody lot.';

notify pgrst, 'reload schema';

commit;
