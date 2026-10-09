-- Mi Mi Khine Pwal Yon: production-shaped weighing batches and master data.
--
-- Migration order:
--   1. 202608120001_bag_weights_realtime.sql
--   2. this file
--
-- This migration is deliberately additive.  The pilot bag_weights columns and
-- direct INSERT/UPDATE surface remain available while the browser moves to the
-- RPCs below.  Server triggers create/synchronise the parent batch, replace
-- client dates/references with server values, enforce state transitions, and
-- leave an audit trail.

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- Business clock and server-side document numbers
-- ---------------------------------------------------------------------------

create table if not exists public.business_settings (
  singleton boolean primary key default true,
  business_timezone text not null default 'Asia/Yangon',
  business_date_override date,
  batch_ref_prefix text not null default 'WB',
  voucher_ref_prefix text not null default 'WR',
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users (id) on delete set null,

  constraint business_settings_singleton check (singleton = true),
  constraint business_settings_timezone_present check (
    length(trim(business_timezone)) between 1 and 64
  ),
  constraint business_settings_batch_prefix_valid check (
    batch_ref_prefix ~ '^[A-Z]{1,6}$'
  ),
  constraint business_settings_voucher_prefix_valid check (
    voucher_ref_prefix ~ '^[A-Z]{1,6}$'
  )
);

insert into public.business_settings (singleton)
values (true)
on conflict (singleton) do nothing;

create or replace function public.validate_business_timezone()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  perform timezone(new.business_timezone, now());
  new.updated_at = now();
  if auth.uid() is not null then
    new.updated_by = auth.uid();
  end if;
  return new;
exception
  when invalid_parameter_value then
    raise exception 'Unknown business timezone: %', new.business_timezone
      using errcode = '22023';
end;
$$;

drop trigger if exists business_settings_validate_timezone
  on public.business_settings;
create trigger business_settings_validate_timezone
before insert or update on public.business_settings
for each row execute function public.validate_business_timezone();

create or replace function public.get_business_date()
returns date
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    settings.business_date_override,
    timezone(settings.business_timezone, now())::date
  )
  from public.business_settings as settings
  where settings.singleton = true
  union all
  select timezone('Asia/Yangon', now())::date
  where not exists (
    select 1
    from public.business_settings as settings
    where settings.singleton = true
  )
  limit 1;
$$;

revoke all on function public.get_business_date() from public;
grant execute on function public.get_business_date() to authenticated;
grant execute on function public.get_business_date() to service_role;

create table if not exists public.document_counters (
  document_type text not null,
  business_date date not null,
  last_value bigint not null default 0,
  updated_at timestamptz not null default now(),

  constraint document_counters_pk primary key (document_type, business_date),
  constraint document_counters_type_valid check (
    document_type in ('WB', 'WR')
  ),
  constraint document_counters_value_nonnegative check (last_value >= 0)
);

create or replace function public.next_document_ref(
  p_document_type text,
  p_business_date date
)
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_type text := upper(trim(coalesce(p_document_type, '')));
  v_date date := coalesce(p_business_date, public.get_business_date());
  v_prefix text;
  v_value bigint;
begin
  if v_type not in ('WB', 'WR') then
    raise exception 'Unsupported document type: %', p_document_type
      using errcode = '22023';
  end if;

  select case
    when v_type = 'WB' then settings.batch_ref_prefix
    else settings.voucher_ref_prefix
  end
  into v_prefix
  from public.business_settings as settings
  where settings.singleton = true;

  v_prefix := coalesce(v_prefix, v_type);

  insert into public.document_counters (
    document_type,
    business_date,
    last_value,
    updated_at
  )
  values (v_type, v_date, 1, now())
  on conflict (document_type, business_date)
  do update set
    last_value = public.document_counters.last_value + 1,
    updated_at = now()
  returning last_value into v_value;

  return v_prefix
    || '-'
    || to_char(v_date, 'YYYYMMDD')
    || '-'
    || lpad(v_value::text, 4, '0');
end;
$$;

revoke all on function public.next_document_ref(text, date) from public;
grant execute on function public.next_document_ref(text, date) to service_role;

-- ---------------------------------------------------------------------------
-- Durable master data
-- ---------------------------------------------------------------------------

create sequence if not exists public.farmer_code_seq as bigint start with 1;
create sequence if not exists public.crop_type_code_seq as bigint start with 1;
create sequence if not exists public.product_code_seq as bigint start with 1;
create sequence if not exists public.stock_location_code_seq as bigint start with 1;

create table if not exists public.crop_types (
  crop_type_id text primary key default (
    'C-' || lpad(nextval('public.crop_type_code_seq')::text, 3, '0')
  ),
  name text not null,
  category text not null default 'BEAN',
  settlement_method text not null default 'BATCH',
  default_tare_centi_pyitha integer not null default 20,
  pricing_divisor_pyitha integer not null default 20,
  active boolean not null default true,
  notes text,
  created_by uuid default auth.uid() references auth.users (id) on delete set null,
  updated_by uuid default auth.uid() references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- New records use C-###.  The wider safe-code form is intentional: pilot
  -- rows may already contain immutable legacy IDs such as VALIDATION-CROP,
  -- and those IDs must be preserved when the parent/master FKs are added.
  constraint crop_types_id_valid check (
    crop_type_id ~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,79}$'
  ),
  constraint crop_types_name_present check (length(trim(name)) between 1 and 120),
  constraint crop_types_category_valid check (
    category in ('BEAN', 'CHILI', 'OTHER')
  ),
  constraint crop_types_settlement_valid check (
    settlement_method in ('BATCH', 'PER_BAG')
  ),
  constraint crop_types_tare_valid check (
    default_tare_centi_pyitha between 0 and 10000
  ),
  constraint crop_types_divisor_valid check (
    pricing_divisor_pyitha between 1 and 10000
  ),
  constraint crop_types_chili_per_bag check (
    category <> 'CHILI' or settlement_method = 'PER_BAG'
  )
);

create unique index if not exists crop_types_name_unique_idx
  on public.crop_types (lower(trim(name)));

create table if not exists public.farmers (
  customer_id text primary key default (
    'F-' || lpad(nextval('public.farmer_code_seq')::text, 3, '0')
  ),
  full_name text not null,
  phone_normalized text,
  phone_display text,
  village text,
  township text,
  acres numeric(12, 2) not null default 0,
  primary_crop_type_id text references public.crop_types (crop_type_id)
    on update restrict on delete restrict,
  risk_level text not null default 'LOW',
  opening_debt_kyat bigint not null default 0,
  active boolean not null default true,
  notes text,
  created_by uuid default auth.uid() references auth.users (id) on delete set null,
  updated_by uuid default auth.uid() references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- New records use F-###; safe legacy IDs (for example
  -- VALIDATION-CUSTOMER) remain valid so existing bag rows are never
  -- rewritten or deleted during the FK backfill.
  constraint farmers_id_valid check (
    customer_id ~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,79}$'
  ),
  constraint farmers_name_present check (length(trim(full_name)) between 1 and 160),
  constraint farmers_phone_valid check (
    phone_normalized is null or phone_normalized ~ '^[0-9]{7,15}$'
  ),
  constraint farmers_acres_nonnegative check (acres >= 0),
  constraint farmers_risk_valid check (
    risk_level in ('LOW', 'MEDIUM', 'HIGH', 'BLACKLISTED')
  ),
  constraint farmers_opening_debt_nonnegative check (opening_debt_kyat >= 0)
);

create unique index if not exists farmers_phone_unique_idx
  on public.farmers (phone_normalized)
  where phone_normalized is not null;
create index if not exists farmers_name_search_idx
  on public.farmers (lower(full_name));
create index if not exists farmers_active_risk_idx
  on public.farmers (active, risk_level, customer_id);

create table if not exists public.products (
  product_id text primary key default (
    'P-' || lpad(nextval('public.product_code_seq')::text, 3, '0')
  ),
  name text not null,
  category text not null default 'OTHER',
  unit_name text not null,
  whole_units_only boolean not null default true,
  default_unit_price_kyat bigint not null default 0,
  reorder_level numeric(14, 3) not null default 0,
  active boolean not null default true,
  notes text,
  created_by uuid default auth.uid() references auth.users (id) on delete set null,
  updated_by uuid default auth.uid() references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint products_id_valid check (product_id ~ '^P-[0-9]{3,}$'),
  constraint products_name_present check (length(trim(name)) between 1 and 160),
  constraint products_category_present check (length(trim(category)) between 1 and 100),
  constraint products_unit_present check (length(trim(unit_name)) between 1 and 40),
  constraint products_price_nonnegative check (default_unit_price_kyat >= 0),
  constraint products_reorder_nonnegative check (reorder_level >= 0),
  constraint products_whole_reorder_valid check (
    not whole_units_only or reorder_level = trunc(reorder_level)
  )
);

