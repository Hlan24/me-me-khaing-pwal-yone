-- Mi Mi Khine Pwal Yon:
-- canonical weighing compatibility and RPC-only write hardening.
--
-- Prerequisites:
--   1. 202608120001_bag_weights_realtime.sql
--   2. 202608130001_weighing_batches_master_data.sql
--   3. 202608260001_offline_queue_integrity.sql
--
-- This migration deliberately does not recreate weighing_batches and does not
-- replace any canonical workflow RPC.

begin;

-- Fail clearly and atomically if this is run against a database that has not
-- received the canonical migrations.
do $migration$
declare
  v_missing_columns text;
begin
  if to_regclass('public.weighing_batches') is null then
    raise exception
      'Missing prerequisite table public.weighing_batches; run 202608130001 first'
      using errcode = '42P01';
  end if;

  if to_regclass('public.bag_weights') is null then
    raise exception
      'Missing prerequisite table public.bag_weights; run 202608120001 first'
      using errcode = '42P01';
  end if;

  select string_agg(
    required.table_name || '.' || required.column_name,
    ', '
    order by required.table_name, required.column_name
  )
  into v_missing_columns
  from (
    values
      ('weighing_batches', 'id'),
      ('weighing_batches', 'batch_ref'),
      ('weighing_batches', 'voucher_ref'),
      ('weighing_batches', 'business_date'),
      ('weighing_batches', 'customer_id'),
      ('weighing_batches', 'customer_name'),
      ('weighing_batches', 'crop_type_id'),
      ('weighing_batches', 'crop_name'),
      ('weighing_batches', 'status'),
      ('weighing_batches', 'total_bags'),
      ('weighing_batches', 'total_gross_weight_centi_pyitha'),
      ('weighing_batches', 'device_id'),
      ('weighing_batches', 'created_by'),
      ('weighing_batches', 'created_at'),
      ('weighing_batches', 'submitted_by'),
      ('weighing_batches', 'submitted_at'),
      ('weighing_batches', 'voided_by'),
      ('weighing_batches', 'voided_at'),
      ('weighing_batches', 'void_reason'),
      ('weighing_batches', 'updated_at'),
      ('bag_weights', 'id'),
      ('bag_weights', 'batch_id'),
      ('bag_weights', 'batch_ref'),
      ('bag_weights', 'business_date'),
      ('bag_weights', 'bag_no'),
      ('bag_weights', 'weight_centi_pyitha'),
      ('bag_weights', 'status'),
      ('bag_weights', 'device_id'),
      ('bag_weights', 'created_by'),
      ('bag_weights', 'created_at'),
      ('bag_weights', 'updated_at')
  ) as required(table_name, column_name)
  where not exists (
    select 1
    from information_schema.columns as actual
    where actual.table_schema = 'public'
      and actual.table_name = required.table_name
      and actual.column_name = required.column_name
  );

  if v_missing_columns is not null then
    raise exception
      'Canonical weighing schema is incomplete. Missing: %',
      v_missing_columns
      using errcode = '42703';
  end if;

  if to_regprocedure(
    'public.register_weighing_business_date(text)'
  ) is null then
    raise exception
      'Missing register_weighing_business_date(text); run 202608260001 first'
      using errcode = '42883';
  end if;

  if to_regprocedure(
    'public.create_weighing_batch(text,text,text,uuid)'
  ) is null then
    raise exception
      'Missing online create_weighing_batch RPC; run canonical migrations first'
      using errcode = '42883';
  end if;

  if to_regprocedure(
    'public.create_weighing_batch(text,text,text,uuid,date)'
  ) is null then
    raise exception
      'Missing offline create_weighing_batch RPC; run 202608260001 first'
      using errcode = '42883';
  end if;

  if to_regprocedure(
    'public.add_bag_weight(uuid,uuid,integer,integer,text,numeric,text,text)'
  ) is null then
    raise exception
      'Missing canonical add_bag_weight RPC'
      using errcode = '42883';
  end if;

  if to_regprocedure(
    'public.submit_weighing_batch(uuid)'
  ) is null then
    raise exception
      'Missing canonical submit_weighing_batch RPC'
      using errcode = '42883';
  end if;

  if to_regprocedure(
    'public.void_bag_weight(uuid,text)'
  ) is null then
    raise exception
      'Missing canonical void_bag_weight RPC'
      using errcode = '42883';
  end if;

  if to_regprocedure(
    'public.void_weighing_batch(uuid,text)'
  ) is null then
    raise exception
      'Missing canonical void_weighing_batch RPC'
      using errcode = '42883';
  end if;
end
$migration$;

-- Ensure every bag belongs to a canonical header. The production constraint
-- already has this name, so this normally only performs the validation check.
do $migration$
begin
  if not exists (
    select 1
    from pg_constraint as constraint_record
    where constraint_record.conrelid = 'public.bag_weights'::regclass
      and constraint_record.conname = 'bag_weights_batch_fk'
  ) then
    alter table public.bag_weights
      add constraint bag_weights_batch_fk
      foreign key (batch_id)
      references public.weighing_batches (id)
      on update restrict
      on delete restrict
      not valid;
  end if;
