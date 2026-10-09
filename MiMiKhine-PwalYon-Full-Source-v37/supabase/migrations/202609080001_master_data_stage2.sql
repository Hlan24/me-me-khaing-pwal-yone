-- Mi Mi Khine Pwal Yon: Stage 2 durable master data and opening balances.
--
-- This migration is additive and idempotent. It keeps operational history
-- separate from editable master records, disables destructive browser writes,
-- and makes opening-balance imports atomic, server-validated and auditable.

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- Farmer master fields used by the production UI
-- ---------------------------------------------------------------------------

alter table public.farmers
  add column if not exists nrc text,
  add column if not exists gender text,
  add column if not exists address text,
  add column if not exists land_type text,
  add column if not exists kyc_status text not null default 'PENDING';

alter table public.farmers
  drop constraint if exists farmers_gender_valid;
alter table public.farmers
  add constraint farmers_gender_valid check (
    gender is null or gender in ('MALE', 'FEMALE', 'UNDISCLOSED')
  );

alter table public.farmers
  drop constraint if exists farmers_kyc_status_valid;
alter table public.farmers
  add constraint farmers_kyc_status_valid check (
    kyc_status in ('COMPLETE', 'PENDING')
  );

alter table public.farmers
  drop constraint if exists farmers_nrc_length_valid;
alter table public.farmers
  add constraint farmers_nrc_length_valid check (
    nrc is null or length(trim(nrc)) between 1 and 80
  );

grant insert (
  nrc,
  gender,
  address,
  land_type,
  kyc_status
) on table public.farmers to authenticated;

grant update (
  nrc,
  gender,
  address,
  land_type,
  kyc_status
) on table public.farmers to authenticated;

grant insert (active) on table public.farmers to authenticated;
grant insert (active) on table public.crop_types to authenticated;
grant insert (active) on table public.products to authenticated;
grant insert (active) on table public.stock_locations to authenticated;

-- ---------------------------------------------------------------------------
-- Immutable opening-balance imports
-- ---------------------------------------------------------------------------

create sequence if not exists public.opening_balance_ref_seq as bigint start with 1;

create table if not exists public.opening_balance_imports (
  id uuid primary key default gen_random_uuid(),
  import_ref text not null unique,
  request_id uuid not null unique,
  business_date date not null default public.get_business_date(),
  import_type text not null,
  source_name text not null,
  notes text,
  row_count integer not null default 0,
  total_quantity numeric(20, 3) not null default 0,
  total_weight_centi_pyitha bigint not null default 0,
  total_principal_kyat bigint not null default 0,
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),

  constraint opening_balance_import_ref_valid check (
    import_ref ~ '^OB-[0-9]{8}-[0-9]{6,}$'
  ),
  constraint opening_balance_import_type_valid check (
    import_type in ('FARMER_DEBT', 'PRODUCT_STOCK', 'CROP_STOCK')
  ),
  constraint opening_balance_source_present check (
    length(trim(source_name)) between 1 and 200
  ),
  constraint opening_balance_notes_length check (
    notes is null or length(notes) <= 500
  ),
  constraint opening_balance_row_count_positive check (row_count >= 0),
  constraint opening_balance_totals_nonnegative check (
    total_quantity >= 0
    and total_weight_centi_pyitha >= 0
    and total_principal_kyat >= 0
  )
);

create table if not exists public.opening_balance_entries (
  id bigint generated always as identity primary key,
  import_id uuid not null references public.opening_balance_imports (id)
    on update restrict on delete restrict,
  line_no integer not null,
  entry_type text not null,
  customer_id text references public.farmers (customer_id)
    on update restrict on delete restrict,
  crop_type_id text references public.crop_types (crop_type_id)
    on update restrict on delete restrict,
  product_id text references public.products (product_id)
    on update restrict on delete restrict,
  location_id text references public.stock_locations (location_id)
    on update restrict on delete restrict,
  quantity numeric(20, 3),
  weight_centi_pyitha bigint,
  principal_kyat bigint,
  monthly_interest_rate numeric(7, 4),
  opening_date date,
  notes text,
  created_at timestamptz not null default now(),

  constraint opening_balance_entry_line_positive check (line_no > 0),
  constraint opening_balance_entry_type_valid check (
    entry_type in ('FARMER_DEBT', 'PRODUCT_STOCK', 'CROP_STOCK')
  ),
  constraint opening_balance_entry_notes_length check (
    notes is null or length(notes) <= 500
  ),
  constraint opening_balance_entry_unique_line unique (import_id, line_no),
  constraint opening_balance_entry_shape check (
    (
      entry_type = 'FARMER_DEBT'
      and customer_id is not null
      and crop_type_id is null
      and product_id is null
      and location_id is null
      and quantity is null
      and weight_centi_pyitha is null
      and principal_kyat > 0
      and monthly_interest_rate between 0 and 100
      and opening_date is not null
    )
    or
    (
      entry_type = 'PRODUCT_STOCK'
      and customer_id is null
      and crop_type_id is null
      and product_id is not null
      and location_id is not null
      and quantity > 0
      and weight_centi_pyitha is null
      and principal_kyat is null
      and monthly_interest_rate is null
      and opening_date is null
    )
    or
    (
      entry_type = 'CROP_STOCK'
      and customer_id is null
      and crop_type_id is not null
      and product_id is null
      and location_id is not null
      and quantity is null
      and weight_centi_pyitha > 0
      and principal_kyat is null
      and monthly_interest_rate is null
      and opening_date is null
    )
  )
);