create unique index if not exists products_name_unique_idx
  on public.products (lower(trim(name)));
create index if not exists products_active_category_idx
  on public.products (active, category, product_id);

create table if not exists public.stock_locations (
  location_id text primary key default (
    'WH-' || lpad(nextval('public.stock_location_code_seq')::text, 3, '0')
  ),
  name text not null,
  location_type text not null default 'WAREHOUSE',
  active boolean not null default true,
  notes text,
  created_by uuid default auth.uid() references auth.users (id) on delete set null,
  updated_by uuid default auth.uid() references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint stock_locations_id_valid check (location_id ~ '^WH-[0-9]{3,}$'),
  constraint stock_locations_name_present check (length(trim(name)) between 1 and 160),
  constraint stock_locations_type_valid check (
    location_type in ('WAREHOUSE', 'SHOP', 'OTHER')
  )
);

create unique index if not exists stock_locations_name_unique_idx
  on public.stock_locations (lower(trim(name)));

create or replace function public.set_master_updated_at_and_actor()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  new.updated_at = now();
  if auth.uid() is not null then
    new.updated_by = auth.uid();
  end if;
  return new;
end;
$$;

drop trigger if exists crop_types_set_updated_at on public.crop_types;
create trigger crop_types_set_updated_at
before update on public.crop_types
for each row execute function public.set_master_updated_at_and_actor();

drop trigger if exists farmers_set_updated_at on public.farmers;
create trigger farmers_set_updated_at
before update on public.farmers
for each row execute function public.set_master_updated_at_and_actor();

drop trigger if exists products_set_updated_at on public.products;
create trigger products_set_updated_at
before update on public.products
for each row execute function public.set_master_updated_at_and_actor();

drop trigger if exists stock_locations_set_updated_at on public.stock_locations;
create trigger stock_locations_set_updated_at
before update on public.stock_locations
for each row execute function public.set_master_updated_at_and_actor();

-- Seed only the concrete records already shown by the pilot.  ON CONFLICT does
-- not overwrite production edits.  Stock quantities are intentionally absent:
-- a later immutable stock-movement ledger will be their source of truth.
insert into public.crop_types (
  crop_type_id,
  name,
  category,
  settlement_method,
  default_tare_centi_pyitha,
  pricing_divisor_pyitha,
  active
)
values
  ('C-001', 'မတ်ပဲ',     'BEAN',  'BATCH',   20, 20, true),
  ('C-002', 'မတ်ပဲ RAW', 'BEAN',  'BATCH',   20, 20, true),
  ('C-003', 'ပဲတီစိမ်း',  'BEAN',  'BATCH',   20, 20, true),
  ('C-004', 'ငရုတ်',      'CHILI', 'PER_BAG', 10,  1, true),
  ('C-005', 'ပဲစင်းငုံ',  'BEAN',  'BATCH',   20, 20, true),
  ('C-006', 'ကုလားပဲ',    'BEAN',  'BATCH',   20, 20, true),
  ('C-007', 'ထောပတ်ပဲ',   'BEAN',  'BATCH',   20, 20, true)
on conflict (crop_type_id) do nothing;

-- Preserve any crop IDs already used by pilot rows before adding the FK.
insert into public.crop_types (
  crop_type_id,
  name,
  category,
  settlement_method,
  default_tare_centi_pyitha,
  pricing_divisor_pyitha,
  active,
  notes
)
select distinct on (bags.crop_type_id)
  bags.crop_type_id,
  coalesce(nullif(trim(bags.crop_name), ''), 'သီးနှံ')
    || ' [' || bags.crop_type_id || ']',
  case when coalesce(bags.crop_name, '') ilike '%ငရုတ်%'
    then 'CHILI' else 'BEAN' end,
  case when coalesce(bags.crop_name, '') ilike '%ငရုတ်%'
    then 'PER_BAG' else 'BATCH' end,
  case when coalesce(bags.crop_name, '') ilike '%ငရုတ်%'
    then 10 else 20 end,
  case when coalesce(bags.crop_name, '') ilike '%ငရုတ်%'
    then 1 else 20 end,
  true,
  'Pilot bag row မှ migration ဖြင့် ထည့်ထားသည်'
from public.bag_weights as bags
where not exists (
  select 1
  from public.crop_types as crops
  where crops.crop_type_id = bags.crop_type_id
)
order by bags.crop_type_id, bags.created_at
on conflict (crop_type_id) do nothing;

insert into public.farmers (
  customer_id,
  full_name,
  phone_normalized,
  phone_display,
  village,
  township,
  acres,
  primary_crop_type_id,
  risk_level,
  opening_debt_kyat,
  active
)
values
  (
    'F-001', 'ဦးမင်းဦး', '09421778023', '09 421 778 023',
    'ကန်သာရွာ', 'ပဲခူးမြို့နယ်', 18, 'C-001', 'LOW', 0, true
  ),
  (
    'F-014', 'ဒေါ်ရီရီဝင်း', '09795320118', '09 795 320 118',
    'လယ်တီရွာ', 'သနပ်ပင်မြို့နယ်', 12, 'C-003', 'MEDIUM', 0, true
  ),
  (
    'F-027', 'ဦးကျော်ဆွေ', '09250443891', '09 250 443 891',
    'သာစည်ရွာ', 'ဝေါမြို့နယ်', 25, 'C-004', 'BLACKLISTED', 0, true
  )
on conflict (customer_id) do nothing;

-- Preserve any farmer IDs already referenced by pilot rows before adding FK.
insert into public.farmers (
  customer_id,
  full_name,
  risk_level,
  active,
  notes
)
select distinct on (bags.customer_id)
  bags.customer_id,
  coalesce(nullif(trim(bags.customer_name), ''), bags.customer_id),
  'MEDIUM',
  true,
  'Pilot bag row မှ migration ဖြင့် ထည့်ထားသည်'
from public.bag_weights as bags
where not exists (
  select 1
  from public.farmers as farmers
  where farmers.customer_id = bags.customer_id
)
order by bags.customer_id, bags.created_at
on conflict (customer_id) do nothing;

insert into public.products (
  product_id,
  name,
  category,
  unit_name,
  whole_units_only,
  default_unit_price_kyat,
  reorder_level,
  active
)
values
  ('P-001', 'ဆန်',          'စားသောက်ကုန်', 'အိတ်',    true,  85000, 5, true),
  ('P-002', 'မြေဆီ',        'မြေဆီ',        'အိတ်',    true,  72000, 5, true),
  ('P-003', 'မျိုးစေ့',      'မျိုးစေ့',      'အိတ်',    true,  95000, 5, true),
  ('P-004', 'ပြောင်းမျိုး',   'မျိုးစေ့',      'အိတ်',    true, 110000, 5, true),
  ('P-005', 'စိုက်ပျိုးဆေး', 'စိုက်ပျိုးဆေး', 'ပုလင်း', true,  18500, 5, true)
on conflict (product_id) do nothing;

insert into public.stock_locations (
  location_id,
  name,
  location_type,
  active,
  notes
)
values (
  'WH-001',
  'ပင်မဂိုဒေါင်',
  'WAREHOUSE',
  true,
  'ပွဲရုံ၏ ပုံသေဂိုဒေါင်'
)
on conflict (location_id) do nothing;

-- Continue each human-readable code above the largest imported/seeded code.
select setval(
  'public.crop_type_code_seq',
  greatest(
    1,
    coalesce((
      select max(substring(crop_type_id from '[0-9]+$')::bigint)
      from public.crop_types
      where crop_type_id ~ '^C-[0-9]{3,18}$'
    ), 1)
  ),
  true
);

select setval(
  'public.farmer_code_seq',
  greatest(
    1,
    coalesce((
      select max(substring(customer_id from '[0-9]+$')::bigint)
      from public.farmers
      where customer_id ~ '^F-[0-9]{3,18}$'
    ), 1)
  ),
  true
);

select setval(
  'public.product_code_seq',
  greatest(
    1,
    coalesce((
      select max(substring(product_id from '[0-9]+$')::bigint)
      from public.products
      where product_id ~ '^P-[0-9]{3,18}$'
    ), 1)
  ),
  true
);

select setval(
  'public.stock_location_code_seq',
  greatest(
    1,
    coalesce((
      select max(substring(location_id from '[0-9]+$')::bigint)
      from public.stock_locations
      where location_id ~ '^WH-[0-9]{3,18}$'
    ), 1)
  ),
  true
);

-- ---------------------------------------------------------------------------
-- Master-data RLS and staff-role safeguards
-- ---------------------------------------------------------------------------