end
$migration$;

-- This is harmless if the constraint is already validated. It deliberately
-- fails and rolls the transaction back if orphan details are discovered.
alter table public.bag_weights
  validate constraint bag_weights_batch_fk;

-- Existing unfiltered history index is already deterministic:
-- (business_date desc, created_at desc, id desc).
--
-- The canonical status index lacks id, so use a new name instead of relying on
-- CREATE INDEX IF NOT EXISTS against the older, shorter definition.
create index if not exists weighing_batches_status_history_page_idx
  on public.weighing_batches (
    status,
    business_date desc,
    created_at desc,
    id desc
  );

-- RPC-only browser writes. SELECT remains available to active staff through
-- RLS for initial queries, pagination, and Realtime authorization.
alter table public.weighing_batches enable row level security;
alter table public.weighing_batches force row level security;
alter table public.bag_weights enable row level security;
alter table public.bag_weights force row level security;

revoke all privileges
  on table public.weighing_batches
  from anon, authenticated;
grant select
  on table public.weighing_batches
  to authenticated;
grant all privileges
  on table public.weighing_batches
  to service_role;

revoke all privileges
  on table public.bag_weights
  from anon, authenticated;

-- The pilot migration granted column-level UPDATE privileges. Table-level
-- REVOKE does not reliably communicate the intent for those individual grants,
-- so revoke the known legacy column grant explicitly as well.
revoke update (status, batch_ref)
  on table public.bag_weights
  from anon, authenticated;

grant select
  on table public.bag_weights
  to authenticated;
grant all privileges
  on table public.bag_weights
  to service_role;

-- The server-date context table is an implementation detail of its SECURITY
-- DEFINER RPC and must not be directly writable from the browser.
alter table public.weighing_device_business_contexts
  enable row level security;
alter table public.weighing_device_business_contexts
  force row level security;

revoke all privileges
  on table public.weighing_device_business_contexts
  from public, anon, authenticated;
grant select, insert, update, delete
  on table public.weighing_device_business_contexts
  to service_role;

-- Remove known direct-write policies left by pilot versions. Direct writes are
-- now exclusively through the canonical SECURITY DEFINER RPCs.
drop policy if exists
  "Authenticated staff can insert own bag weights"
  on public.bag_weights;
drop policy if exists
  "Creators can update their bag weights"
  on public.bag_weights;
drop policy if exists
  "Active weighing staff can insert own bag weights"
  on public.bag_weights;
drop policy if exists
  "Active staff can update allowed bag status"
  on public.bag_weights;

-- Recreate the two read policies with their canonical staff gate.
drop policy if exists
  "Active staff can read weighing batches"
  on public.weighing_batches;
create policy "Active staff can read weighing batches"
on public.weighing_batches
for select
to authenticated
using (public.current_staff_is_active());

drop policy if exists
  "Active staff can read bag weights"
  on public.bag_weights;
create policy "Active staff can read bag weights"
on public.bag_weights
for select
to authenticated
using (public.current_staff_is_active());

-- Remove implicit PUBLIC/anon execution and restate the complete intended RPC
-- surface. Exact signatures matter because create_weighing_batch is overloaded.
revoke all
  on function public.register_weighing_business_date(text)
  from public, anon;
revoke all
  on function public.create_weighing_batch(text, text, text, uuid)
  from public, anon;
revoke all
  on function public.create_weighing_batch(text, text, text, uuid, date)
  from public, anon;
revoke all
  on function public.add_bag_weight(
    uuid, uuid, integer, integer, text, numeric, text, text
  )
  from public, anon;
revoke all
  on function public.submit_weighing_batch(uuid)
  from public, anon;
revoke all
  on function public.void_bag_weight(uuid, text)
  from public, anon;
revoke all
  on function public.void_weighing_batch(uuid, text)
  from public, anon;

grant execute
  on function public.register_weighing_business_date(text)
  to authenticated, service_role;
grant execute
  on function public.create_weighing_batch(text, text, text, uuid)
  to authenticated, service_role;
grant execute
  on function public.create_weighing_batch(text, text, text, uuid, date)
  to authenticated, service_role;
grant execute
  on function public.add_bag_weight(
    uuid, uuid, integer, integer, text, numeric, text, text
  )
  to authenticated, service_role;
grant execute
  on function public.submit_weighing_batch(uuid)
  to authenticated, service_role;
grant execute
  on function public.void_bag_weight(uuid, text)
  to authenticated, service_role;
grant execute
  on function public.void_weighing_batch(uuid, text)
  to authenticated, service_role;

-- Full old/new payloads are useful for Realtime reconciliation and local queue
-- acknowledgement after status changes.
alter table public.weighing_batches replica identity full;
alter table public.bag_weights replica identity full;

do $migration$
begin
  if not exists (
    select 1
    from pg_publication
    where pubname = 'supabase_realtime'
  ) then
    raise exception
      'Supabase Realtime publication does not exist'
      using errcode = '55000';
  end if;

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

  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'bag_weights'
  ) then
    alter publication supabase_realtime
      add table public.bag_weights;
  end if;
end
$migration$;

notify pgrst, 'reload schema';

commit;