create index if not exists opening_balance_entries_import_idx
  on public.opening_balance_entries (import_id, line_no);
create index if not exists opening_balance_entries_farmer_idx
  on public.opening_balance_entries (customer_id, opening_date, id)
  where entry_type = 'FARMER_DEBT';
create index if not exists opening_balance_entries_product_idx
  on public.opening_balance_entries (product_id, location_id, id)
  where entry_type = 'PRODUCT_STOCK';
create index if not exists opening_balance_entries_crop_idx
  on public.opening_balance_entries (crop_type_id, location_id, id)
  where entry_type = 'CROP_STOCK';
create unique index if not exists opening_balance_entries_import_product_unique_idx
  on public.opening_balance_entries (import_id, product_id, location_id)
  where entry_type = 'PRODUCT_STOCK';
create unique index if not exists opening_balance_entries_import_crop_unique_idx
  on public.opening_balance_entries (import_id, crop_type_id, location_id)
  where entry_type = 'CROP_STOCK';

create or replace function public.prevent_opening_balance_mutation()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if current_setting('app.opening_balance_commit', true) = 'on' then
    if tg_op = 'DELETE' then
      return old;
    elsif tg_op = 'TRUNCATE' then
      return null;
    end if;
    return new;
  end if;
  raise exception 'Opening-balance imports are immutable; post a correction in a later operational module'
    using errcode = '55000';
end;
$$;

drop trigger if exists opening_balance_imports_prevent_update_delete
  on public.opening_balance_imports;
create trigger opening_balance_imports_prevent_update_delete
before update or delete on public.opening_balance_imports
for each row execute function public.prevent_opening_balance_mutation();

drop trigger if exists opening_balance_entries_prevent_update_delete
  on public.opening_balance_entries;
create trigger opening_balance_entries_prevent_update_delete
before update or delete on public.opening_balance_entries
for each row execute function public.prevent_opening_balance_mutation();

drop trigger if exists opening_balance_imports_prevent_truncate
  on public.opening_balance_imports;
create trigger opening_balance_imports_prevent_truncate
before truncate on public.opening_balance_imports
for each statement execute function public.prevent_opening_balance_mutation();

drop trigger if exists opening_balance_entries_prevent_truncate
  on public.opening_balance_entries;
create trigger opening_balance_entries_prevent_truncate
before truncate on public.opening_balance_entries
for each statement execute function public.prevent_opening_balance_mutation();

alter table public.opening_balance_imports enable row level security;
alter table public.opening_balance_imports force row level security;
alter table public.opening_balance_entries enable row level security;
alter table public.opening_balance_entries force row level security;

revoke all on table public.opening_balance_imports from anon, authenticated;
revoke all on table public.opening_balance_entries from anon, authenticated;
revoke all on sequence public.opening_balance_ref_seq from anon, authenticated;
revoke all on sequence public.opening_balance_entries_id_seq from anon, authenticated;

grant select on table public.opening_balance_imports to authenticated;
grant select on table public.opening_balance_entries to authenticated;
grant all on table public.opening_balance_imports to service_role;
grant all on table public.opening_balance_entries to service_role;
grant all on sequence public.opening_balance_ref_seq to service_role;
grant all on sequence public.opening_balance_entries_id_seq to service_role;

drop policy if exists "Active staff can read opening balance imports"
  on public.opening_balance_imports;