alter table public.business_settings enable row level security;
alter table public.business_settings force row level security;
alter table public.document_counters enable row level security;
alter table public.document_counters force row level security;
alter table public.crop_types enable row level security;
alter table public.crop_types force row level security;
alter table public.farmers enable row level security;
alter table public.farmers force row level security;
alter table public.products enable row level security;
alter table public.products force row level security;
alter table public.stock_locations enable row level security;
alter table public.stock_locations force row level security;

revoke all on table public.business_settings from anon, authenticated;
revoke all on table public.document_counters from anon, authenticated;
revoke all on table public.crop_types from anon, authenticated;
revoke all on table public.farmers from anon, authenticated;
revoke all on table public.products from anon, authenticated;
revoke all on table public.stock_locations from anon, authenticated;

grant select on table public.business_settings to authenticated;
grant update (
  business_timezone,
  business_date_override,
  batch_ref_prefix,
  voucher_ref_prefix
) on table public.business_settings to authenticated;

grant select on table public.crop_types to authenticated;
grant insert (
  name,
  category,
  settlement_method,
  default_tare_centi_pyitha,
  pricing_divisor_pyitha,
  notes
) on table public.crop_types to authenticated;
grant update (
  name,
  category,
  settlement_method,
  default_tare_centi_pyitha,
  pricing_divisor_pyitha,
  active,
  notes
) on table public.crop_types to authenticated;

grant select on table public.farmers to authenticated;
grant insert (
  full_name,
  phone_normalized,
  phone_display,
  village,
  township,
  acres,
  primary_crop_type_id,
  risk_level,
  notes
) on table public.farmers to authenticated;
grant update (
  full_name,
  phone_normalized,
  phone_display,
  village,
  township,
  acres,
  primary_crop_type_id,
  risk_level,
  active,
  notes
) on table public.farmers to authenticated;

grant select on table public.products to authenticated;
grant insert (
  name,
  category,
  unit_name,
  whole_units_only,
  default_unit_price_kyat,
  reorder_level,
  notes
) on table public.products to authenticated;
grant update (
  name,
  category,
  unit_name,
  whole_units_only,
  default_unit_price_kyat,
  reorder_level,
  active,
  notes
) on table public.products to authenticated;

grant select on table public.stock_locations to authenticated;
grant insert (
  name,
  location_type,
  notes
) on table public.stock_locations to authenticated;
grant update (
  name,
  location_type,
  active,
  notes
) on table public.stock_locations to authenticated;

grant usage, select on sequence public.farmer_code_seq to authenticated;
grant usage, select on sequence public.crop_type_code_seq to authenticated;
grant usage, select on sequence public.product_code_seq to authenticated;
grant usage, select on sequence public.stock_location_code_seq to authenticated;

grant all on table public.business_settings to service_role;
grant all on table public.document_counters to service_role;
grant all on table public.crop_types to service_role;
grant all on table public.farmers to service_role;
grant all on table public.products to service_role;
grant all on table public.stock_locations to service_role;
grant all on sequence public.farmer_code_seq to service_role;
grant all on sequence public.crop_type_code_seq to service_role;
grant all on sequence public.product_code_seq to service_role;
grant all on sequence public.stock_location_code_seq to service_role;

-- Activation metadata is trigger-owned.  The pilot migration exposed these
-- columns for UPDATE; remove that privilege while retaining the UI's
-- display_name/role/active update surface.
revoke update (activated_at, activated_by)
  on table public.staff_members from authenticated;

drop policy if exists "Active staff can read business settings"
  on public.business_settings;
create policy "Active staff can read business settings"
on public.business_settings
for select to authenticated
using (public.current_staff_is_active());

drop policy if exists "Owners can update business settings"
  on public.business_settings;
create policy "Owners can update business settings"
on public.business_settings
for update to authenticated
using (public.current_staff_has_role(array['owner', 'admin']))
with check (public.current_staff_has_role(array['owner', 'admin']));

drop policy if exists "Active staff can read crop types" on public.crop_types;
create policy "Active staff can read crop types"
on public.crop_types
for select to authenticated
using (public.current_staff_is_active());

drop policy if exists "Owners can create crop types" on public.crop_types;
create policy "Owners can create crop types"
on public.crop_types
for insert to authenticated
with check (public.current_staff_has_role(array['owner', 'admin']));

drop policy if exists "Owners can update crop types" on public.crop_types;
create policy "Owners can update crop types"
on public.crop_types
for update to authenticated
using (public.current_staff_has_role(array['owner', 'admin']))
with check (public.current_staff_has_role(array['owner', 'admin']));

drop policy if exists "Active staff can read farmers" on public.farmers;
create policy "Active staff can read farmers"
on public.farmers
for select to authenticated
using (public.current_staff_is_active());

drop policy if exists "Accounting staff can create farmers" on public.farmers;
create policy "Accounting staff can create farmers"
on public.farmers
for insert to authenticated
with check (
  public.current_staff_has_role(array['owner', 'admin', 'accountant'])
);

drop policy if exists "Accounting staff can update farmers" on public.farmers;
create policy "Accounting staff can update farmers"
on public.farmers
for update to authenticated
using (public.current_staff_has_role(array['owner', 'admin', 'accountant']))
with check (public.current_staff_has_role(array['owner', 'admin', 'accountant']));

drop policy if exists "Active staff can read products" on public.products;
create policy "Active staff can read products"
on public.products
for select to authenticated
using (public.current_staff_is_active());

drop policy if exists "Owners can create products" on public.products;
create policy "Owners can create products"
on public.products
for insert to authenticated
with check (public.current_staff_has_role(array['owner', 'admin']));

drop policy if exists "Owners can update products" on public.products;
create policy "Owners can update products"
on public.products
for update to authenticated
using (public.current_staff_has_role(array['owner', 'admin']))
with check (public.current_staff_has_role(array['owner', 'admin']));

drop policy if exists "Active staff can read stock locations"
  on public.stock_locations;
create policy "Active staff can read stock locations"
on public.stock_locations
for select to authenticated
using (public.current_staff_is_active());

drop policy if exists "Owners can create stock locations"
  on public.stock_locations;
create policy "Owners can create stock locations"
on public.stock_locations
for insert to authenticated
with check (public.current_staff_has_role(array['owner', 'admin']));

drop policy if exists "Owners can update stock locations"
  on public.stock_locations;
create policy "Owners can update stock locations"
on public.stock_locations
for update to authenticated
using (public.current_staff_has_role(array['owner', 'admin']))
with check (public.current_staff_has_role(array['owner', 'admin']));

create or replace function public.guard_staff_member_role_changes()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_role text;
  v_other_active_owners integer;
begin
  if auth.uid() is not null then
    select staff.role
    into v_actor_role
    from public.staff_members as staff
    where staff.user_id = auth.uid()
      and staff.active = true;

    if v_actor_role is null then
      raise exception 'Only active staff may manage staff records'
        using errcode = '42501';
    end if;

    if (old.role = 'owner' or new.role = 'owner')
      and v_actor_role <> 'owner' then
      raise exception 'Only an owner may change an owner account'
        using errcode = '42501';
    end if;

    if old.active is distinct from new.active then
      if new.active then
        new.activated_at = now();
        new.activated_by = auth.uid();
      end if;
    end if;
  end if;

  if old.role = 'owner'
    and old.active = true
    and (new.role <> 'owner' or new.active = false) then
    -- Serialise concurrent owner demotions/deactivations.  Without this lock,
    -- two owner rows could each observe the other as active and both commit.
    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended(
        'public.staff_members.active_owner_guard',
        0
      )
    );

    select count(*)::integer
    into v_other_active_owners
    from public.staff_members as staff
    where staff.user_id <> old.user_id
      and staff.role = 'owner'
      and staff.active = true;

    if v_other_active_owners = 0 then
      raise exception 'The last active owner cannot be deactivated or demoted'
        using errcode = '23514';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists staff_members_guard_owner_role on public.staff_members;
create trigger staff_members_guard_owner_role
before update on public.staff_members
for each row execute function public.guard_staff_member_role_changes();

-- Role/activation changes are financial-system access changes, so retain an
-- append-only snapshot even if either account is later disabled or removed.
-- UUIDs are deliberately stored without auth.users FKs so account deletion
-- cannot rewrite or cascade-delete the audit history.
create table if not exists public.staff_access_audit_events (
  id bigint generated always as identity primary key,
  target_user_id uuid not null,
  actor_user_id uuid,
  actor_role text,
  old_role text not null,
  new_role text not null,
  old_active boolean not null,
  new_active boolean not null,
  occurred_at timestamptz not null default now(),

  constraint staff_access_audit_actor_role_valid check (
    actor_role is null
    or actor_role in ('owner', 'admin', 'weigher', 'accountant', 'viewer')
  )
);

