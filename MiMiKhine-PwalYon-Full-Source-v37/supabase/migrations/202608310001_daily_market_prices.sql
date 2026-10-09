-- Mi Mi Khine Pwal Yon: daily bean/chili market prices and trend reporting.
-- Safe to run more than once in Supabase Dashboard > SQL Editor.
--
-- One record represents one crop/condition/pricing-unit for one business day.
-- The natural-key constraint makes the UI's "save today's whole sheet" action
-- idempotent, including retries from the PC-local offline queue.

create extension if not exists pgcrypto;

create table if not exists public.market_prices (
  id uuid primary key default gen_random_uuid(),
  business_date date not null default ((timezone('Asia/Yangon', now()))::date),
  crop_type_id text not null,
  crop_name text not null,
  category text not null,
  condition text not null default 'STANDARD',
  price_unit_pyitha numeric(8, 2) not null,
  price_mmk bigint not null,
  source_note text,
  created_by uuid not null default auth.uid(),
  updated_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint market_prices_category_valid check (
    category in ('bean', 'chili')
  ),
  constraint market_prices_condition_valid check (
    condition in ('STANDARD', 'WET', 'DRY', 'MIXED')
  ),
  constraint market_prices_unit_valid check (
    price_unit_pyitha > 0 and price_unit_pyitha <= 1000
  ),
  constraint market_prices_value_valid check (
    price_mmk > 0 and price_mmk <= 10000000000
  ),
  constraint market_prices_daily_natural_key unique (
    business_date,
    crop_type_id,
    condition,
    price_unit_pyitha
  )
);

create index if not exists market_prices_crop_date_idx
  on public.market_prices (crop_type_id, condition, business_date desc);

create index if not exists market_prices_date_category_idx
  on public.market_prices (business_date desc, category, crop_type_id);

create or replace function public.set_market_prices_updated_fields()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  new.updated_at = now();
  new.updated_by = auth.uid();
  return new;
end;
$$;

drop trigger if exists market_prices_set_updated_fields on public.market_prices;
create trigger market_prices_set_updated_fields
before update on public.market_prices
for each row execute function public.set_market_prices_updated_fields();

alter table public.market_prices enable row level security;
alter table public.market_prices force row level security;

revoke all on table public.market_prices from anon;
revoke all on table public.market_prices from authenticated;
grant select on table public.market_prices to authenticated;
grant insert (
  business_date,
  crop_type_id,
  crop_name,
  category,
  condition,
  price_unit_pyitha,
  price_mmk,
  source_note
) on table public.market_prices to authenticated;
grant update (
  crop_name,
  category,
  price_mmk,
  source_note
) on table public.market_prices to authenticated;
grant all on table public.market_prices to service_role;

drop policy if exists "Active staff can read market prices" on public.market_prices;
create policy "Active staff can read market prices"
on public.market_prices
for select
to authenticated
using (public.current_staff_is_active());

drop policy if exists "Accounting staff can insert market prices" on public.market_prices;
create policy "Accounting staff can insert market prices"
on public.market_prices
for insert
to authenticated
with check (
  public.current_staff_has_role(array['owner', 'admin', 'accountant'])
  and created_by = (select auth.uid())
  and updated_by = (select auth.uid())
);

drop policy if exists "Accounting staff can correct market prices" on public.market_prices;
create policy "Accounting staff can correct market prices"
on public.market_prices
for update
to authenticated
using (public.current_staff_has_role(array['owner', 'admin', 'accountant']))
with check (public.current_staff_has_role(array['owner', 'admin', 'accountant']));

-- The browser and its offline queue call one idempotent RPC.  The conflict
-- columns remain immutable while an existing daily row can be corrected.
create or replace function public.upsert_market_price(
  p_business_date date,
  p_crop_type_id text,
  p_crop_name text,
  p_category text,
  p_condition text,
  p_price_unit_pyitha numeric,
  p_price_mmk bigint,
  p_source_note text default null
)
returns public.market_prices
language plpgsql
security invoker
set search_path = ''
as $$
declare
  saved public.market_prices;
begin
  insert into public.market_prices (
    business_date,
    crop_type_id,
    crop_name,
    category,
    condition,
    price_unit_pyitha,
    price_mmk,
    source_note
  )
  values (
    p_business_date,
    p_crop_type_id,
    p_crop_name,
    p_category,
    p_condition,
    p_price_unit_pyitha,
    p_price_mmk,
    nullif(trim(p_source_note), '')
  )
  on conflict (
    business_date,
    crop_type_id,
    condition,
    price_unit_pyitha
  ) do update
  set crop_name = excluded.crop_name,
      category = excluded.category,
      price_mmk = excluded.price_mmk,
      source_note = excluded.source_note
  returning * into saved;

  return saved;
end;
$$;

revoke all on function public.upsert_market_price(
  date, text, text, text, text, numeric, bigint, text
) from public;
grant execute on function public.upsert_market_price(
  date, text, text, text, text, numeric, bigint, text
) to authenticated;

alter table public.market_prices replica identity full;

do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'market_prices'
  ) then
    alter publication supabase_realtime add table public.market_prices;
  end if;
end
$$;