create policy "Active staff can read opening balance imports"
on public.opening_balance_imports
for select to authenticated
using (public.current_staff_is_active());

drop policy if exists "Active staff can read opening balance entries"
  on public.opening_balance_entries;
create policy "Active staff can read opening balance entries"
on public.opening_balance_entries
for select to authenticated
using (public.current_staff_is_active());

create or replace function public.commit_opening_balance_import(
  p_request_id uuid,
  p_import_type text,
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
  v_type text := upper(trim(coalesce(p_import_type, '')));
  v_source text := trim(coalesce(p_source_name, ''));
  v_row jsonb;
  v_line bigint;
  v_entity text;
  v_location text;
  v_notes text;
  v_quantity numeric(20, 3);
  v_weight_centi bigint;
  v_principal bigint;
  v_rate numeric(7, 4);
  v_opening_date date;
  v_whole_units boolean;
  v_count integer := 0;
  v_total_quantity numeric(20, 3) := 0;
  v_total_weight bigint := 0;
  v_total_principal bigint := 0;
begin
  perform public.require_staff_roles(array['owner', 'admin', 'accountant']);
  perform set_config('app.opening_balance_commit', 'on', true);

  if p_request_id is null then
    raise exception 'Opening-balance request ID is required' using errcode = '22023';
  end if;

  select imports.* into v_existing
  from public.opening_balance_imports as imports
  where imports.request_id = p_request_id;

  if found then
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

  if v_type not in ('FARMER_DEBT', 'PRODUCT_STOCK', 'CROP_STOCK') then
    raise exception 'Unsupported opening-balance import type: %', p_import_type
      using errcode = '22023';
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
    raise exception 'Opening-balance import requires 1 to 1000 rows'
      using errcode = '22023';
  end if;

  insert into public.opening_balance_imports (
    import_ref,
    request_id,
    business_date,
    import_type,
    source_name,
    notes,
    created_by
  )
  values (
    'OB-' || to_char(public.get_business_date(), 'YYYYMMDD') || '-'
      || lpad(nextval('public.opening_balance_ref_seq')::text, 6, '0'),
    p_request_id,
    public.get_business_date(),
    v_type,
    v_source,
    nullif(trim(coalesce(p_notes, '')), ''),
    auth.uid()
  )
  returning * into v_import;

  for v_row, v_line in
    select item.value, item.ordinality
    from jsonb_array_elements(p_rows) with ordinality as item(value, ordinality)
  loop
    if jsonb_typeof(v_row) <> 'object' then
      raise exception 'Line % must be an object', v_line using errcode = '22023';
    end if;

    v_entity := trim(coalesce(
      v_row ->> 'customer_id',
      v_row ->> 'product_id',
      v_row ->> 'crop_type_id',
      ''
    ));
    v_location := nullif(trim(coalesce(v_row ->> 'location_id', '')), '');
    v_notes := nullif(trim(coalesce(v_row ->> 'notes', '')), '');

    if v_notes is not null and length(v_notes) > 500 then
      raise exception 'Line % notes cannot exceed 500 characters', v_line
        using errcode = '22023';
    end if;

    if v_type = 'FARMER_DEBT' then
      if not exists (
        select 1 from public.farmers as farmers
        where farmers.customer_id = v_entity
      ) then
        raise exception 'Line % farmer not found: %', v_line, v_entity
          using errcode = '23503';
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
      if coalesce(v_row ->> 'monthly_rate', '') !~ '^[0-9]+([.][0-9]{1,4})?$' then
        raise exception 'Line % monthly_rate must contain up to four decimals', v_line
          using errcode = '22023';
      end if;
      v_rate := (v_row ->> 'monthly_rate')::numeric(7, 4);
      if v_rate < 0 or v_rate > 100 then
        raise exception 'Line % monthly_rate must be from 0 to 100', v_line
          using errcode = '22023';
      end if;
      if coalesce(v_row ->> 'opening_date', '') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
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

      insert into public.opening_balance_entries (
        import_id, line_no, entry_type, customer_id, principal_kyat,
        monthly_interest_rate, opening_date, notes
      ) values (
        v_import.id, v_line, v_type, v_entity, v_principal,
        v_rate, v_opening_date, v_notes
      );
      v_total_principal := v_total_principal + v_principal;

    elsif v_type = 'PRODUCT_STOCK' then
      select products.whole_units_only into v_whole_units
      from public.products as products
      where products.product_id = v_entity and products.active = true;
      if not found then
        raise exception 'Line % active product not found: %', v_line, v_entity
          using errcode = '23503';
      end if;
      if not exists (
        select 1 from public.stock_locations as locations
        where locations.location_id = v_location and locations.active = true
      ) then
        raise exception 'Line % active stock location not found: %', v_line, v_location
          using errcode = '23503';
      end if;
      if coalesce(v_row ->> 'quantity', '') !~ '^[0-9]+([.][0-9]{1,3})?$' then
        raise exception 'Line % quantity must contain up to three decimals', v_line
          using errcode = '22023';
      end if;
      v_quantity := (v_row ->> 'quantity')::numeric(20, 3);
      if v_quantity <= 0 then
        raise exception 'Line % quantity must be greater than zero', v_line
          using errcode = '22023';
      end if;
      if v_whole_units and v_quantity <> trunc(v_quantity) then
        raise exception 'Line % product requires a whole-unit quantity', v_line
          using errcode = '22023';
      end if;

      insert into public.opening_balance_entries (
        import_id, line_no, entry_type, product_id, location_id, quantity, notes
      ) values (
        v_import.id, v_line, v_type, v_entity, v_location, v_quantity, v_notes
      );
      v_total_quantity := v_total_quantity + v_quantity;

    else
      if not exists (
        select 1 from public.crop_types as crops
        where crops.crop_type_id = v_entity and crops.active = true
      ) then
        raise exception 'Line % active crop not found: %', v_line, v_entity
          using errcode = '23503';
      end if;
      if not exists (
        select 1 from public.stock_locations as locations
        where locations.location_id = v_location and locations.active = true
      ) then
        raise exception 'Line % active stock location not found: %', v_line, v_location
          using errcode = '23503';
      end if;
      if coalesce(v_row ->> 'weight_pyitha', '') !~ '^[0-9]+([.][0-9]{1,2})?$' then
        raise exception 'Line % weight_pyitha must contain up to two decimals', v_line
          using errcode = '22023';
      end if;
      v_weight_centi := round((v_row ->> 'weight_pyitha')::numeric * 100)::bigint;
      if v_weight_centi <= 0 then
        raise exception 'Line % weight_pyitha must be greater than zero', v_line
          using errcode = '22023';
      end if;

      insert into public.opening_balance_entries (
        import_id, line_no, entry_type, crop_type_id, location_id,
        weight_centi_pyitha, notes
      ) values (
        v_import.id, v_line, v_type, v_entity, v_location,
        v_weight_centi, v_notes
      );
      v_total_weight := v_total_weight + v_weight_centi;
    end if;

    v_count := v_count + 1;
  end loop;

  update public.opening_balance_imports as imports set
    row_count = v_count,
    total_quantity = v_total_quantity,
    total_weight_centi_pyitha = v_total_weight,
    total_principal_kyat = v_total_principal
  where imports.id = v_import.id;

  if v_type = 'FARMER_DEBT' then
    update public.farmers as farmers set
      opening_debt_kyat = coalesce((
        select sum(entries.principal_kyat)::bigint
        from public.opening_balance_entries as entries
        where entries.entry_type = 'FARMER_DEBT'
          and entries.customer_id = farmers.customer_id
      ), 0)
    where farmers.customer_id in (
      select distinct entries.customer_id
      from public.opening_balance_entries as entries
      where entries.import_id = v_import.id
    );
  end if;

  return query select
    v_import.id,
    v_import.import_ref,
    v_import.business_date,
    v_type,
    v_count,
    v_total_quantity,
    v_total_weight,
    v_total_principal,
    false;
end;
$$;

revoke all on function public.commit_opening_balance_import(
  uuid, text, text, jsonb, text
) from public;
grant execute on function public.commit_opening_balance_import(
  uuid, text, text, jsonb, text
) to authenticated;
grant execute on function public.commit_opening_balance_import(
  uuid, text, text, jsonb, text
) to service_role;

alter table public.crop_types replica identity full;
alter table public.farmers replica identity full;
alter table public.products replica identity full;
alter table public.stock_locations replica identity full;
alter table public.staff_members replica identity full;
alter table public.opening_balance_imports replica identity full;

do $$
declare
  v_table text;
begin
  foreach v_table in array array[
    'crop_types',
    'farmers',
    'products',
    'stock_locations',
    'staff_members',
    'opening_balance_imports'
  ]
  loop
    if not exists (
      select 1
      from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = v_table
    ) then
      execute format('alter publication supabase_realtime add table public.%I', v_table);
    end if;
  end loop;
end
$$;