create index if not exists staff_access_audit_target_time_idx
  on public.staff_access_audit_events (
    target_user_id,
    occurred_at desc,
    id desc
  );

create or replace function public.audit_staff_access_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_role text;
begin
  if auth.uid() = new.user_id then
    v_actor_role := old.role;
  else
    select staff.role
    into v_actor_role
    from public.staff_members as staff
    where staff.user_id = auth.uid();
  end if;

  insert into public.staff_access_audit_events (
    target_user_id,
    actor_user_id,
    actor_role,
    old_role,
    new_role,
    old_active,
    new_active
  )
  values (
    new.user_id,
    auth.uid(),
    v_actor_role,
    old.role,
    new.role,
    old.active,
    new.active
  );

  return new;
end;
$$;

drop trigger if exists staff_members_audit_access_change
  on public.staff_members;
create trigger staff_members_audit_access_change
after update of role, active on public.staff_members
for each row
when (
  old.role is distinct from new.role
  or old.active is distinct from new.active
)
execute function public.audit_staff_access_change();

create or replace function public.prevent_staff_access_audit_mutation()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  raise exception 'Staff access audit events are append-only'
    using errcode = '55000';
end;
$$;

revoke all on function public.audit_staff_access_change() from public;
revoke all on function public.prevent_staff_access_audit_mutation() from public;

drop trigger if exists staff_access_audit_prevent_update_delete
  on public.staff_access_audit_events;
create trigger staff_access_audit_prevent_update_delete
before update or delete on public.staff_access_audit_events
for each row execute function public.prevent_staff_access_audit_mutation();

drop trigger if exists staff_access_audit_prevent_truncate
  on public.staff_access_audit_events;
create trigger staff_access_audit_prevent_truncate
before truncate on public.staff_access_audit_events
for each statement execute function public.prevent_staff_access_audit_mutation();

alter table public.staff_access_audit_events enable row level security;
alter table public.staff_access_audit_events force row level security;
revoke all on table public.staff_access_audit_events from anon, authenticated;
revoke all on table public.staff_access_audit_events from service_role;
grant select on table public.staff_access_audit_events to authenticated;
grant select, insert on table public.staff_access_audit_events to service_role;
grant usage, select on sequence public.staff_access_audit_events_id_seq
  to service_role;

drop policy if exists "Owners can read staff access audit"
  on public.staff_access_audit_events;
create policy "Owners can read staff access audit"
on public.staff_access_audit_events
for select to authenticated
using (public.current_staff_has_role(array['owner', 'admin']));

-- Internal role assertion used by SECURITY DEFINER workflow RPCs.
create or replace function public.require_staff_roles(required_roles text[])
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null
    or not public.current_staff_has_role(required_roles) then
    raise exception 'Active staff role required'
      using errcode = '42501';
  end if;
end;
$$;

revoke all on function public.require_staff_roles(text[]) from public;
grant execute on function public.require_staff_roles(text[]) to service_role;

-- ---------------------------------------------------------------------------
-- Parent weighing batches, audit history, and compatibility backfill
-- ---------------------------------------------------------------------------

create table if not exists public.weighing_batches (
  id uuid primary key default gen_random_uuid(),
  batch_ref text not null,
  voucher_ref text,
  business_date date not null default public.get_business_date(),
  customer_id text not null references public.farmers (customer_id)
    on update restrict on delete restrict,
  customer_name text not null,
  crop_type_id text not null references public.crop_types (crop_type_id)
    on update restrict on delete restrict,
  crop_name text not null,
  status text not null default 'DRAFT',
  total_bags integer not null default 0,
  total_gross_weight_centi_pyitha bigint not null default 0,
  device_id text not null default 'WEB-MOBILE',
  -- Actor UUID snapshots intentionally have no auth.users FK.  This preserves
  -- historical attribution and permits backfill even if a pilot Auth account
  -- was removed; all new writes still enforce auth.uid()/active staff.
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),
  submitted_by uuid,
  submitted_at timestamptz,
  settled_by uuid,
  settled_at timestamptz,
  voided_by uuid,
  voided_at timestamptz,
  void_reason text,
  updated_at timestamptz not null default now(),

  constraint weighing_batches_batch_ref_present check (
    length(trim(batch_ref)) between 1 and 80
  ),
  constraint weighing_batches_voucher_ref_present check (
    voucher_ref is null or length(trim(voucher_ref)) between 1 and 80
  ),
  constraint weighing_batches_customer_name_present check (
    length(trim(customer_name)) between 1 and 160
  ),
  constraint weighing_batches_crop_name_present check (
    length(trim(crop_name)) between 1 and 160
  ),
  constraint weighing_batches_status_valid check (
    status in ('DRAFT', 'SUBMITTED', 'SETTLED', 'VOID')
  ),
  constraint weighing_batches_submitted_voucher check (
    status not in ('SUBMITTED', 'SETTLED') or voucher_ref is not null
  ),
  constraint weighing_batches_totals_nonnegative check (
    total_bags >= 0 and total_gross_weight_centi_pyitha >= 0
  ),
  constraint weighing_batches_submitted_nonempty check (
    status not in ('SUBMITTED', 'SETTLED') or total_bags > 0
  ),
  constraint weighing_batches_submitted_metadata check (
    status = 'DRAFT'
    or status = 'VOID'
    or (submitted_by is not null and submitted_at is not null)
  ),
  constraint weighing_batches_settled_metadata check (
    status <> 'SETTLED'
    or (
      submitted_by is not null
      and submitted_at is not null
      and settled_by is not null
      and settled_at is not null
    )
  ),
  constraint weighing_batches_void_metadata check (
    status <> 'VOID'
    or (
      voided_by is not null
      and voided_at is not null
      and length(trim(coalesce(void_reason, ''))) >= 3
    )
  )
);

create unique index if not exists weighing_batches_batch_ref_unique_idx
  on public.weighing_batches (batch_ref);
create unique index if not exists weighing_batches_voucher_ref_unique_idx
  on public.weighing_batches (voucher_ref)
  where voucher_ref is not null;
create index if not exists weighing_batches_history_idx
  on public.weighing_batches (business_date desc, created_at desc, id desc);
create index if not exists weighing_batches_customer_history_idx
  on public.weighing_batches (customer_id, business_date desc, created_at desc);
create index if not exists weighing_batches_status_history_idx
  on public.weighing_batches (status, business_date desc, created_at desc);

create table if not exists public.weighing_audit_events (
  id bigint generated always as identity primary key,
  batch_id uuid not null references public.weighing_batches (id)
    on delete restrict,
  bag_weight_id uuid references public.bag_weights (id) on delete restrict,
  action text not null,
  from_status text,
  to_status text,
  reason text,
  details jsonb not null default '{}'::jsonb,
  actor_user_id uuid,
  occurred_at timestamptz not null default now(),

  constraint weighing_audit_action_valid check (
    action in (
      'BATCH_CREATED',
      'BATCH_BACKFILLED',
      'BAG_ADDED',
      'BAG_VOIDED',
      'BATCH_SUBMITTED',
      'BATCH_VOIDED',
      'BATCH_SETTLED'
    )
  ),
  constraint weighing_audit_details_object check (
    jsonb_typeof(details) = 'object'
  )
);

create index if not exists weighing_audit_batch_time_idx
  on public.weighing_audit_events (batch_id, occurred_at desc, id desc);

create or replace function public.prevent_weighing_audit_mutation()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  raise exception 'Weighing audit events are append-only'
    using errcode = '55000';
end;
$$;

revoke all on function public.prevent_weighing_audit_mutation() from public;

drop trigger if exists weighing_audit_prevent_update_delete
  on public.weighing_audit_events;
create trigger weighing_audit_prevent_update_delete
before update or delete on public.weighing_audit_events
for each row execute function public.prevent_weighing_audit_mutation();

drop trigger if exists weighing_audit_prevent_truncate
  on public.weighing_audit_events;
create trigger weighing_audit_prevent_truncate
before truncate on public.weighing_audit_events
for each statement execute function public.prevent_weighing_audit_mutation();

