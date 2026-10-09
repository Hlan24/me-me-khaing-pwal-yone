-- Read-only production verification for
-- 202609150001_crop_sales_day_close.sql.
--
-- Run the whole query in Supabase SQL Editor after the migration. Every
-- numbered row and the final OVERALL row must say PASS. This query never
-- inserts, updates, deletes, truncates, or changes schema objects.

with checks as (
  select
    '01 crop-operation tables exist with forced RLS'::text as check_name,
    count(*)::bigint as violations,
    'all six ledgers exist with RLS and FORCE RLS'::text as expectation
  from (
    values
      ('crop_settlements'),
      ('crop_settlement_bag_prices'),
      ('crop_stock_movements'),
      ('wholesale_crop_sales'),
      ('buyer_receivable_lots'),
      ('business_day_closes')
  ) as expected(table_name)
  left join pg_class as relation
    on relation.oid = to_regclass('public.' || expected.table_name)
  where relation.oid is null
     or not relation.relrowsecurity
     or not relation.relforcerowsecurity

  union all
  select
    '02 browser roles have no direct ledger writes',
    count(*)::bigint,
    'anon and authenticated cannot INSERT, UPDATE, DELETE, or TRUNCATE the six ledgers'
  from (
    values
      ('crop_settlements'),
      ('crop_settlement_bag_prices'),
      ('crop_stock_movements'),
      ('wholesale_crop_sales'),
      ('buyer_receivable_lots'),
      ('business_day_closes')
  ) as expected(table_name)
  cross join (values ('anon'), ('authenticated')) as browser(role_name)
  where has_table_privilege(browser.role_name,
          'public.' || expected.table_name, 'INSERT')
     or has_table_privilege(browser.role_name,
          'public.' || expected.table_name, 'UPDATE')
     or has_table_privilege(browser.role_name,
          'public.' || expected.table_name, 'DELETE')
     or has_table_privilege(browser.role_name,
          'public.' || expected.table_name, 'TRUNCATE')

  union all
  select
    '03 exact owner RPC signatures exist',
    count(*)::bigint,
    'all five UI-facing crop-operation functions exist'
  from (
    values
      ('public.get_crop_stock_balances()'),
      ('public.get_day_close_preview()'),
      ('public.settle_crop_intake(uuid,uuid,text,bigint,text,bigint,numeric,bigint,text,text,uuid,bigint,numeric,jsonb,text)'),
      ('public.record_wholesale_crop_sale(uuid,text,text,text,bigint,integer,integer,bigint,bigint,bigint,bigint,text,text,text)'),
      ('public.close_business_day(uuid,bigint,bigint)')
  ) as expected(signature)
  left join pg_proc as proc
    on proc.oid = to_regprocedure(expected.signature)
  where proc.oid is null

  union all
  select
    '04 owner RPC execute grants are closed correctly',
    count(*)::bigint,
    'authenticated can execute the five owner entry points and anon can execute none'
  from (
    values
      ('public.get_crop_stock_balances()'),
      ('public.get_day_close_preview()'),
      ('public.settle_crop_intake(uuid,uuid,text,bigint,text,bigint,numeric,bigint,text,text,uuid,bigint,numeric,jsonb,text)'),
      ('public.record_wholesale_crop_sale(uuid,text,text,text,bigint,integer,integer,bigint,bigint,bigint,bigint,text,text,text)'),
      ('public.close_business_day(uuid,bigint,bigint)')
  ) as expected(signature)
  where not has_function_privilege(
          'authenticated', expected.signature, 'EXECUTE'
        )
     or has_function_privilege('anon', expected.signature, 'EXECUTE')

  union all
  select
    '05 internal helpers cannot be called from browsers',
    count(*)::bigint,
    'stock, date-lock, allocation-guard, and trigger helpers are service-only'
  from (
    values
      ('public.crop_stock_quantity(text,text)'),
      ('public.assert_business_day_open()'),
      ('public.guard_closed_business_day_posting()'),
      ('public.guard_current_business_day_open()'),
      ('public.guard_intake_allocation_mutation()')
  ) as expected(signature)
  where has_function_privilege(
          'authenticated', expected.signature, 'EXECUTE'
        )
     or has_function_privilege('anon', expected.signature, 'EXECUTE')

  union all
  select
    '06 realtime publication contains every new ledger',
    count(*)::bigint,
    'all six crop-operation tables are in supabase_realtime'
  from (
    values
      ('crop_settlements'),
      ('crop_settlement_bag_prices'),
      ('crop_stock_movements'),
      ('wholesale_crop_sales'),
      ('buyer_receivable_lots'),
      ('business_day_closes')
  ) as expected(table_name)
  where not exists (
    select 1
    from pg_publication_tables as published
    where published.pubname = 'supabase_realtime'
      and published.schemaname = 'public'
      and published.tablename = expected.table_name
  )

  union all
  select
    '07 immutable-ledger triggers are enabled',
    count(*)::bigint,
    'every new ledger rejects update, delete, and truncate'
  from (
    values
      ('crop_settlements'),
      ('crop_settlement_bag_prices'),
      ('crop_stock_movements'),
      ('wholesale_crop_sales'),
      ('buyer_receivable_lots'),
      ('business_day_closes')
  ) as expected(table_name)
  cross join (values ('_prevent_update_delete'), ('_prevent_truncate'))
    as suffix(value)
  left join pg_trigger as trig
    on trig.tgrelid = to_regclass('public.' || expected.table_name)
   and trig.tgname = expected.table_name || suffix.value
   and trig.tgenabled <> 'D'
  where trig.oid is null

  union all
  select
    '08 bean settlements buy only sale-reserved stock',
    count(*)::bigint,
    'bean purchase weight equals its allocation sale portion; farmer consignment remains separate'
  from public.crop_settlements as settlement
  left join public.intake_allocations as allocation
    on allocation.id = settlement.allocation_id
  where settlement.crop_category = 'BEAN'
    and (
      allocation.id is null
      or settlement.purchased_centi_pyitha
           <> allocation.sale_reserved_centi_pyitha
      or allocation.sale_state <> 'SETTLED'
      or (
        allocation.consigned_centi_pyitha > 0
        and not exists (
          select 1
          from public.consignment_lots as lot
          where lot.id = allocation.consignment_lot_id
            and lot.original_net_weight_centi_pyitha
                = allocation.consigned_centi_pyitha
        )
      )
    )

  union all
  select
    '09 settlement transaction, stock, payout, and debt reconcile',
    count(*)::bigint,
    'each settlement has one matching transaction, stock-in, optional offset, and physical payout'
  from public.crop_settlements as settlement
  join public.finance_transactions as tx
    on tx.id = settlement.transaction_id
  left join lateral (
    select count(*)::integer as movement_count
    from public.crop_stock_movements as movement
    where movement.transaction_id = settlement.transaction_id
      and movement.movement_type = 'PURCHASE_IN'
      and movement.movement_ref = settlement.settlement_ref
      and movement.business_date = settlement.business_date
      and movement.quantity_delta_centi_pyitha
          = settlement.purchased_centi_pyitha
      and movement.quantity_before_centi_pyitha
          = settlement.stock_before_centi_pyitha
      and movement.quantity_after_centi_pyitha
          = settlement.stock_after_centi_pyitha
  ) as stock on true
  left join lateral (
    select count(*)::integer as payout_count
    from public.cash_ledger_entries as cash
    where cash.transaction_id = settlement.transaction_id
      and cash.direction = 'OUT'
      and cash.category = 'FARMER_PAYOUT'
      and cash.document_ref = settlement.settlement_ref
      and cash.business_date = settlement.business_date
      and cash.amount_kyat = settlement.payable_kyat
  ) as payout on true
  left join lateral (
    select count(*)::integer as offset_count
    from public.advance_repayments as repayment
    where repayment.transaction_id = settlement.transaction_id
      and repayment.advance_lot_id = settlement.debt_advance_lot_id
      and repayment.principal_kyat = settlement.debt_principal_kyat
      and repayment.interest_kyat = settlement.debt_interest_kyat
      and repayment.total_received_kyat = settlement.debt_total_kyat
      and repayment.payment_method = 'OFFSET'
  ) as debt on true
  where tx.document_type <> 'CROP_SETTLEMENT'
     or tx.document_ref <> settlement.settlement_ref
     or tx.business_date <> settlement.business_date
     or stock.movement_count <> 1
     or (settlement.payable_kyat = 0 and payout.payout_count <> 0)
     or (settlement.payable_kyat > 0 and payout.payout_count <> 1)
     or (settlement.debt_advance_lot_id is null and debt.offset_count <> 0)
     or (settlement.debt_advance_lot_id is not null and debt.offset_count <> 1)

  union all
  select
    '10 chili per-bag prices reconcile exactly',
    count(*)::bigint,
    'each chili settlement bag count, net weight, and value equal immutable detail rows'
  from public.crop_settlements as settlement
  left join lateral (
    select count(*)::integer as bag_count,
      coalesce(sum(bag.net_centi_pyitha), 0)::bigint as net_weight,
      coalesce(sum(bag.bag_value_kyat), 0)::bigint as bag_value
    from public.crop_settlement_bag_prices as bag
    where bag.settlement_id = settlement.id
  ) as detail on true
  where settlement.crop_category = 'CHILI'
    and (
      detail.bag_count <> settlement.actual_bags
      or detail.net_weight <> settlement.purchased_centi_pyitha
      or detail.bag_value <> settlement.gross_value_kyat
    )

  union all
  select
    '11 wholesale sale stock, cash, and receivable reconcile',
    count(*)::bigint,
    'each sale has one stock-out plus either one full receipt or one full receivable'
  from public.wholesale_crop_sales as sale
  join public.finance_transactions as tx on tx.id = sale.transaction_id
  left join lateral (
    select count(*)::integer as movement_count
    from public.crop_stock_movements as movement
    where movement.transaction_id = sale.transaction_id
      and movement.movement_type = 'WHOLESALE_OUT'
      and movement.movement_ref = sale.sale_ref
      and movement.business_date = sale.business_date
      and movement.quantity_delta_centi_pyitha = -sale.weight_centi_pyitha
      and movement.quantity_before_centi_pyitha
          = sale.stock_before_centi_pyitha
      and movement.quantity_after_centi_pyitha
          = sale.stock_after_centi_pyitha
  ) as stock on true
  left join lateral (
    select count(*)::integer as receipt_count
    from public.cash_ledger_entries as cash
    where cash.transaction_id = sale.transaction_id
      and cash.direction = 'IN'
      and cash.category = 'CROP_SALE'
      and cash.amount_kyat = sale.received_kyat
  ) as receipt on true
  left join lateral (
    select count(*)::integer as receivable_count
    from public.buyer_receivable_lots as lot
    where lot.sale_id = sale.id
      and lot.sale_ref = sale.sale_ref
      and lot.opening_kyat = sale.receivable_kyat
      and lot.remaining_kyat = sale.receivable_kyat
  ) as receivable on true
  where tx.document_type <> 'CROP_SALE'
     or tx.document_ref <> sale.sale_ref
     or tx.business_date <> sale.business_date
     or stock.movement_count <> 1
     or (sale.payment_method = 'CREDIT'
         and (receipt.receipt_count <> 0 or receivable.receivable_count <> 1))
     or (sale.payment_method <> 'CREDIT'
         and (receipt.receipt_count <> 1 or receivable.receivable_count <> 0))

  union all
  select
    '12 crop stock never becomes negative',
    count(*)::bigint,
    'opening crop stock plus immutable movements stays nonnegative at every saved snapshot'
  from public.crop_stock_movements as movement
  where movement.quantity_before_centi_pyitha < 0
     or movement.quantity_after_centi_pyitha < 0
     or public.crop_stock_quantity(
          movement.crop_type_id, movement.location_id
        ) < 0

  union all
  select
    '13 closed days are exact and have no later postings',
    count(*)::bigint,
    'each close has zero variance/pending work and no later operational rows on that business date'
  from public.business_day_closes as close_row
  join public.finance_transactions as tx
    on tx.id = close_row.transaction_id
  where tx.document_type <> 'DAY_CLOSE'
     or tx.document_ref <> close_row.day_close_ref
     or tx.business_date <> close_row.business_date
     or close_row.expected_cash_kyat <> close_row.counted_cash_kyat
     or close_row.variance_kyat <> 0
     or close_row.pending_draft_batches <> 0
     or close_row.pending_unallocated_batches <> 0
     or close_row.pending_settlements <> 0
     or exists (
       select 1
       from public.finance_transactions as later
       where later.business_date = close_row.business_date
         and later.created_at > close_row.created_at
     )
     or exists (
       select 1
       from public.weighing_batches as later
       where later.business_date = close_row.business_date
         and later.created_at > close_row.created_at
     )

  union all
  select
    '14 closed-day posting guards are enabled',
    count(*)::bigint,
    'finance, weighing, bag, and allocation guards reject closed-day postings'
  from (
    values
      ('finance_transactions', 'finance_transactions_closed_day_guard'),
      ('weighing_batches', 'weighing_batches_closed_day_guard'),
      ('bag_weights', 'zz_bag_weights_closed_day_guard'),
      ('intake_allocations', 'intake_allocations_closed_day_guard')
  ) as expected(table_name, trigger_name)
  left join pg_trigger as trig
    on trig.tgrelid = to_regclass('public.' || expected.table_name)
   and trig.tgname = expected.trigger_name
   and trig.tgenabled <> 'D'
  where trig.oid is null

  union all
  select
    '15 day-close concurrency barrier is installed',
    case when
      position('for share' in lower(pg_get_functiondef(
        to_regprocedure('public.assert_business_day_open()')
      ))) > 0
      and position('for share' in lower(pg_get_functiondef(
        to_regprocedure('public.guard_closed_business_day_posting()')
      ))) > 0
      and position('for update' in lower(pg_get_functiondef(
        to_regprocedure('public.close_business_day(uuid,bigint,bigint)')
      ))) > 0
    then 0 else 1 end::bigint,
    'posting paths share-lock business settings and Day Close exclusively locks it'

  union all
  select
    '16 new finance documents have immutable audit events',
    count(*)::bigint,
    'every settlement, wholesale sale, and day close transaction has an audit row'
  from public.finance_transactions as tx
  where tx.document_type in ('CROP_SETTLEMENT', 'CROP_SALE', 'DAY_CLOSE')
    and not exists (
      select 1
      from public.finance_audit_events as audit
      where audit.transaction_id = tx.id
        and audit.document_ref = tx.document_ref
    )

  union all
  select
    '17 active owner remains',
    case when exists (
      select 1 from public.staff_members
      where role = 'owner' and active = true
    ) then 0 else 1 end::bigint,
    'at least one active owner can operate the production ledgers'

  union all
  select
    '18 wholesale buyer-paid labour reconciles',
    count(*)::bigint,
    'actual bags times labour rate is added to crop value before freight and buyer payment'
  from public.wholesale_crop_sales as sale
  where sale.labour_rate_kyat < 0
     or sale.labour_total_kyat
          <> sale.actual_bags::bigint * sale.labour_rate_kyat
     or sale.net_value_kyat
          <> sale.gross_value_kyat + sale.labour_total_kyat
             - sale.freight_kyat
), results as (
  select check_name,
    case when violations = 0 then 'PASS' else 'FAIL' end as status,
    violations, expectation
  from checks
)
select check_name, status, violations, expectation
from results
union all
select 'OVERALL',
  case when sum(violations) = 0 then 'PASS' else 'FAIL' end,
  sum(violations)::bigint,
  'all crop sales and day-close production checks must pass'
from results
order by check_name;
