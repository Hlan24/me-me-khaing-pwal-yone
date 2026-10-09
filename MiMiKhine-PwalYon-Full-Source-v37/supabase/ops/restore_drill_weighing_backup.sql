-- Non-destructive logical-backup restore drill.
--
-- Purpose
--   Parse the exported JSON into typed TEMP tables, assert the exact expected
--   staff/bag counts, and check basic identity/referential invariants.  It never
--   writes to public/auth tables.  TEMP data disappears at transaction/session
--   end, so the backup itself stays outside this repository.
--
-- Required JSON envelope (values omitted intentionally; do not commit PII):
--   {
--     "staff_members": [ ... rows exported from public.staff_members ... ],
--     "bag_weights":   [ ... rows exported from public.bag_weights ... ]
--   }
--
-- How to run
--   1. Copy this entire file into a private SQL session.
--   2. Replace the commented invocation at the bottom with the backup JSON.
--   3. Set p_expected_staff/p_expected_bags from the export manifest (for the
--      current drill these are expected to be 1 and 10).
--   4. Run definition + invocation together.  Every returned row must PASS.

create temporary table if not exists restore_drill_bootstrap (
  initialized boolean not null default true
) on commit drop;

create or replace function pg_temp.verify_pwal_yon_backup_restore(
  p_backup jsonb,
  p_expected_staff bigint,
  p_expected_bags bigint
)
returns table (
  check_name text,
  expected bigint,
  actual bigint,
  result text
)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_staff_count bigint;
  v_bag_count bigint;
begin
  if jsonb_typeof(p_backup) <> 'object' then
    raise exception 'Backup payload must be one JSON object'
      using errcode = '22023';
  end if;

  if jsonb_typeof(p_backup -> 'staff_members') <> 'array'
    or jsonb_typeof(p_backup -> 'bag_weights') <> 'array' then
    raise exception 'Backup must contain staff_members and bag_weights arrays'
      using errcode = '22023';
  end if;

  if p_expected_staff < 0 or p_expected_bags < 0 then
    raise exception 'Expected counts must be non-negative'
      using errcode = '22023';
  end if;

  drop table if exists pg_temp.restore_drill_staff_members;
  drop table if exists pg_temp.restore_drill_bag_weights;

  create temporary table restore_drill_staff_members (
    user_id uuid,
    email text,
    display_name text,
    role text,
    active boolean,
    activated_at timestamptz,
    activated_by uuid,
    created_at timestamptz,
    updated_at timestamptz
  ) on commit drop;

  create temporary table restore_drill_bag_weights (
    id uuid,
    batch_id uuid,
    batch_ref text,
    business_date date,
    bag_no integer,
    customer_id text,
    customer_name text,
    crop_type_id text,
    crop_name text,
    weight_centi_pyitha integer,
    condition text,
    moisture_pct numeric(5, 2),
    quality_grade text,
    status text,
    device_id text,
    created_by uuid,
    created_at timestamptz,
    updated_at timestamptz
  ) on commit drop;

  insert into pg_temp.restore_drill_staff_members
  select parsed.*
  from jsonb_to_recordset(p_backup -> 'staff_members') as parsed (
    user_id uuid,
    email text,
    display_name text,
    role text,
    active boolean,
    activated_at timestamptz,
    activated_by uuid,
    created_at timestamptz,
    updated_at timestamptz
  );

  insert into pg_temp.restore_drill_bag_weights
  select parsed.*
  from jsonb_to_recordset(p_backup -> 'bag_weights') as parsed (
    id uuid,
    batch_id uuid,
    batch_ref text,
    business_date date,
    bag_no integer,
    customer_id text,
    customer_name text,
    crop_type_id text,
    crop_name text,
    weight_centi_pyitha integer,
    condition text,
    moisture_pct numeric(5, 2),
    quality_grade text,
    status text,
    device_id text,
    created_by uuid,
    created_at timestamptz,
    updated_at timestamptz
  );

  select count(*) into v_staff_count
  from pg_temp.restore_drill_staff_members;
  select count(*) into v_bag_count
  from pg_temp.restore_drill_bag_weights;

  return query
  select
    'staff_members row count'::text,
    p_expected_staff,
    v_staff_count,
    case when v_staff_count = p_expected_staff then 'PASS' else 'FAIL' end;

  return query
  select
    'bag_weights row count'::text,
    p_expected_bags,
    v_bag_count,
    case when v_bag_count = p_expected_bags then 'PASS' else 'FAIL' end;

  return query
  select
    'staff user_id present and unique'::text,
    0::bigint,
    (
      count(*) filter (where staff.user_id is null)
      + count(*) - count(distinct staff.user_id)
    )::bigint,
    case when
      count(*) filter (where staff.user_id is null)
        + count(*) - count(distinct staff.user_id) = 0
      then 'PASS' else 'FAIL' end
  from pg_temp.restore_drill_staff_members as staff;

  return query
  select
    'staff roles valid'::text,
    0::bigint,
    count(*)::bigint,
    case when count(*) = 0 then 'PASS' else 'FAIL' end
  from pg_temp.restore_drill_staff_members as staff
  where staff.role is null
     or staff.role not in ('owner', 'admin', 'weigher', 'accountant', 'viewer')
     or staff.active is null;

  return query
  select
    'bag id present and unique'::text,
    0::bigint,
    (
      count(*) filter (where bags.id is null)
      + count(*) - count(distinct bags.id)
    )::bigint,
    case when
      count(*) filter (where bags.id is null)
        + count(*) - count(distinct bags.id) = 0
      then 'PASS' else 'FAIL' end
  from pg_temp.restore_drill_bag_weights as bags;

  return query
  select
    'batch bag_no unique'::text,
    0::bigint,
    count(*)::bigint,
    case when count(*) = 0 then 'PASS' else 'FAIL' end
  from (
    select bags.batch_id, bags.bag_no
    from pg_temp.restore_drill_bag_weights as bags
    group by bags.batch_id, bags.bag_no
    having bags.batch_id is null
       or bags.bag_no is null
       or count(*) > 1
  ) as invalid;

  return query
  select
    'bag measurements and statuses valid'::text,
    0::bigint,
    count(*)::bigint,
    case when count(*) = 0 then 'PASS' else 'FAIL' end
  from pg_temp.restore_drill_bag_weights as bags
  where bags.weight_centi_pyitha is null
     or bags.weight_centi_pyitha not between 1 and 20000
     or bags.status is null
     or bags.status not in ('DRAFT', 'SUBMITTED', 'VOID')
     or (bags.condition is not null and bags.condition not in ('WET', 'DRY'))
     or (bags.moisture_pct is not null
         and bags.moisture_pct not between 0 and 100)
     or (bags.quality_grade is not null
         and bags.quality_grade not in ('A', 'B', 'C'));

  return query
  select
    'bag creator included in staff backup'::text,
    0::bigint,
    count(*)::bigint,
    case when count(*) = 0 then 'PASS' else 'FAIL' end
  from pg_temp.restore_drill_bag_weights as bags
  left join pg_temp.restore_drill_staff_members as staff
    on staff.user_id = bags.created_by
  where bags.created_by is null or staff.user_id is null;
end;
$$;

-- Private invocation template (keep the real payload outside the repository):
-- select *
-- from pg_temp.verify_pwal_yon_backup_restore(
--   p_backup => '<PASTE PRIVATE BACKUP JSON HERE>'::jsonb,
--   p_expected_staff => 1,
--   p_expected_bags => 10
-- );
