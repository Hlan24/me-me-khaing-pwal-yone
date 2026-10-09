-- Read-only post-migration verification for
-- 202608130001_weighing_batches_master_data.sql and
-- 202608260001_offline_queue_integrity.sql.
--
-- Run the entire query in Supabase SQL Editor after applying the migration.
-- PASS on every row is required.  It does not insert, update, or delete data.

with checks as (
  select
    '01 business settings singleton'::text as check_name,
    abs(1 - count(*))::bigint as violations,
    'exactly one business_settings row'::text as expectation
  from public.business_settings

  union all
  select
    '02 bag parent exists',
    count(*)::bigint,
    'every bag_weights.batch_id references weighing_batches.id'
  from public.bag_weights as bags
  left join public.weighing_batches as batch on batch.id = bags.batch_id
  where batch.id is null

  union all
  select
    '03 batch master rows exist',
    count(*)::bigint,
    'every batch references a farmer and crop master row'
  from public.weighing_batches as batch
  left join public.farmers as farmer on farmer.customer_id = batch.customer_id
  left join public.crop_types as crop
    on crop.crop_type_id = batch.crop_type_id
  where farmer.customer_id is null or crop.crop_type_id is null

  union all
  select
    '04 bag/header identity agrees',
    count(*)::bigint,
    'bag detail uses header date, farmer, crop, snapshots, and WB batch_ref'
  from public.bag_weights as bags
  join public.weighing_batches as batch on batch.id = bags.batch_id
  where bags.business_date is distinct from batch.business_date
     or bags.customer_id is distinct from batch.customer_id
     or bags.customer_name is distinct from batch.customer_name
     or bags.crop_type_id is distinct from batch.crop_type_id
     or bags.crop_name is distinct from batch.crop_name
     or bags.batch_ref is distinct from batch.batch_ref

  union all
  select
    '05 detail lifecycle agrees',
    count(*)::bigint,
    'DRAFT/SUBMITTED/SETTLED/VOID headers have coherent detail statuses'
  from public.bag_weights as bags
  join public.weighing_batches as batch on batch.id = bags.batch_id
  where (batch.status = 'DRAFT' and bags.status <> 'VOID'
         and bags.status <> 'DRAFT')
     or (batch.status in ('SUBMITTED', 'SETTLED') and bags.status <> 'VOID'
         and bags.status <> 'SUBMITTED')
     or (batch.status = 'VOID' and bags.status <> 'VOID')

  union all
  select
    '06 stored batch totals agree',
    count(*)::bigint,
    'header totals equal all non-VOID bag details'
  from public.weighing_batches as batch
  cross join lateral (
    select
      count(*) filter (where bags.status <> 'VOID')::integer as bag_count,
      coalesce(sum(bags.weight_centi_pyitha)
        filter (where bags.status <> 'VOID'), 0)::bigint as gross_weight
    from public.bag_weights as bags
    where bags.batch_id = batch.id
  ) as calculated
  where batch.total_bags is distinct from calculated.bag_count
     or batch.total_gross_weight_centi_pyitha
       is distinct from calculated.gross_weight

  union all
  select
    '07 submitted metadata complete',
    count(*)::bigint,
    'SUBMITTED/SETTLED batches have server voucher, actor, and timestamp'
  from public.weighing_batches
  where status in ('SUBMITTED', 'SETTLED')
    and (voucher_ref is null or submitted_by is null or submitted_at is null)

  union all
  select
    '08 void metadata complete',
    count(*)::bigint,
    'VOID batches have actor, timestamp, and reason'
  from public.weighing_batches
  where status = 'VOID'
    and (
      voided_by is null
      or voided_at is null
      or length(trim(coalesce(void_reason, ''))) < 3
    )

  union all
  select
    '09 document references unique',
    (
      (select count(*) - count(distinct batch_ref)
       from public.weighing_batches)
      +
      (select count(voucher_ref) - count(distinct voucher_ref)
       from public.weighing_batches)
    )::bigint,
    'WB batch_ref and non-null WR voucher_ref values are unique'

  union all
  select
    '10 batch creation audit exists',
    count(*)::bigint,
    'every batch has BATCH_CREATED or BATCH_BACKFILLED'
  from public.weighing_batches as batch
  where not exists (
    select 1
    from public.weighing_audit_events as audit
    where audit.batch_id = batch.id
      and audit.action in ('BATCH_CREATED', 'BATCH_BACKFILLED')
  )

  union all
  select
    '11 duplicate batch bag numbers absent',
    count(*)::bigint,
    'one bag_no per batch_id'
  from (
    select batch_id, bag_no
    from public.bag_weights
    group by batch_id, bag_no
    having count(*) > 1
  ) as duplicates

  union all
  select
    '12 expected RPC signatures',
    count(*)::bigint,
    'all UI-facing RPC signatures and exact argument names exist'
  from (
    values
      (
        'public.create_weighing_batch(text,text,text,uuid)',
        array['p_customer_id','p_crop_type_id','p_device_id','p_batch_id']::text[],
        2
      ),
      (
        'public.create_weighing_batch(text,text,text,uuid,date)',
        array['p_customer_id','p_crop_type_id','p_device_id','p_batch_id',
              'p_business_date']::text[],
        0
      ),
      (
        'public.register_weighing_business_date(text)',
        array['p_device_id']::text[],
        0
      ),
      (
        'public.add_bag_weight(uuid,uuid,integer,integer,text,numeric,text,text)',
        array['p_batch_id','p_bag_id','p_bag_no','p_weight_centi_pyitha',
              'p_condition','p_moisture_pct','p_quality_grade','p_device_id']::text[],
        4
      ),
      (
        'public.submit_weighing_batch(uuid)',
        array['p_batch_id']::text[],
        0
      ),
      (
        'public.void_bag_weight(uuid,text)',
        array['p_bag_id','p_reason']::text[],
        1
      ),
      (
        'public.void_weighing_batch(uuid,text)',
        array['p_batch_id','p_reason']::text[],
        1
      )
  ) as expected(signature, argument_names, default_count)
  left join pg_proc as proc
    on proc.oid = to_regprocedure(expected.signature)
   and proc.proargnames[1:proc.pronargs] = expected.argument_names
   and proc.pronargdefaults = expected.default_count
  where proc.oid is null

  union all
  select
    '13 RLS and FORCE RLS enabled',
    count(*)::bigint,
    'all business tables are protected by forced RLS'
  from (
    values
      ('staff_members'),
      ('staff_access_audit_events'),
      ('business_settings'),
      ('document_counters'),
      ('crop_types'),
      ('farmers'),
      ('products'),
      ('stock_locations'),
      ('bag_weights'),
      ('weighing_batches'),
      ('weighing_audit_events'),
      ('weighing_device_business_contexts')
  ) as expected(table_name)
  left join pg_class as relation
    on relation.oid = to_regclass('public.' || expected.table_name)
  where relation.oid is null
     or not relation.relrowsecurity
     or not relation.relforcerowsecurity

  union all
  select
    '14 audit immutability triggers enabled',
    count(*)::bigint,
    'weighing and staff audit UPDATE/DELETE/TRUNCATE guards are enabled'
  from (
    values
      ('weighing_audit_events', 'weighing_audit_prevent_update_delete'),
      ('weighing_audit_events', 'weighing_audit_prevent_truncate'),
      ('staff_access_audit_events', 'staff_access_audit_prevent_update_delete'),
      ('staff_access_audit_events', 'staff_access_audit_prevent_truncate')
  ) as expected(table_name, trigger_name)
  left join pg_trigger as trig
    on trig.tgname = expected.trigger_name
   and trig.tgrelid = to_regclass('public.' || expected.table_name)
   and trig.tgenabled <> 'D'
  where trig.oid is null

  union all
  select
    '15 finance and activation metadata write grants closed',
    (
      case when has_column_privilege(
        'authenticated', 'public.farmers', 'opening_debt_kyat', 'INSERT'
      ) then 1 else 0 end
      + case when has_column_privilege(
        'authenticated', 'public.farmers', 'opening_debt_kyat', 'UPDATE'
      ) then 1 else 0 end
      + case when has_column_privilege(
        'authenticated', 'public.staff_members', 'activated_at', 'UPDATE'
      ) then 1 else 0 end
      + case when has_column_privilege(
        'authenticated', 'public.staff_members', 'activated_by', 'UPDATE'
      ) then 1 else 0 end
    )::bigint,
    'UI cannot write opening debt or trigger-owned activation metadata'

  union all
  select
    '16 active owner remains',
    case when exists (
      select 1
      from public.staff_members
      where role = 'owner' and active = true
    ) then 0 else 1 end::bigint,
    'at least one active owner account exists'

  union all
  select
    '17 offline context direct grants closed',
    (
      case when has_table_privilege(
        'authenticated', 'public.weighing_device_business_contexts', 'SELECT'
      ) then 1 else 0 end
      + case when has_table_privilege(
        'authenticated', 'public.weighing_device_business_contexts', 'INSERT'
      ) then 1 else 0 end
      + case when has_table_privilege(
        'authenticated', 'public.weighing_device_business_contexts', 'UPDATE'
      ) then 1 else 0 end
      + case when has_table_privilege(
        'authenticated', 'public.weighing_device_business_contexts', 'DELETE'
      ) then 1 else 0 end
    )::bigint,
    'offline business-date contexts are writable only through RPCs'

  union all
  select
    '18 offline context RPCs are security definer',
    count(*)::bigint,
    'business-date registration and exact-date batch creation are protected RPCs'
  from (
    values
      ('public.register_weighing_business_date(text)'),
      ('public.create_weighing_batch(text,text,text,uuid,date)')
  ) as expected(signature)
  left join pg_proc as proc
    on proc.oid = to_regprocedure(expected.signature)
   and proc.prosecdef = true
  where proc.oid is null
)
select
  case when violations = 0 then 'PASS' else 'FAIL' end as result,
  check_name,
  violations,
  expectation
from checks
order by check_name;
