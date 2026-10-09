-- Read-only post-migration verification for
-- 202609100001_owner_finance_ledger.sql.
--
-- Run the whole query in Supabase SQL Editor after the migration. Every
-- numbered row and the final OVERALL row must say PASS. This query never
-- inserts, updates, deletes, truncates, or changes schema objects.

with checks as (
  select
    '01 finance tables exist with forced RLS'::text as check_name,
    count(*)::bigint as violations,
    'all ten finance tables exist with RLS and FORCE RLS'::text as expectation
  from (
    values
      ('finance_document_counters'),
      ('finance_transactions'),
      ('advance_lots'),
      ('advance_repayments'),
      ('product_stock_movements'),
      ('finance_product_sales'),
      ('finance_stock_receipts'),
      ('business_expenses'),
      ('cash_ledger_entries'),
      ('finance_audit_events')
  ) as expected(table_name)
  left join pg_class as relation
    on relation.oid = to_regclass('public.' || expected.table_name)
  where relation.oid is null
     or not relation.relrowsecurity
     or not relation.relforcerowsecurity

  union all
  select
    '02 browser roles have no direct finance writes',
    count(*)::bigint,
    'anon and authenticated cannot INSERT, UPDATE, DELETE, or TRUNCATE finance tables'
  from (
    values
      ('finance_document_counters'),
      ('finance_transactions'),
      ('advance_lots'),
      ('advance_repayments'),
      ('product_stock_movements'),
      ('finance_product_sales'),
      ('finance_stock_receipts'),
      ('business_expenses'),
      ('cash_ledger_entries'),
      ('finance_audit_events')
  ) as expected(table_name)
  cross join (values ('anon'), ('authenticated')) as browser(role_name)
  where has_table_privilege(
          browser.role_name, 'public.' || expected.table_name, 'INSERT'
        )
     or has_table_privilege(
          browser.role_name, 'public.' || expected.table_name, 'UPDATE'
        )
     or has_table_privilege(
          browser.role_name, 'public.' || expected.table_name, 'DELETE'
        )
     or has_table_privilege(
          browser.role_name, 'public.' || expected.table_name, 'TRUNCATE'
        )

  union all
  select
    '03 exact owner RPC signatures exist',
    count(*)::bigint,
    'all eight UI-facing functions exist with exact argument names'
  from (
    values
      (
        'public.get_product_stock_balances()',
        array[]::text[]
      ),
      (
        'public.get_farmer_debt_balances()',
        array[]::text[]
      ),
      (
        'public.get_daily_cash_flow()',
        array[]::text[]
      ),
      (
        'public.issue_advance(uuid,text,text,bigint,numeric,text,numeric,bigint,text,text)',
        array[
          'p_request_id', 'p_customer_id', 'p_advance_type',
          'p_principal_kyat', 'p_monthly_interest_rate', 'p_product_id',
          'p_quantity', 'p_unit_price_kyat', 'p_location_id', 'p_notes'
        ]::text[]
      ),
      (
        'public.repay_advance(uuid,uuid,bigint,numeric,text,text,text)',
        array[
          'p_request_id', 'p_advance_lot_id', 'p_principal_kyat',
          'p_quantity', 'p_payment_method', 'p_payment_reference', 'p_notes'
        ]::text[]
      ),
      (
        'public.record_product_sale(uuid,text,text,text,text,text,numeric,bigint,text,text,text)',
        array[
          'p_request_id', 'p_customer_type', 'p_customer_id', 'p_buyer_name',
          'p_product_id', 'p_location_id', 'p_quantity',
          'p_unit_price_kyat', 'p_payment_method', 'p_payment_reference',
          'p_notes'
        ]::text[]
      ),
      (
        'public.record_stock_receipt(uuid,text,text,text,numeric,bigint,text,text,text)',
        array[
          'p_request_id', 'p_supplier_name', 'p_product_id', 'p_location_id',
          'p_quantity', 'p_unit_cost_kyat', 'p_payment_method',
          'p_payment_reference', 'p_notes'
        ]::text[]
      ),
      (
        'public.record_business_expense(uuid,text,bigint,text,text,text)',
        array[
          'p_request_id', 'p_category', 'p_amount_kyat',
          'p_payment_method', 'p_payment_reference', 'p_notes'
        ]::text[]
      )
  ) as expected(signature, argument_names)
  left join pg_proc as proc
    on proc.oid = to_regprocedure(expected.signature)
   and coalesce(proc.proargnames[1:proc.pronargs], array[]::text[])
       = expected.argument_names
  where proc.oid is null

  union all
  select
    '04 owner RPC execute grants are present',
    count(*)::bigint,
    'authenticated can execute all eight entry points and anon can execute none'
  from (
    values
      ('public.get_product_stock_balances()'),
      ('public.get_farmer_debt_balances()'),
      ('public.get_daily_cash_flow()'),
      ('public.issue_advance(uuid,text,text,bigint,numeric,text,numeric,bigint,text,text)'),
      ('public.repay_advance(uuid,uuid,bigint,numeric,text,text,text)'),
      ('public.record_product_sale(uuid,text,text,text,text,text,numeric,bigint,text,text,text)'),
      ('public.record_stock_receipt(uuid,text,text,text,numeric,bigint,text,text,text)'),
      ('public.record_business_expense(uuid,text,bigint,text,text,text)')
  ) as expected(signature)
  where not has_function_privilege(
          'authenticated', expected.signature, 'EXECUTE'
        )
     or has_function_privilege('anon', expected.signature, 'EXECUTE')

  union all
  select
    '05 internal helper execution is closed',
    count(*)::bigint,
    'anon and authenticated cannot call counters, stock helper, or trigger helpers'
  from (
    values
      ('public.next_finance_document_ref(text,date)'),
      ('public.product_stock_quantity(text,text)'),
      ('public.create_opening_advance_lot()'),
      ('public.prevent_finance_ledger_mutation()'),
      ('public.guard_advance_lot_mutation()')
  ) as expected(signature)
  where has_function_privilege(
          'authenticated', expected.signature, 'EXECUTE'
        )
     or has_function_privilege('anon', expected.signature, 'EXECUTE')

  union all
  select
    '06 realtime tables are published',
    count(*)::bigint,
    'all seven UI-listened tables are in supabase_realtime'
  from (
    values
      ('advance_lots'),
      ('advance_repayments'),
      ('product_stock_movements'),
      ('finance_product_sales'),
      ('finance_stock_receipts'),
      ('business_expenses'),
      ('cash_ledger_entries')
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
    'advance-lot and append-only table guards are enabled'
  from (
    values
      ('advance_lots', 'advance_lots_guard_update_delete'),
      ('advance_lots', 'advance_lots_prevent_truncate'),
      ('finance_transactions', 'finance_transactions_prevent_update_delete'),
      ('finance_transactions', 'finance_transactions_prevent_truncate'),
      ('advance_repayments', 'advance_repayments_prevent_update_delete'),
      ('advance_repayments', 'advance_repayments_prevent_truncate'),
      ('product_stock_movements', 'product_stock_movements_prevent_update_delete'),
      ('product_stock_movements', 'product_stock_movements_prevent_truncate'),
      ('finance_product_sales', 'finance_product_sales_prevent_update_delete'),
      ('finance_product_sales', 'finance_product_sales_prevent_truncate'),
      ('finance_stock_receipts', 'finance_stock_receipts_prevent_update_delete'),
      ('finance_stock_receipts', 'finance_stock_receipts_prevent_truncate'),
      ('business_expenses', 'business_expenses_prevent_update_delete'),
      ('business_expenses', 'business_expenses_prevent_truncate'),
      ('cash_ledger_entries', 'cash_ledger_entries_prevent_update_delete'),
      ('cash_ledger_entries', 'cash_ledger_entries_prevent_truncate'),
      ('finance_audit_events', 'finance_audit_events_prevent_update_delete'),
      ('finance_audit_events', 'finance_audit_events_prevent_truncate')
  ) as expected(table_name, trigger_name)
  left join pg_trigger as trig
    on trig.tgrelid = to_regclass('public.' || expected.table_name)
   and trig.tgname = expected.trigger_name
   and trig.tgenabled <> 'D'
  where trig.oid is null

  union all
  select
    '08 each transaction has its exact document row',
    count(*)::bigint,
    'one and only one matching advance, repayment, sale, receipt, or expense row exists'
  from public.finance_transactions as tx
  left join lateral (
    select
      (select count(*) from public.advance_lots as row
       where row.transaction_id = tx.id)
      + (select count(*) from public.advance_repayments as row
         where row.transaction_id = tx.id)
      + (select count(*) from public.finance_product_sales as row
         where row.transaction_id = tx.id)
      + (select count(*) from public.finance_stock_receipts as row
         where row.transaction_id = tx.id)
      + (select count(*) from public.business_expenses as row
         where row.transaction_id = tx.id) as child_count
  ) as children on true
  where tx.document_type in (
    'ADVANCE', 'ADVANCE_REPAYMENT', 'PRODUCT_SALE',
    'STOCK_RECEIPT', 'EXPENSE'
  ) and (
    children.child_count <> 1
     or (tx.document_type = 'ADVANCE' and not exists (
          select 1 from public.advance_lots where transaction_id = tx.id
        ))
     or (tx.document_type = 'ADVANCE_REPAYMENT' and not exists (
          select 1 from public.advance_repayments where transaction_id = tx.id
        ))
     or (tx.document_type = 'PRODUCT_SALE' and not exists (
          select 1 from public.finance_product_sales where transaction_id = tx.id
        ))
     or (tx.document_type = 'STOCK_RECEIPT' and not exists (
          select 1 from public.finance_stock_receipts where transaction_id = tx.id
        ))
     or (tx.document_type = 'EXPENSE' and not exists (
          select 1 from public.business_expenses where transaction_id = tx.id
        ))
  )

  union all
  select
    '09 document references and dates agree',
    count(*)::bigint,
    'transaction, document, cash, stock, and audit rows use one ref/date'
  from public.finance_transactions as tx
  where exists (
      select 1 from public.advance_lots as row
      where row.transaction_id = tx.id
        and (row.advance_ref <> tx.document_ref
             or row.issued_date <> tx.business_date)
    )
     or exists (
      select 1 from public.advance_repayments as row
      where row.transaction_id = tx.id
        and (row.repayment_ref <> case
               when row.payment_method = 'OFFSET'
                 then tx.document_ref || '-RP'
               else tx.document_ref end
             or row.payment_date <> tx.business_date)
    )
     or exists (
      select 1 from public.finance_product_sales as row
      where row.transaction_id = tx.id
        and (row.sale_ref <> tx.document_ref
             or row.business_date <> tx.business_date)
    )
     or exists (
      select 1 from public.finance_stock_receipts as row
      where row.transaction_id = tx.id
        and (row.receipt_ref <> tx.document_ref
             or row.business_date <> tx.business_date)
    )
     or exists (
      select 1 from public.business_expenses as row
      where row.transaction_id = tx.id
        and (row.expense_ref <> tx.document_ref
             or row.business_date <> tx.business_date)
    )
     or exists (
      select 1 from public.cash_ledger_entries as row
      where row.transaction_id = tx.id
        and (row.document_ref <> tx.document_ref
             or row.business_date <> tx.business_date)
    )
     or exists (
      select 1 from public.product_stock_movements as row
      where row.transaction_id = tx.id
        and (row.movement_ref <> tx.document_ref
             or row.business_date <> tx.business_date)
    )
     or exists (
      select 1 from public.finance_audit_events as row
      where row.transaction_id = tx.id and row.document_ref <> tx.document_ref
    )

  union all
  select
    '10 advance principal and quantity reconcile',
    count(*)::bigint,
    'lot totals and every repayment before/after snapshot reconcile'
  from public.advance_lots as lot
  left join lateral (
    select
      coalesce(sum(payment.principal_kyat), 0)::bigint as principal_paid,
      coalesce(sum(payment.selected_quantity), 0)::numeric as quantity_paid
    from public.advance_repayments as payment
    where payment.advance_lot_id = lot.id
  ) as paid on true
  where lot.remaining_principal_kyat
        <> lot.original_principal_kyat - paid.principal_paid
     or (
       lot.advance_type = 'GOODS'
       and lot.remaining_quantity
           <> lot.original_quantity - paid.quantity_paid
     )
     or (
       lot.advance_type = 'GOODS'
       and ((lot.remaining_quantity = 0)
            <> (lot.remaining_principal_kyat = 0))
     )
     or exists (
       select 1
       from public.advance_repayments as payment
       where payment.advance_lot_id = lot.id
         and (
           payment.remaining_principal_kyat
             <> payment.principal_before_kyat - payment.principal_kyat
           or (
             lot.advance_type = 'GOODS'
             and (
               payment.quantity_before is null
               or payment.selected_quantity is null
               or payment.remaining_quantity is null
               or payment.remaining_quantity
                    <> payment.quantity_before - payment.selected_quantity
               or ((payment.remaining_quantity = 0)
                    <> (payment.remaining_principal_kyat = 0))
             )
           )
         )
     )

  union all
  select
    '11 advance status agrees with balance',
    count(*)::bigint,
    'OPEN, PARTIAL, and PAID match principal and goods quantity balances'
  from public.advance_lots as lot
  where (lot.status = 'OPEN'
         and (lot.remaining_principal_kyat <> lot.original_principal_kyat
              or (lot.advance_type = 'GOODS'
                  and lot.remaining_quantity <> lot.original_quantity)))
     or (lot.status = 'PARTIAL'
         and not (lot.remaining_principal_kyat > 0
                  and lot.remaining_principal_kyat < lot.original_principal_kyat
                  and (lot.advance_type = 'CASH'
                       or lot.remaining_quantity > 0)))
     or (lot.status = 'PAID'
         and (lot.remaining_principal_kyat <> 0
              or (lot.advance_type = 'GOODS'
                  and lot.remaining_quantity <> 0)))

  union all
  select
    '12 repayment half-month interest is exact',
    count(*)::bigint,
    '0 days=0; 1-15=half month; 16-30=one month; then each 15 days'
  from public.advance_repayments as payment
  join public.advance_lots as lot on lot.id = payment.advance_lot_id
  where payment.elapsed_days <> payment.payment_date - lot.issued_date
     or payment.half_month_steps
        <> case
             when payment.elapsed_days = 0 then 0
             else (payment.elapsed_days + 14) / 15
           end
     or payment.interest_kyat <> round(
          payment.principal_kyat::numeric
          * payment.monthly_interest_rate_snapshot / 100
          * payment.half_month_steps / 2
        )::bigint
     or payment.total_received_kyat
        <> payment.principal_kyat + payment.interest_kyat

  union all
  select
    '13 stock balances never go below zero',
    count(*)::bigint,
    'opening stock plus all movements is non-negative per product/location'
  from (
    select product_id, location_id, sum(quantity) as balance
    from (
      select product_id, location_id, quantity
      from public.opening_balance_entries
      where entry_type = 'PRODUCT_STOCK'
      union all
      select product_id, location_id, quantity_delta
      from public.product_stock_movements
    ) as entries
    group by product_id, location_id
  ) as balances
  where balances.balance < 0

  union all
  select
    '14 whole-unit products stay whole',
    count(*)::bigint,
    'whole-unit openings, movements, sales, receipts, and goods lots are integers'
  from (
    select opening.product_id, opening.quantity
    from public.opening_balance_entries as opening
    join public.products as product on product.product_id = opening.product_id
    where opening.entry_type = 'PRODUCT_STOCK'
      and product.whole_units_only
      and opening.quantity <> trunc(opening.quantity)
    union all
    select movement.product_id, abs(movement.quantity_delta)
    from public.product_stock_movements as movement
    join public.products as product on product.product_id = movement.product_id
    where product.whole_units_only
      and movement.quantity_delta <> trunc(movement.quantity_delta)
    union all
    select sale.product_id, sale.quantity
    from public.finance_product_sales as sale
    join public.products as product on product.product_id = sale.product_id
    where product.whole_units_only
      and sale.quantity <> trunc(sale.quantity)
    union all
    select receipt.product_id, receipt.quantity
    from public.finance_stock_receipts as receipt
    join public.products as product on product.product_id = receipt.product_id
    where product.whole_units_only
      and receipt.quantity <> trunc(receipt.quantity)
    union all
    select lot.product_id, lot.original_quantity
    from public.advance_lots as lot
    where lot.advance_type = 'GOODS'
      and lot.whole_units_only
      and lot.original_quantity <> trunc(lot.original_quantity)
  ) as invalid_whole_units

  union all
  select
    '15 cash and stock postings match document type',
    count(*)::bigint,
    'each document reconciles exactly to its one cash/stock posting'
  from public.finance_transactions as tx
  left join lateral (
    select
      count(*) filter (where cash.direction = 'IN')::integer as cash_in,
      count(*) filter (where cash.direction = 'OUT')::integer as cash_out
    from public.cash_ledger_entries as cash
    where cash.transaction_id = tx.id
  ) as cash_count on true
  left join lateral (
    select count(*)::integer as stock_movements
    from public.product_stock_movements as movement
    where movement.transaction_id = tx.id
  ) as stock_count on true
  left join public.advance_lots as lot on lot.transaction_id = tx.id
  where (tx.document_type = 'ADVANCE' and lot.advance_type = 'CASH'
         and (cash_count.cash_out <> 1 or cash_count.cash_in <> 0
              or stock_count.stock_movements <> 0
              or not exists (
                select 1
                from public.cash_ledger_entries as cash
                where cash.transaction_id = tx.id
                  and cash.direction = 'OUT'
                  and cash.category = 'ADVANCE'
                  and cash.amount_kyat = lot.original_principal_kyat
                  and cash.principal_kyat = lot.original_principal_kyat
                  and cash.interest_kyat = 0
              )))
     or (tx.document_type = 'ADVANCE' and lot.advance_type = 'GOODS'
         and (cash_count.cash_out <> 0 or cash_count.cash_in <> 0
              or stock_count.stock_movements <> 1
              or not exists (
                select 1 from public.product_stock_movements as movement
                where movement.transaction_id = tx.id
                  and movement.movement_type = 'OUT_ADVANCE'
                  and movement.product_id = lot.product_id
                  and movement.location_id = lot.location_id
                  and movement.quantity_delta = -lot.original_quantity
                  and movement.quantity_after
                      = movement.quantity_before - lot.original_quantity
              )))
     or (tx.document_type = 'ADVANCE_REPAYMENT'
         and (cash_count.cash_in <> 1 or cash_count.cash_out <> 0
              or stock_count.stock_movements <> 0
              or not exists (
                select 1
                from public.advance_repayments as payment
                join public.cash_ledger_entries as cash
                  on cash.transaction_id = payment.transaction_id
                where payment.transaction_id = tx.id
                  and cash.direction = 'IN'
                  and cash.category = 'DEBT_REPAYMENT'
                  and cash.amount_kyat = payment.total_received_kyat
                  and cash.principal_kyat = payment.principal_kyat
                  and cash.interest_kyat = payment.interest_kyat
                  and cash.payment_method = payment.payment_method
              )))
     or (tx.document_type = 'PRODUCT_SALE'
         and (cash_count.cash_in <> 1 or cash_count.cash_out <> 0
              or stock_count.stock_movements <> 1
              or not exists (
                select 1
                from public.finance_product_sales as sale
                join public.product_stock_movements as movement
                  on movement.transaction_id = sale.transaction_id
                join public.cash_ledger_entries as cash
                  on cash.transaction_id = sale.transaction_id
                where sale.transaction_id = tx.id
                  and movement.movement_type = 'OUT_SALE'
                  and movement.product_id = sale.product_id
                  and movement.location_id = sale.location_id
                  and movement.quantity_delta = -sale.quantity
                  and movement.quantity_before = sale.stock_before
                  and movement.quantity_after = sale.stock_after
                  and sale.stock_after = sale.stock_before - sale.quantity
                  and cash.direction = 'IN'
                  and cash.category = 'PRODUCT_SALE'
                  and cash.amount_kyat = sale.total_kyat
                  and cash.payment_method = sale.payment_method
              )))
     or (tx.document_type = 'STOCK_RECEIPT'
         and (cash_count.cash_out <> 1 or cash_count.cash_in <> 0
              or stock_count.stock_movements <> 1
              or not exists (
                select 1
                from public.finance_stock_receipts as receipt
                join public.product_stock_movements as movement
                  on movement.transaction_id = receipt.transaction_id
                join public.cash_ledger_entries as cash
                  on cash.transaction_id = receipt.transaction_id
                where receipt.transaction_id = tx.id
                  and cash.category = 'STOCK_PURCHASE'
                  and cash.direction = 'OUT'
                  and cash.amount_kyat = receipt.total_kyat
                  and cash.payment_method = receipt.payment_method
                  and movement.movement_type = 'IN_PURCHASE'
                  and movement.product_id = receipt.product_id
                  and movement.location_id = receipt.location_id
                  and movement.quantity_delta = receipt.quantity
                  and movement.quantity_before = receipt.stock_before
                  and movement.quantity_after = receipt.stock_after
                  and receipt.stock_after
                      = receipt.stock_before + receipt.quantity
              )))
     or (tx.document_type = 'EXPENSE'
         and (cash_count.cash_out <> 1 or cash_count.cash_in <> 0
              or stock_count.stock_movements <> 0
              or not exists (
                select 1
                from public.business_expenses as expense
                join public.cash_ledger_entries as cash
                  on cash.transaction_id = expense.transaction_id
                where expense.transaction_id = tx.id
                  and cash.direction = 'OUT'
                  and cash.category = 'EXPENSE'
                  and cash.amount_kyat = expense.amount_kyat
                  and cash.payment_method = expense.payment_method
              )))

  union all
  select
    '16 each transaction has an audit event',
    count(*)::bigint,
    'every server-posted document has at least one immutable audit row'
  from public.finance_transactions as tx
  where not exists (
    select 1 from public.finance_audit_events as audit
    where audit.transaction_id = tx.id
      and audit.document_ref = tx.document_ref
  )

  union all
  select
    '17 opening farmer debts have repayable lots',
    count(*)::bigint,
    'each FARMER_DEBT opening entry has one linked cash advance lot'
  from public.opening_balance_entries as opening
  left join public.advance_lots as lot
    on lot.opening_balance_entry_id = opening.id
  where opening.entry_type = 'FARMER_DEBT'
    and (
      lot.id is null
      or lot.advance_type <> 'CASH'
      or lot.original_principal_kyat <> opening.principal_kyat
      or lot.issued_date <> opening.opening_date
    )

  union all
  select
    '18 active owner remains',
    case when exists (
      select 1
      from public.staff_members
      where role = 'owner' and active = true
    ) then 0 else 1 end::bigint,
    'at least one active owner can operate the finance ledger'

  union all
  select
    '19 owner-only read policies are exact',
    count(*)::bigint,
    'each readable finance table has one authenticated owner-only SELECT policy'
  from (
    values
      ('finance_transactions', 'Owner can read finance transactions'),
      ('advance_lots', 'Owner can read advance lots'),
      ('advance_repayments', 'Owner can read advance repayments'),
      ('product_stock_movements', 'Owner can read product stock movements'),
      ('finance_product_sales', 'Owner can read finance product sales'),
      ('finance_stock_receipts', 'Owner can read finance stock receipts'),
      ('business_expenses', 'Owner can read business expenses'),
      ('cash_ledger_entries', 'Owner can read cash ledger'),
      ('finance_audit_events', 'Owner can read finance audit')
  ) as expected(table_name, policy_name)
  where not exists (
      select 1
      from pg_policies as policy
      where policy.schemaname = 'public'
        and policy.tablename = expected.table_name
        and policy.policyname = expected.policy_name
        and policy.cmd = 'SELECT'
        and policy.roles @> array['authenticated']::name[]
        and policy.qual like '%current_staff_has_role%'
        and policy.qual like '%owner%'
    )
     or exists (
      select 1
      from pg_policies as policy
      where policy.schemaname = 'public'
        and policy.tablename = expected.table_name
        and policy.policyname <> expected.policy_name
        and policy.cmd in ('ALL', 'SELECT')
    )
), results as (
  select
    check_name,
    case when violations = 0 then 'PASS' else 'FAIL' end as status,
    violations,
    expectation
  from checks
)
select check_name, status, violations, expectation
from results
union all
select
  'OVERALL',
  case when sum(violations) = 0 then 'PASS' else 'FAIL' end,
  sum(violations)::bigint,
  'all owner-finance production checks must pass'
from results
order by check_name;