-- Deterministic backfill: one parent for every historical pilot batch_id.  The
-- legacy client batch_ref is retained only when it is globally unique across
-- both the source rows and existing parents; all other parents receive a safe
-- full-UUID MIG- reference.  No bag row is deleted.
insert into public.weighing_batches (
  id,
  batch_ref,
  voucher_ref,
  business_date,
  customer_id,
  customer_name,
  crop_type_id,
  crop_name,
  status,
  total_bags,
  total_gross_weight_centi_pyitha,
  device_id,
  created_by,
  created_at,
  submitted_by,
  submitted_at,
  voided_by,
  voided_at,
  void_reason,
  updated_at
)
select
  grouped.batch_id,
  coalesce(
    case
      when grouped.legacy_batch_ref is not null
        and (
          select count(distinct source_bags.batch_id)
          from public.bag_weights as source_bags
          where nullif(trim(source_bags.batch_ref), '')
            = grouped.legacy_batch_ref
        ) = 1
        and not exists (
          select 1
          from public.weighing_batches as existing
          where existing.batch_ref = grouped.legacy_batch_ref
            and existing.id <> grouped.batch_id
        )
      then grouped.legacy_batch_ref
    end,
    'MIG-' || replace(grouped.business_date::text, '-', '')
      || '-' || grouped.batch_id::text
  ),
  case when grouped.batch_status = 'SUBMITTED'
    then public.next_document_ref('WR', grouped.business_date)
    else null
  end,
  grouped.business_date,
  grouped.customer_id,
  grouped.customer_name,
  grouped.crop_type_id,
  grouped.crop_name,
  grouped.batch_status,
  grouped.total_bags,
  grouped.total_weight,
  grouped.device_id,
  grouped.created_by,
  grouped.created_at,
  case when grouped.batch_status = 'SUBMITTED'
    then grouped.created_by else null end,
  case when grouped.batch_status = 'SUBMITTED'
    then grouped.updated_at else null end,
  case when grouped.batch_status = 'VOID'
    then grouped.created_by else null end,
  case when grouped.batch_status = 'VOID'
    then grouped.updated_at else null end,
  case when grouped.batch_status = 'VOID'
    then 'Legacy pilot batch backfill' else null end,
  grouped.updated_at
from (
  select
    bags.batch_id,
    min(nullif(trim(bags.batch_ref), '')) as legacy_batch_ref,
    min(bags.business_date) as business_date,
    (array_agg(bags.customer_id order by bags.created_at, bags.id))[1]
      as customer_id,
    (array_agg(bags.customer_name order by bags.created_at, bags.id))[1]
      as customer_name,
    (array_agg(bags.crop_type_id order by bags.created_at, bags.id))[1]
      as crop_type_id,
    (array_agg(bags.crop_name order by bags.created_at, bags.id))[1]
      as crop_name,
    case
      when count(*) filter (where bags.status <> 'VOID') = 0 then 'VOID'
      when bool_or(bags.status = 'SUBMITTED') then 'SUBMITTED'
      else 'DRAFT'
    end as batch_status,
    count(*) filter (where bags.status <> 'VOID')::integer as total_bags,
    coalesce(sum(bags.weight_centi_pyitha)
      filter (where bags.status <> 'VOID'), 0)::bigint as total_weight,
    (array_agg(bags.device_id order by bags.created_at, bags.id))[1]
      as device_id,
    (array_agg(bags.created_by order by bags.created_at, bags.id))[1]
      as created_by,
    min(bags.created_at) as created_at,
    max(bags.updated_at) as updated_at
  from public.bag_weights as bags
  group by bags.batch_id
) as grouped
where not exists (
  select 1
  from public.weighing_batches as existing
  where existing.id = grouped.batch_id
)
on conflict (id) do nothing;

-- Repair partially submitted legacy groups and make batch_ref mean one thing
-- everywhere: the immutable WB batch reference.  WR voucher_ref remains a
-- header-only receipt number.  This is a status/reference normalisation only;
-- measurement rows are never deleted or rewritten.
update public.bag_weights as bags
set
  status = case
    when batch.status = 'VOID' then 'VOID'
    when bags.status = 'VOID' then 'VOID'
    when batch.status in ('SUBMITTED', 'SETTLED') then 'SUBMITTED'
    else 'DRAFT'
  end,
  batch_ref = batch.batch_ref
from public.weighing_batches as batch
where batch.id = bags.batch_id
  and (
    bags.batch_ref is distinct from batch.batch_ref
    or (
      (batch.status = 'VOID' or bags.status <> 'VOID')
      and bags.status is distinct from case
        when batch.status = 'VOID' then 'VOID'
        when batch.status in ('SUBMITTED', 'SETTLED') then 'SUBMITTED'
        else 'DRAFT'
      end
    )
  );

insert into public.weighing_audit_events (
  batch_id,
  action,
  details,
  actor_user_id,
  occurred_at
)
select
  batch.id,
  'BATCH_BACKFILLED',
  jsonb_build_object(
    'source', 'bag_weights pilot',
    'batch_ref', batch.batch_ref,
    'total_bags', batch.total_bags,
    'total_weight_centi_pyitha', batch.total_gross_weight_centi_pyitha
  ),
  batch.created_by,
  batch.updated_at
from public.weighing_batches as batch
where exists (
    select 1
    from public.bag_weights as bags
    where bags.batch_id = batch.id
  )
  and not exists (
    select 1
    from public.weighing_audit_events as audit
    where audit.batch_id = batch.id
      and audit.action = 'BATCH_BACKFILLED'
  );

-- Add the FK after the no-delete parent backfill.
do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.bag_weights'::regclass
      and conname = 'bag_weights_batch_fk'
  ) then
    alter table public.bag_weights
      add constraint bag_weights_batch_fk
      foreign key (batch_id)
      references public.weighing_batches (id)
      on update restrict
      on delete restrict
      not valid;

    alter table public.bag_weights
      validate constraint bag_weights_batch_fk;
  end if;
end
$$;

-- ---------------------------------------------------------------------------
-- Batch invariants and compatibility triggers
-- ---------------------------------------------------------------------------

create or replace function public.recalculate_weighing_batch(p_batch_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.weighing_batches as batch
  set
    total_bags = aggregate_values.total_bags,
    total_gross_weight_centi_pyitha = aggregate_values.total_weight,
    updated_at = now()
  from (
    select
      count(*) filter (where bags.status <> 'VOID')::integer as total_bags,
      coalesce(sum(bags.weight_centi_pyitha)
        filter (where bags.status <> 'VOID'), 0)::bigint as total_weight
    from public.bag_weights as bags
    where bags.batch_id = p_batch_id
  ) as aggregate_values
  where batch.id = p_batch_id;
end;
$$;

revoke all on function public.recalculate_weighing_batch(uuid) from public;
grant execute on function public.recalculate_weighing_batch(uuid) to service_role;

create or replace function public.guard_weighing_batch_update()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.id is distinct from old.id
    or new.batch_ref is distinct from old.batch_ref
    or new.business_date is distinct from old.business_date
    or new.customer_id is distinct from old.customer_id
    or new.customer_name is distinct from old.customer_name
    or new.crop_type_id is distinct from old.crop_type_id
    or new.crop_name is distinct from old.crop_name
    or new.device_id is distinct from old.device_id
    or new.created_by is distinct from old.created_by
    or new.created_at is distinct from old.created_at
    or (
      old.voucher_ref is not null
      and new.voucher_ref is distinct from old.voucher_ref
    )
    or (
      old.submitted_at is not null
      and (
        new.submitted_by is distinct from old.submitted_by
        or new.submitted_at is distinct from old.submitted_at
      )
    )
    or (
      old.settled_at is not null
      and (
        new.settled_by is distinct from old.settled_by
        or new.settled_at is distinct from old.settled_at
      )
    )
    or (
      old.voided_at is not null
      and (
        new.voided_by is distinct from old.voided_by
        or new.voided_at is distinct from old.voided_at
        or new.void_reason is distinct from old.void_reason
      )
    ) then
    raise exception 'Submitted batch identity and server fields are immutable'
      using errcode = '23514';
  end if;

  if new.status is distinct from old.status then
    if not (
      (old.status = 'DRAFT' and new.status in ('SUBMITTED', 'VOID'))
      or (old.status = 'SUBMITTED' and new.status in ('SETTLED', 'VOID'))
    ) then
      raise exception 'Invalid batch state transition: % to %',
        old.status,
        new.status
        using errcode = '23514';
    end if;
  end if;

  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists weighing_batches_guard_update on public.weighing_batches;
create trigger weighing_batches_guard_update
before update on public.weighing_batches
for each row execute function public.guard_weighing_batch_update();

-- The pilot inserts bags directly.  If its parent does not yet exist this
-- trigger creates a server-owned parent from the authoritative master rows.
-- It also overwrites client business_date/ref/name snapshots with server data.
create or replace function public.prepare_bag_weight_write()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_batch public.weighing_batches%rowtype;
  v_farmer public.farmers%rowtype;
  v_crop public.crop_types%rowtype;
begin
  if tg_op = 'INSERT' then
    if new.created_by is null then
      new.created_by = auth.uid();
    end if;

    if auth.uid() is not null and new.created_by <> auth.uid() then
      raise exception 'Bag creator must match the signed-in staff member'
        using errcode = '42501';
    end if;

    if auth.uid() is not null then
      new.created_at = now();
      new.updated_at = now();
    end if;

    select batch.*
    into v_batch
    from public.weighing_batches as batch
    where batch.id = new.batch_id
    for update;

    if not found then
      perform public.require_staff_roles(
        array['owner', 'admin', 'weigher', 'accountant']
      );

      select farmer.* into v_farmer
      from public.farmers as farmer
      where farmer.customer_id = new.customer_id
        and farmer.active = true;

      if not found then
        raise exception 'Active farmer not found: %', new.customer_id
          using errcode = '23503';
      end if;

      if v_farmer.risk_level = 'BLACKLISTED' then
        raise exception 'This farmer is blocked from new weighing batches'
          using errcode = '42501';
      end if;

      select crop.* into v_crop
      from public.crop_types as crop
      where crop.crop_type_id = new.crop_type_id
        and crop.active = true;

      if not found then
        raise exception 'Active crop type not found: %', new.crop_type_id
          using errcode = '23503';
      end if;

      insert into public.weighing_batches (
        id,
        batch_ref,
        business_date,
        customer_id,
        customer_name,
        crop_type_id,
        crop_name,
        status,
        device_id,
        created_by
      )
      values (
        new.batch_id,
        public.next_document_ref('WB', public.get_business_date()),
        public.get_business_date(),
        v_farmer.customer_id,
        v_farmer.full_name,
        v_crop.crop_type_id,
        v_crop.name,
        'DRAFT',
        coalesce(nullif(trim(new.device_id), ''), 'WEB-MOBILE'),
        new.created_by
      )
      returning * into v_batch;

      insert into public.weighing_audit_events (
        batch_id,
        action,
        details,
        actor_user_id
      )
      values (
        v_batch.id,
        'BATCH_CREATED',
        jsonb_build_object('source', 'legacy direct bag insert'),
        new.created_by
      );
    end if;

    if v_batch.status <> 'DRAFT' then
      raise exception 'Bags may only be added to a DRAFT batch'
        using errcode = '23514';
    end if;

    if v_batch.customer_id <> new.customer_id
      or v_batch.crop_type_id <> new.crop_type_id then
      raise exception 'Bag farmer/crop does not match the batch'
        using errcode = '23514';
    end if;

    if auth.uid() is not null
      and v_batch.created_by <> auth.uid()
      and not public.current_staff_has_role(
        array['owner', 'admin', 'accountant']
      ) then
      raise exception 'Only the creator or accounting staff may add bags'
        using errcode = '42501';
    end if;

    new.business_date = v_batch.business_date;
    new.batch_ref = v_batch.batch_ref;
    new.customer_id = v_batch.customer_id;
    new.customer_name = v_batch.customer_name;
    new.crop_type_id = v_batch.crop_type_id;
    new.crop_name = v_batch.crop_name;
    new.status = 'DRAFT';
    new.device_id = coalesce(
      nullif(trim(new.device_id), ''),
      v_batch.device_id,
      'WEB-MOBILE'
    );
    return new;
  end if;

  perform public.require_staff_roles(
    array['owner', 'admin', 'weigher', 'accountant']
  );

  select batch.*
  into v_batch
  from public.weighing_batches as batch
  where batch.id = old.batch_id
  for update;

  if not found then
    raise exception 'Parent weighing batch not found'
      using errcode = '23503';
  end if;

  if new.id is distinct from old.id
    or new.batch_id is distinct from old.batch_id
    or new.business_date is distinct from old.business_date
    or new.bag_no is distinct from old.bag_no
    or new.customer_id is distinct from old.customer_id
    or new.customer_name is distinct from old.customer_name
    or new.crop_type_id is distinct from old.crop_type_id
    or new.crop_name is distinct from old.crop_name
    or new.weight_centi_pyitha is distinct from old.weight_centi_pyitha
    or new.condition is distinct from old.condition
    or new.moisture_pct is distinct from old.moisture_pct
    or new.quality_grade is distinct from old.quality_grade
    or new.device_id is distinct from old.device_id
    or new.created_by is distinct from old.created_by
    or new.created_at is distinct from old.created_at then
    raise exception 'Bag measurements are immutable; VOID and re-enter instead'
      using errcode = '23514';
  end if;

  -- The bag detail always carries the WB reference.  WR is a header-only
  -- receipt/voucher reference and must never replace the batch identity.
  new.batch_ref = v_batch.batch_ref;

  if new.status is distinct from old.status then
    if old.status = 'DRAFT' and new.status = 'SUBMITTED' then
      if v_batch.status = 'DRAFT' then
        -- Legacy compatibility: the first row update submits the parent.  The
        -- statement-level trigger will update every other non-void bag.
        update public.weighing_batches
        set
          voucher_ref = coalesce(
            voucher_ref,
            public.next_document_ref('WR', business_date)
          ),
          status = 'SUBMITTED',
          submitted_by = auth.uid(),
          submitted_at = now()
        where id = v_batch.id
        returning * into v_batch;

        insert into public.weighing_audit_events (
          batch_id,
          action,
          from_status,
          to_status,
          details,
          actor_user_id
        )
        values (
          v_batch.id,
          'BATCH_SUBMITTED',
          'DRAFT',
          'SUBMITTED',
          jsonb_build_object('source', 'legacy direct bag update'),
          auth.uid()
        );
      elsif v_batch.status <> 'SUBMITTED' then
        raise exception 'Batch cannot be submitted from status %', v_batch.status
          using errcode = '23514';
      end if;

      new.batch_ref = v_batch.batch_ref;
      new.status = 'SUBMITTED';
    elsif new.status = 'VOID'
      and old.status in ('DRAFT', 'SUBMITTED') then
      if old.status = 'SUBMITTED'
        and not public.current_staff_has_role(
          array['owner', 'admin', 'accountant']
        ) then
        raise exception 'Accounting role is required to void a submitted bag'
          using errcode = '42501';
      end if;
      new.batch_ref = v_batch.batch_ref;
    else
      raise exception 'Invalid bag state transition: % to %',
        old.status,
        new.status
        using errcode = '23514';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists bag_weights_prepare_write on public.bag_weights;
create trigger bag_weights_prepare_write
before insert or update on public.bag_weights
for each row execute function public.prepare_bag_weight_write();

create or replace function public.after_bag_weight_write()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    insert into public.weighing_audit_events (
      batch_id,
      bag_weight_id,
      action,
      to_status,
      details,
      actor_user_id
    )
    values (
      new.batch_id,
      new.id,
      'BAG_ADDED',
      new.status,
      jsonb_build_object(
        'bag_no', new.bag_no,
        'weight_centi_pyitha', new.weight_centi_pyitha,
        'device_id', new.device_id
      ),
      new.created_by
    );
  elsif old.status <> 'VOID' and new.status = 'VOID' then
    insert into public.weighing_audit_events (
      batch_id,
      bag_weight_id,
      action,
      from_status,
      to_status,
      reason,
      details,
      actor_user_id
    )
    values (
      new.batch_id,
      new.id,
      'BAG_VOIDED',
      old.status,
      new.status,
      coalesce(
        nullif(current_setting('app.weighing_void_reason', true), ''),
        'Legacy direct status update'
      ),
      jsonb_build_object(
        'bag_no', new.bag_no,
        'weight_centi_pyitha', new.weight_centi_pyitha
      ),
      auth.uid()
    );
  end if;

  perform public.recalculate_weighing_batch(new.batch_id);
  return new;
end;
$$;

drop trigger if exists bag_weights_after_write on public.bag_weights;
create trigger bag_weights_after_write
after insert or update of status on public.bag_weights
for each row execute function public.after_bag_weight_write();

-- Keep all rows coherent when the pilot submits by UPDATE ... WHERE batch_id.
create or replace function public.finish_legacy_bag_submission()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.bag_weights as bags
  set
    status = 'SUBMITTED',
    batch_ref = batch.batch_ref
  from public.weighing_batches as batch
  where bags.batch_id = batch.id
    and batch.status = 'SUBMITTED'
    and bags.status = 'DRAFT';
  return null;
end;
$$;

drop trigger if exists bag_weights_finish_legacy_submission
  on public.bag_weights;
create trigger bag_weights_finish_legacy_submission
after update of status on public.bag_weights
for each statement execute function public.finish_legacy_bag_submission();

-- ---------------------------------------------------------------------------
-- Authenticated workflow RPCs
-- ---------------------------------------------------------------------------

create or replace function public.create_weighing_batch(
  p_customer_id text,
  p_crop_type_id text,
  p_device_id text default 'WEB-MOBILE',
  p_batch_id uuid default null
)
returns public.weighing_batches
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_farmer public.farmers%rowtype;
  v_crop public.crop_types%rowtype;
  v_batch public.weighing_batches%rowtype;
  v_id uuid := coalesce(p_batch_id, gen_random_uuid());
  v_date date := public.get_business_date();
begin
  perform public.require_staff_roles(
    array['owner', 'admin', 'weigher', 'accountant']
  );

  if p_batch_id is not null then
    select batch.*
    into v_batch
    from public.weighing_batches as batch
    where batch.id = p_batch_id;

    if found then
      if v_batch.customer_id <> p_customer_id
        or v_batch.crop_type_id <> p_crop_type_id then
        raise exception 'Existing batch identity does not match this request'
          using errcode = '23514';
      end if;
      return v_batch;
    end if;
  end if;

  select farmer.* into v_farmer
  from public.farmers as farmer
  where farmer.customer_id = p_customer_id
    and farmer.active = true;

  if not found then
    raise exception 'Active farmer not found: %', p_customer_id
      using errcode = '23503';
  end if;

  if v_farmer.risk_level = 'BLACKLISTED' then
    raise exception 'This farmer is blocked from new weighing batches'
      using errcode = '42501';
  end if;

  select crop.* into v_crop
  from public.crop_types as crop
  where crop.crop_type_id = p_crop_type_id
    and crop.active = true;

  if not found then
    raise exception 'Active crop type not found: %', p_crop_type_id
      using errcode = '23503';
  end if;

  insert into public.weighing_batches (
    id,
    batch_ref,
    business_date,
    customer_id,
    customer_name,
    crop_type_id,
    crop_name,
    status,
    device_id,
    created_by
  )
  values (
    v_id,
    public.next_document_ref('WB', v_date),
    v_date,
    v_farmer.customer_id,
    v_farmer.full_name,
    v_crop.crop_type_id,
    v_crop.name,
    'DRAFT',
    coalesce(nullif(trim(p_device_id), ''), 'WEB-MOBILE'),
    auth.uid()
  )
  on conflict (id) do nothing
  returning * into v_batch;

  -- Two offline/retry requests can race with the same client UUID.  The loser
  -- returns the already-created equivalent header instead of failing, while a
  -- UUID reused for different master data remains a hard error.
  if not found then
    select batch.*
    into v_batch
    from public.weighing_batches as batch
    where batch.id = v_id;

    if not found then
      raise exception 'Batch idempotency conflict could not be resolved'
        using errcode = '40001';
    end if;

    if v_batch.customer_id <> p_customer_id
      or v_batch.crop_type_id <> p_crop_type_id then
      raise exception 'Existing batch identity does not match this request'
        using errcode = '23514';
    end if;

    return v_batch;
  end if;

  insert into public.weighing_audit_events (
    batch_id,
    action,
    to_status,
    details,
    actor_user_id
  )
  values (
    v_batch.id,
    'BATCH_CREATED',
    v_batch.status,
    jsonb_build_object('batch_ref', v_batch.batch_ref),
    auth.uid()
  );

  return v_batch;
end;
$$;

create or replace function public.add_bag_weight(
  p_batch_id uuid,
  p_bag_id uuid,
  p_bag_no integer,
  p_weight_centi_pyitha integer,
  p_condition text default null,
  p_moisture_pct numeric default null,
  p_quality_grade text default null,
  p_device_id text default null
)
returns public.bag_weights
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_batch public.weighing_batches%rowtype;
  v_existing public.bag_weights%rowtype;
  v_bag public.bag_weights%rowtype;
  v_condition text := nullif(upper(trim(coalesce(p_condition, ''))), '');
  v_quality_grade text := nullif(
    upper(trim(coalesce(p_quality_grade, ''))),
    ''
  );
begin
  perform public.require_staff_roles(
    array['owner', 'admin', 'weigher', 'accountant']
  );

  -- A retry remains idempotent even after the batch was submitted while the
  -- device was offline.  Validate the immutable measurement before checking
  -- the current parent state.
  select bags.*
  into v_existing
  from public.bag_weights as bags
  where bags.id = p_bag_id;

  if found then
    if v_existing.batch_id <> p_batch_id
      or v_existing.bag_no <> p_bag_no
      or v_existing.weight_centi_pyitha <> p_weight_centi_pyitha
      or v_existing.condition is distinct from v_condition
      or v_existing.moisture_pct is distinct from p_moisture_pct
      or v_existing.quality_grade is distinct from v_quality_grade then
      raise exception 'Idempotency key already belongs to a different bag'
        using errcode = '23505';
    end if;
    return v_existing;
  end if;

  select batch.*
  into v_batch
  from public.weighing_batches as batch
  where batch.id = p_batch_id
  for update;

  if not found then
    raise exception 'Weighing batch not found: %', p_batch_id
      using errcode = '23503';
  end if;

  -- Recheck after acquiring the parent lock: a concurrent retry may have
  -- inserted this client UUID just before submitting the batch.
  select bags.*
  into v_existing
  from public.bag_weights as bags
  where bags.id = p_bag_id;

  if found then
    if v_existing.batch_id <> p_batch_id
      or v_existing.bag_no <> p_bag_no
      or v_existing.weight_centi_pyitha <> p_weight_centi_pyitha
      or v_existing.condition is distinct from v_condition
      or v_existing.moisture_pct is distinct from p_moisture_pct
      or v_existing.quality_grade is distinct from v_quality_grade then
      raise exception 'Idempotency key already belongs to a different bag'
        using errcode = '23505';
    end if;
    return v_existing;
  end if;

  if v_batch.status <> 'DRAFT' then
    raise exception 'Bags may only be added to a DRAFT batch'
      using errcode = '23514';
  end if;

  if v_batch.created_by <> auth.uid()
    and not public.current_staff_has_role(
      array['owner', 'admin', 'accountant']
    ) then
    raise exception 'Only the creator or accounting staff may add bags'
      using errcode = '42501';
  end if;

  insert into public.bag_weights (
    id,
    batch_id,
    batch_ref,
    business_date,
    bag_no,
    customer_id,
    customer_name,
    crop_type_id,
    crop_name,
    weight_centi_pyitha,
    condition,
    moisture_pct,
    quality_grade,
    status,
    device_id,
    created_by
  )
  values (
    p_bag_id,
    v_batch.id,
    v_batch.batch_ref,
    v_batch.business_date,
    p_bag_no,
    v_batch.customer_id,
    v_batch.customer_name,
    v_batch.crop_type_id,
    v_batch.crop_name,
    p_weight_centi_pyitha,
    v_condition,
    p_moisture_pct,
    v_quality_grade,
    'DRAFT',
    coalesce(nullif(trim(p_device_id), ''), v_batch.device_id),
    auth.uid()
  )
  on conflict (id) do nothing
  returning * into v_bag;

  if not found then
    select bags.*
    into v_existing
    from public.bag_weights as bags
    where bags.id = p_bag_id;

    if not found then
      raise exception 'Bag idempotency conflict could not be resolved'
        using errcode = '40001';
    end if;

    if v_existing.batch_id <> p_batch_id
      or v_existing.bag_no <> p_bag_no
      or v_existing.weight_centi_pyitha <> p_weight_centi_pyitha
      or v_existing.condition is distinct from v_condition
      or v_existing.moisture_pct is distinct from p_moisture_pct
      or v_existing.quality_grade is distinct from v_quality_grade then
      raise exception 'Idempotency key already belongs to a different bag'
        using errcode = '23505';
    end if;

    return v_existing;
  end if;

  return v_bag;
end;
$$;

create or replace function public.submit_weighing_batch(p_batch_id uuid)
returns public.weighing_batches
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_batch public.weighing_batches%rowtype;
begin
  perform public.require_staff_roles(
    array['owner', 'admin', 'weigher', 'accountant']
  );

  select batch.*
  into v_batch
  from public.weighing_batches as batch
  where batch.id = p_batch_id
  for update;

  if not found then
    raise exception 'Weighing batch not found: %', p_batch_id
      using errcode = '23503';
  end if;

  if v_batch.status = 'SUBMITTED' then
    return v_batch;
  end if;

  if v_batch.status <> 'DRAFT' then
    raise exception 'Batch cannot be submitted from status %', v_batch.status
      using errcode = '23514';
  end if;

  if v_batch.created_by <> auth.uid()
    and not public.current_staff_has_role(
      array['owner', 'admin', 'accountant']
    ) then
    raise exception 'Only the creator or accounting staff may submit this batch'
      using errcode = '42501';
  end if;

  perform public.recalculate_weighing_batch(v_batch.id);
  select batch.* into v_batch
  from public.weighing_batches as batch
  where batch.id = p_batch_id
  for update;

  if v_batch.total_bags <= 0 then
    raise exception 'A batch must contain at least one non-void bag'
      using errcode = '23514';
  end if;

  update public.weighing_batches
  set
    voucher_ref = coalesce(
      voucher_ref,
      public.next_document_ref('WR', business_date)
    ),
    status = 'SUBMITTED',
    submitted_by = auth.uid(),
    submitted_at = now()
  where id = p_batch_id
  returning * into v_batch;

  update public.bag_weights
  set
    status = 'SUBMITTED',
    batch_ref = v_batch.batch_ref
  where batch_id = p_batch_id
    and status = 'DRAFT';

  insert into public.weighing_audit_events (
    batch_id,
    action,
    from_status,
    to_status,
    details,
    actor_user_id
  )
  values (
    v_batch.id,
    'BATCH_SUBMITTED',
    'DRAFT',
    'SUBMITTED',
    jsonb_build_object(
      'voucher_ref', v_batch.voucher_ref,
      'total_bags', v_batch.total_bags,
      'total_weight_centi_pyitha',
        v_batch.total_gross_weight_centi_pyitha
    ),
    auth.uid()
  );

  return v_batch;
end;
$$;

create or replace function public.void_bag_weight(
  p_bag_id uuid,
  p_reason text default 'Operator correction'
)
returns public.bag_weights
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_bag public.bag_weights%rowtype;
  v_batch public.weighing_batches%rowtype;
  v_reason text := trim(coalesce(p_reason, ''));
begin
  perform public.require_staff_roles(
    array['owner', 'admin', 'weigher', 'accountant']
  );

  if length(v_reason) < 3 then
    raise exception 'A reason of at least 3 characters is required'
      using errcode = '22023';
  end if;

  select bags.*
  into v_bag
  from public.bag_weights as bags
  where bags.id = p_bag_id;

  if not found then
    raise exception 'Bag weight not found: %', p_bag_id
      using errcode = '23503';
  end if;

  -- Lock parent before detail, matching submit/batch-void lock order and
  -- avoiding a header/detail deadlock under concurrent operators.
  select batch.*
  into v_batch
  from public.weighing_batches as batch
  where batch.id = v_bag.batch_id
  for update;

  select bags.*
  into v_bag
  from public.bag_weights as bags
  where bags.id = p_bag_id
  for update;

  if v_bag.status = 'VOID' then
    return v_bag;
  end if;

  if v_batch.status not in ('DRAFT', 'SUBMITTED') then
    raise exception 'A bag cannot be voided in a % batch', v_batch.status
      using errcode = '23514';
  end if;

  if v_batch.status = 'SUBMITTED'
    and not public.current_staff_has_role(
      array['owner', 'admin', 'accountant']
    ) then
    raise exception 'Accounting role is required to void a submitted bag'
      using errcode = '42501';
  end if;

  if v_batch.status = 'DRAFT'
    and v_batch.created_by <> auth.uid()
    and not public.current_staff_has_role(
      array['owner', 'admin', 'accountant']
    ) then
    raise exception 'Only the creator or accounting staff may void this bag'
      using errcode = '42501';
  end if;

  perform set_config('app.weighing_void_reason', v_reason, true);

  update public.bag_weights
  set status = 'VOID'
  where id = p_bag_id
  returning * into v_bag;

  perform set_config('app.weighing_void_reason', '', true);

  return v_bag;
end;
$$;

create or replace function public.void_weighing_batch(
  p_batch_id uuid,
  p_reason text default 'Operator cancelled draft batch'
)
returns public.weighing_batches
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_batch public.weighing_batches%rowtype;
  v_reason text := trim(coalesce(p_reason, ''));
  v_from_status text;
begin
  perform public.require_staff_roles(
    array['owner', 'admin', 'weigher', 'accountant']
  );

  if length(v_reason) < 3 then
    raise exception 'A reason of at least 3 characters is required'
      using errcode = '22023';
  end if;

  select batch.*
  into v_batch
  from public.weighing_batches as batch
  where batch.id = p_batch_id
  for update;

  if not found then
    raise exception 'Weighing batch not found: %', p_batch_id
      using errcode = '23503';
  end if;

  if v_batch.status = 'VOID' then
    return v_batch;
  end if;

  if v_batch.status = 'SETTLED' then
    raise exception 'Settled batches require a later accounting reversal flow'
      using errcode = '23514';
  end if;

  if v_batch.status = 'SUBMITTED'
    and not public.current_staff_has_role(
      array['owner', 'admin', 'accountant']
    ) then
    raise exception 'Accounting role is required to void a submitted batch'
      using errcode = '42501';
  end if;

  if v_batch.status = 'DRAFT'
    and v_batch.created_by <> auth.uid()
    and not public.current_staff_has_role(
      array['owner', 'admin', 'accountant']
    ) then
    raise exception 'Only the creator or accounting staff may void this batch'
      using errcode = '42501';
  end if;

  v_from_status := v_batch.status;

  -- Move the parent first so recalculating the last VOID detail cannot create
  -- an invalid zero-bag SUBMITTED header.  The transaction remains atomic.
  update public.weighing_batches
  set
    status = 'VOID',
    voided_by = auth.uid(),
    voided_at = now(),
    void_reason = v_reason
  where id = p_batch_id
  returning * into v_batch;

  perform set_config('app.weighing_void_reason', v_reason, true);

  update public.bag_weights
  set status = 'VOID'
  where batch_id = p_batch_id
    and status <> 'VOID';

  perform set_config('app.weighing_void_reason', '', true);

  perform public.recalculate_weighing_batch(p_batch_id);
  select batch.* into v_batch
  from public.weighing_batches as batch
  where batch.id = p_batch_id;

  insert into public.weighing_audit_events (
    batch_id,
    action,
    from_status,
    to_status,
    reason,
    details,
    actor_user_id
  )
  values (
    v_batch.id,
    'BATCH_VOIDED',
    v_from_status,
    'VOID',
    v_reason,
    jsonb_build_object('batch_ref', v_batch.batch_ref),
    auth.uid()
  );

  return v_batch;
end;
$$;

revoke all on function public.create_weighing_batch(text, text, text, uuid)
  from public;
revoke all on function public.add_bag_weight(
  uuid, uuid, integer, integer, text, numeric, text, text
) from public;
revoke all on function public.submit_weighing_batch(uuid) from public;
revoke all on function public.void_bag_weight(uuid, text) from public;
revoke all on function public.void_weighing_batch(uuid, text) from public;

grant execute on function public.create_weighing_batch(
  text, text, text, uuid
) to authenticated;
grant execute on function public.add_bag_weight(
  uuid, uuid, integer, integer, text, numeric, text, text
) to authenticated;
grant execute on function public.submit_weighing_batch(uuid) to authenticated;
grant execute on function public.void_bag_weight(uuid, text) to authenticated;
grant execute on function public.void_weighing_batch(uuid, text)
  to authenticated;

grant execute on function public.create_weighing_batch(
  text, text, text, uuid
) to service_role;
grant execute on function public.add_bag_weight(
  uuid, uuid, integer, integer, text, numeric, text, text
) to service_role;
grant execute on function public.submit_weighing_batch(uuid) to service_role;
grant execute on function public.void_bag_weight(uuid, text) to service_role;
grant execute on function public.void_weighing_batch(uuid, text)
  to service_role;

-- ---------------------------------------------------------------------------
-- Parent/audit RLS, grants, and realtime
-- ---------------------------------------------------------------------------

alter table public.weighing_batches enable row level security;
alter table public.weighing_batches force row level security;
alter table public.weighing_audit_events enable row level security;
alter table public.weighing_audit_events force row level security;

revoke all on table public.weighing_batches from anon, authenticated;
revoke all on table public.weighing_audit_events from anon, authenticated;
grant select on table public.weighing_batches to authenticated;
grant select on table public.weighing_audit_events to authenticated;
grant all on table public.weighing_batches to service_role;
revoke all on table public.weighing_audit_events from service_role;
grant select, insert on table public.weighing_audit_events to service_role;
grant usage, select on sequence public.weighing_audit_events_id_seq
  to service_role;

drop policy if exists "Active staff can read weighing batches"
  on public.weighing_batches;
create policy "Active staff can read weighing batches"
on public.weighing_batches
for select to authenticated
using (public.current_staff_is_active());

drop policy if exists "Active staff can read weighing audit"
  on public.weighing_audit_events;
create policy "Active staff can read weighing audit"
on public.weighing_audit_events
for select to authenticated
using (public.current_staff_is_active());

-- Direct pilot INSERT/UPDATE grants remain for backward compatibility, but
-- the trigger enforces the parent and lifecycle.  Prefer the RPCs for new UI.
alter table public.weighing_batches replica identity full;

do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'weighing_batches'
  ) then
    alter publication supabase_realtime
      add table public.weighing_batches;
  end if;
end
$$;
