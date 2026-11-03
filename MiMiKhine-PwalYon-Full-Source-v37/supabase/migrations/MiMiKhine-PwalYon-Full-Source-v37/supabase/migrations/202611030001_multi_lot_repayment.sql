-- =========================================================
-- Multiple advance lots → one repayment receipt / voucher
-- Do not run this partial migration in Supabase yet.
-- The RPC function will be added in the next step.
-- =========================================================

-- 1. RP ဘောင်ချာတစ်စောင်၏ Header စာရင်း
create table if not exists public.advance_repayment_batches (
  id uuid primary key default gen_random_uuid(),

  -- Finance transaction တစ်ခု = RP ဘောင်ချာတစ်စောင်
  transaction_id uuid not null unique
    references public.finance_transactions (id)
    on update restrict
    on delete restrict,

  -- Customer ကို ပြမည့် RP ဘောင်ချာနံပါတ်
  receipt_ref text not null unique,

  customer_id text not null
    references public.farmers (customer_id)
    on update restrict
    on delete restrict,

  farmer_name_snapshot text not null,

  payment_date date not null,

  payment_method text not null,

  payment_reference text,

  notes text,

  total_principal_kyat bigint not null default 0,
  total_interest_kyat bigint not null default 0,
  total_received_kyat bigint not null default 0,

  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),

  constraint advance_repayment_batch_method_valid check (
    payment_method in ('CASH', 'BANK', 'MOBILE')
  ),

  constraint advance_repayment_batch_reference_valid check (
    payment_method = 'CASH'
    or length(trim(coalesce(payment_reference, ''))) between 1 and 160
  ),

  constraint advance_repayment_batch_money_valid check (
    total_principal_kyat >= 0
    and total_interest_kyat >= 0
    and total_received_kyat =
      total_principal_kyat + total_interest_kyat
  ),

  constraint advance_repayment_batch_notes_length check (
    notes is null or length(notes) <= 500
  )
);

create index if not exists advance_repayment_batches_farmer_date_idx
  on public.advance_repayment_batches (
    customer_id,
    payment_date desc,
    created_at desc
  );

-- 2. ယခင် single-lot repayment စာရင်းများကို မထိခိုက်စေဘဲ
--    multi-lot batch တစ်ခုအောက်တွင် line item အဖြစ် ချိတ်နိုင်ရန်
alter table public.advance_repayments
  add column if not exists batch_id uuid
  references public.advance_repayment_batches (id)
  on update restrict
  on delete restrict;

-- ယခင်စနစ်တွင် transaction_id တစ်ခုလျှင် repayment တစ်ကြောင်းသာရှိခဲ့သည်။
-- Batch စနစ်တွင် parent transaction ကို batch header ကပိုင်မည်။
-- Repayment line တစ်ကြောင်းချင်းသည် batch_id နှင့် ချိတ်မည်။
alter table public.advance_repayments
  alter column transaction_id drop not null;

alter table public.advance_repayments
  drop constraint if exists advance_repayments_transaction_id_key;

-- စာရင်းဟောင်း = transaction_id ရှိပြီး batch_id မရှိ
-- စာရင်းအသစ် = batch_id ရှိပြီး transaction_id မရှိ
alter table public.advance_repayments
  drop constraint if exists advance_repayments_owner_link_valid;

alter table public.advance_repayments
  add constraint advance_repayments_owner_link_valid check (
    (
      transaction_id is not null
      and batch_id is null
    )
    or
    (
      transaction_id is null
      and batch_id is not null
    )
  );

create index if not exists advance_repayments_batch_idx
  on public.advance_repayments (
    batch_id,
    created_at,
    id
  )
  where batch_id is not null;
-- =========================================================
-- 3. Multiple advance lots → one RP voucher / one Cash Book entry
-- =========================================================

create or replace function public.repay_advances_batch(
  p_request_id uuid,
  p_customer_id text,
  p_lines jsonb,
  p_payment_method text,
  p_payment_reference text,
  p_notes text
)
returns table (
  repayment_batch_id uuid,
  repayment_ref text,
  payment_date date,
  total_principal_kyat bigint,
  total_interest_kyat bigint,
  total_received_kyat bigint,
  repayment_lines jsonb,
  idempotent boolean
)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_existing_tx public.finance_transactions%rowtype;
  v_existing_batch public.advance_repayment_batches%rowtype;

  v_farmer public.farmers%rowtype;
  v_lot public.advance_lots%rowtype;

  v_customer_id text := trim(coalesce(p_customer_id, ''));
  v_method text := upper(trim(coalesce(p_payment_method, '')));
  v_payment_reference text :=
    nullif(trim(coalesce(p_payment_reference, '')), '');
  v_notes text := nullif(trim(coalesce(p_notes, '')), '');

  v_lines jsonb := coalesce(p_lines, '[]'::jsonb);
  v_payload jsonb;

  v_business_date date := public.get_business_date();
  v_transaction_id uuid;
  v_batch_id uuid;
  v_ref text;

  v_line jsonb;
  v_lot_id uuid;
  v_line_ref text;
  v_line_no integer := 0;

  v_principal_input bigint;
  v_quantity_input numeric(20, 3);

  v_principal bigint;
  v_interest bigint;
  v_total bigint;
  v_days integer;
  v_steps integer;

  v_remaining_principal bigint;
  v_remaining_quantity numeric(20, 3);
  v_status text;

  v_total_principal bigint := 0;
  v_total_interest bigint := 0;
  v_total_received bigint := 0;

  v_result_lines jsonb;
begin
  perform public.require_staff_roles(array['owner']);

  if p_request_id is null then
    raise exception 'Repayment request ID is required'
      using errcode = '22023';
  end if;

  if v_customer_id = '' then
    raise exception 'Farmer is required'
      using errcode = '22023';
  end if;

  if jsonb_typeof(v_lines) <> 'array'
    or jsonb_array_length(v_lines) = 0 then
    raise exception 'At least one advance lot is required'
      using errcode = '22023';
  end if;

  if v_method not in ('CASH', 'BANK', 'MOBILE') then
    raise exception 'Payment method must be CASH, BANK or MOBILE'
      using errcode = '22023';
  end if;

  if v_method <> 'CASH' and v_payment_reference is null then
    raise exception 'Bank or mobile payment reference is required'
      using errcode = '22023';
  end if;

  if v_notes is not null and length(v_notes) > 500 then
    raise exception 'Repayment notes cannot exceed 500 characters'
      using errcode = '22023';
  end if;

  -- တစ် Lot ကို တစ်ဘောင်ချာတည်းတွင် နှစ်ကြိမ်မထည့်စေရန်
  if exists (
    select 1
    from jsonb_array_elements(v_lines) as input_line(value)
    group by nullif(trim(input_line.value ->> 'advance_lot_id'), '')
    having nullif(trim(input_line.value ->> 'advance_lot_id'), '') is null
       or count(*) > 1
  ) then
    raise exception
      'Each repayment line must have one unique advance_lot_id'
      using errcode = '22023';
  end if;

  select farmers.*
    into v_farmer
  from public.farmers as farmers
  where farmers.customer_id = v_customer_id;

  if not found then
    raise exception 'Farmer not found'
      using errcode = '23503';
  end if;

  -- ထပ်နှိပ်မိပါက တူညီသော result ကိုသာ ပြန်ပေးရန်
  v_payload := jsonb_build_object(
    'customer_id', v_customer_id,
    'lines', v_lines,
    'payment_method', v_method,
    'payment_reference', v_payment_reference,
    'notes', v_notes
  );

  select transactions.*
    into v_existing_tx
  from public.finance_transactions as transactions
  where transactions.request_id = p_request_id;

  if found then
    if v_existing_tx.document_type <> 'ADVANCE_REPAYMENT' then
      raise exception 'Request ID already belongs to another finance operation'
        using errcode = '23505';
    end if;

    if v_existing_tx.request_payload <> v_payload then
      raise exception
        'Request ID was already used with different repayment data'
        using errcode = '23505';
    end if;

    select batches.*
      into v_existing_batch
    from public.advance_repayment_batches as batches
    where batches.transaction_id = v_existing_tx.id;

    if not found then
      raise exception
        'Request ID belongs to an old single-lot repayment'
        using errcode = '23505';
    end if;

    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'line_ref', repayments.repayment_ref,
          'advance_lot_id', repayments.advance_lot_id,
          'advance_ref', lots.advance_ref,
          'advance_type', lots.advance_type,
          'item_name',
            coalesce(lots.product_name_snapshot, 'ငွေသား'),
          'selected_quantity', repayments.selected_quantity,
          'principal_kyat', repayments.principal_kyat,
          'interest_kyat', repayments.interest_kyat,
          'total_received_kyat', repayments.total_received_kyat,
          'elapsed_days', repayments.elapsed_days,
          'half_month_steps', repayments.half_month_steps,
          'remaining_principal_kyat',
            repayments.remaining_principal_kyat,
          'remaining_quantity', repayments.remaining_quantity
        )
        order by repayments.created_at, repayments.id
      ),
      '[]'::jsonb
    )
    into v_result_lines
    from public.advance_repayments as repayments
    join public.advance_lots as lots
      on lots.id = repayments.advance_lot_id
    where repayments.batch_id = v_existing_batch.id;

    return query
    select
      v_existing_batch.id,
      v_existing_batch.receipt_ref,
      v_existing_batch.payment_date,
      v_existing_batch.total_principal_kyat,
      v_existing_batch.total_interest_kyat,
      v_existing_batch.total_received_kyat,
      v_result_lines,
      true;

    return;
  end if;

  -- RP ဘောင်ချာ Header တစ်ခုတည်းအတွက် Finance Transaction တစ်ခုသာတည်ဆောက်သည်
  v_ref := public.next_finance_document_ref('RP', v_business_date);

  insert into public.finance_transactions (
    request_id,
    request_payload,
    document_ref,
    document_type,
    business_date,
    created_by
  ) values (
    p_request_id,
    v_payload,
    v_ref,
    'ADVANCE_REPAYMENT',
    v_business_date,
    auth.uid()
  )
  returning id into v_transaction_id;

  insert into public.advance_repayment_batches (
    transaction_id,
    receipt_ref,
    customer_id,
    farmer_name_snapshot,
    payment_date,
    payment_method,
    payment_reference,
    notes,
    total_principal_kyat,
    total_interest_kyat,
    total_received_kyat,
    created_by
  ) values (
    v_transaction_id,
    v_ref,
    v_farmer.customer_id,
    v_farmer.full_name,
    v_business_date,
    v_method,
    v_payment_reference,
    v_notes,
    0,
    0,
    0,
    auth.uid()
  )
  returning id into v_batch_id;

  -- advance_lots နှင့် batch header ကို Server function အတွင်းသာ update ခွင့်ပြုရန်
  perform set_config('app.finance_post', 'on', true);

  -- UUID အစဉ်လိုက် lock လုပ်ထားသဖြင့် transaction တိုက်မိနိုင်ခြေနည်းစေသည်
  for v_line in
    select input_line.value
    from jsonb_array_elements(v_lines) as input_line(value)
    order by input_line.value ->> 'advance_lot_id'
  loop
    v_line_no := v_line_no + 1;

    v_lot_id :=
      nullif(trim(v_line ->> 'advance_lot_id'), '')::uuid;

    select lots.*
      into v_lot
    from public.advance_lots as lots
    where lots.id = v_lot_id
    for update;

    if not found then
      raise exception 'Advance lot not found'
        using errcode = '23503';
    end if;

    if v_lot.customer_id <> v_customer_id then
      raise exception
        'All selected advance lots must belong to the same farmer'
        using errcode = '22023';
    end if;

    if v_lot.status = 'PAID'
      or v_lot.remaining_principal_kyat <= 0 then
      raise exception 'One selected advance lot is already paid'
        using errcode = '22023';
    end if;

    if v_business_date < v_lot.issued_date then
      raise exception
        'Server business date is before one advance issue date'
        using errcode = '22023';
    end if;

    -- GOODS အကြွေးဆို quantity ဖြင့်၊ CASH အကြွေးဆို principal ဖြင့် ဆပ်သည်
    if v_lot.advance_type = 'GOODS' then
      v_quantity_input :=
        nullif(trim(v_line ->> 'quantity'), '')::numeric;

      if v_quantity_input is null
        or v_quantity_input <= 0
        or v_quantity_input <> round(v_quantity_input, 3) then
        raise exception
          'Goods repayment quantity must be positive with up to three decimals'
          using errcode = '22023';
      end if;

      if v_lot.whole_units_only
        and v_quantity_input <> trunc(v_quantity_input) then
        raise exception
          'Product requires a whole-unit repayment quantity'
          using errcode = '22023';
      end if;

      if v_quantity_input > v_lot.remaining_quantity then
        raise exception
          'Goods repayment quantity exceeds remaining quantity'
          using errcode = '22023';
      end if;

      if v_quantity_input = v_lot.remaining_quantity then
        v_principal := v_lot.remaining_principal_kyat;
        v_remaining_quantity := 0;
      else
        v_principal :=
          round(v_quantity_input * v_lot.unit_price_kyat)::bigint;

        if v_principal <= 0 then
          raise exception
            'Partial goods repayment is too small'
            using errcode = '22023';
        end if;

        if v_principal >= v_lot.remaining_principal_kyat then
          raise exception
            'For this goods lot, repay the full remaining quantity'
            using errcode = '22023';
        end if;

        v_remaining_quantity :=
          v_lot.remaining_quantity - v_quantity_input;
      end if;

      v_quantity_input := round(v_quantity_input, 3);

    else
      v_principal_input :=
        nullif(trim(v_line ->> 'principal_kyat'), '')::bigint;

      if v_principal_input is null
        or v_principal_input <= 0
        or v_principal_input > v_lot.remaining_principal_kyat then
        raise exception
          'Cash repayment principal must be positive and within balance'
          using errcode = '22023';
      end if;

      v_principal := v_principal_input;
      v_quantity_input := null;
      v_remaining_quantity := null;
    end if;

    if v_principal <= 0
      or v_principal > v_lot.remaining_principal_kyat then
      raise exception 'Repayment principal exceeds remaining principal'
        using errcode = '22023';
    end if;

    -- အတိုးကို ရွေးထားသော lot တစ်ခုချင်းစီ၏ ထုတ်ရက် / အတိုးနှုန်းဖြင့်တွက်သည်
    v_days := v_business_date - v_lot.issued_date;

    v_steps := case
      when v_days = 0 then 0
      else (v_days + 14) / 15
    end;

    v_interest := round(
      v_principal::numeric
      * v_lot.monthly_interest_rate / 100
      * v_steps / 2
    )::bigint;

    v_total := v_principal + v_interest;

    v_remaining_principal :=
      v_lot.remaining_principal_kyat - v_principal;

    if v_lot.advance_type = 'GOODS'
      and (
        (v_remaining_quantity = 0)
        <> (v_remaining_principal = 0)
      ) then
      raise exception
        'Goods repayment would close quantity and principal inconsistently'
        using errcode = '23514';
    end if;

    v_status := case
      when v_lot.advance_type = 'GOODS'
        and v_remaining_quantity = 0
        and v_remaining_principal = 0
        then 'PAID'

      when v_lot.advance_type = 'GOODS'
        then 'PARTIAL'

      when v_remaining_principal = 0
        then 'PAID'

      when v_remaining_principal < v_lot.original_principal_kyat
        then 'PARTIAL'

      else 'OPEN'
    end;

    update public.advance_lots as lots
    set
      remaining_principal_kyat = v_remaining_principal,
      remaining_quantity = v_remaining_quantity,
      status = v_status,
      updated_at = now()
    where lots.id = v_lot.id;

    -- Customer ကို ပြမည့် ဘောင်ချာနံပါတ်က Header RP Ref တစ်ခုတည်းဖြစ်သည်။
    -- Line Ref သည် Server အတွင်းသာ ခွဲခြားဖော်ပြရန် ဖြစ်သည်။
    v_line_ref :=
      v_ref || '-' || lpad(v_line_no::text, 2, '0');

    insert into public.advance_repayments (
      transaction_id,
      batch_id,
      repayment_ref,
      advance_lot_id,
      payment_date,
      quantity_before,
      selected_quantity,
      principal_before_kyat,
      principal_kyat,
      interest_kyat,
      total_received_kyat,
      elapsed_days,
      half_month_steps,
      monthly_interest_rate_snapshot,
      payment_method,
      payment_reference,
      notes,
      remaining_quantity,
      remaining_principal_kyat,
      created_by
    ) values (
      null,
      v_batch_id,
      v_line_ref,
      v_lot.id,
      v_business_date,
      v_lot.remaining_quantity,
      v_quantity_input,
      v_lot.remaining_principal_kyat,
      v_principal,
      v_interest,
      v_total,
      v_days,
      v_steps,
      v_lot.monthly_interest_rate,
      v_method,
      v_payment_reference,
      v_notes,
      v_remaining_quantity,
      v_remaining_principal,
      auth.uid()
    );

    insert into public.finance_audit_events (
      transaction_id,
      document_ref,
      action,
      payload,
      created_by
    ) values (
      v_transaction_id,
      v_ref,
      'ADVANCE_REPAID_IN_BATCH',
      jsonb_build_object(
        'batch_id', v_batch_id,
        'advance_lot_id', v_lot.id,
        'advance_ref', v_lot.advance_ref,
        'line_ref', v_line_ref,
        'selected_quantity', v_quantity_input,
        'principal_kyat', v_principal,
        'interest_kyat', v_interest,
        'total_received_kyat', v_total,
        'elapsed_days', v_days,
        'half_month_steps', v_steps,
        'remaining_principal_kyat', v_remaining_principal,
        'remaining_quantity', v_remaining_quantity
      ),
      auth.uid()
    );

    v_total_principal := v_total_principal + v_principal;
    v_total_interest := v_total_interest + v_interest;
    v_total_received := v_total_received + v_total;
  end loop;

  -- Header စုစုပေါင်းကို line item အားလုံးမှ တွက်ပြီး update လုပ်သည်
  update public.advance_repayment_batches
  set
    total_principal_kyat = v_total_principal,
    total_interest_kyat = v_total_interest,
    total_received_kyat = v_total_received
  where id = v_batch_id;

  -- Cash Book တွင် တစ်ကြောင်းတည်းသာ ဝင်ရမည်
  insert into public.cash_ledger_entries (
    transaction_id,
    document_ref,
    business_date,
    direction,
    amount_kyat,
    payment_method,
    category,
    label,
    principal_kyat,
    interest_kyat,
    created_by
  ) values (
    v_transaction_id,
    v_ref,
    v_business_date,
    'IN',
    v_total_received,
    v_method,
    'DEBT_REPAYMENT',
    'စိုက်ထုတ်အကြွေးပြန်ဆပ် · '
      || v_farmer.full_name
      || ' · '
      || v_line_no
      || ' စာရင်း',
    v_total_principal,
    v_total_interest,
    auth.uid()
  );

  insert into public.finance_audit_events (
    transaction_id,
    document_ref,
    action,
    payload,
    created_by
  ) values (
    v_transaction_id,
    v_ref,
    'ADVANCE_REPAYMENT_BATCH_POSTED',
    jsonb_build_object(
      'batch_id', v_batch_id,
      'customer_id', v_customer_id,
      'line_count', v_line_no,
      'total_principal_kyat', v_total_principal,
      'total_interest_kyat', v_total_interest,
      'total_received_kyat', v_total_received
    ),
    auth.uid()
  );

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'line_ref', repayments.repayment_ref,
        'advance_lot_id', repayments.advance_lot_id,
        'advance_ref', lots.advance_ref,
        'advance_type', lots.advance_type,
        'item_name',
          coalesce(lots.product_name_snapshot, 'ငွေသား'),
        'selected_quantity', repayments.selected_quantity,
        'principal_kyat', repayments.principal_kyat,
        'interest_kyat', repayments.interest_kyat,
        'total_received_kyat', repayments.total_received_kyat,
        'elapsed_days', repayments.elapsed_days,
        'half_month_steps', repayments.half_month_steps,
        'remaining_principal_kyat',
          repayments.remaining_principal_kyat,
        'remaining_quantity', repayments.remaining_quantity
      )
      order by repayments.created_at, repayments.id
    ),
    '[]'::jsonb
  )
  into v_result_lines
  from public.advance_repayments as repayments
  join public.advance_lots as lots
    on lots.id = repayments.advance_lot_id
  where repayments.batch_id = v_batch_id;

  return query
  select
    v_batch_id,
    v_ref,
    v_business_date,
    v_total_principal,
    v_total_interest,
    v_total_received,
    v_result_lines,
    false;
end;
$$;


-- =========================================================
-- 4. Batch table ကို Finance Ledger လုံခြုံရေးစည်းမျဉ်းထဲ ထည့်ခြင်း
-- =========================================================

alter table public.advance_repayment_batches enable row level security;
alter table public.advance_repayment_batches force row level security;

revoke all on table public.advance_repayment_batches
  from anon, authenticated;

grant all on table public.advance_repayment_batches
  to service_role;

grant select on table public.advance_repayment_batches
  to authenticated;

drop policy if exists "Owner can read advance repayment batches"
  on public.advance_repayment_batches;

create policy "Owner can read advance repayment batches"
on public.advance_repayment_batches
for select
to authenticated
using (public.current_staff_has_role(array['owner']));


-- Batch Header ကို direct edit / delete မလုပ်နိုင်ရန်
drop trigger if exists advance_repayment_batches_prevent_update_delete
  on public.advance_repayment_batches;

create trigger advance_repayment_batches_prevent_update_delete
before update or delete
on public.advance_repayment_batches
for each row
execute function public.prevent_finance_ledger_mutation();


-- =========================================================
-- 5. RPC Permission
-- =========================================================

revoke all on function public.repay_advances_batch(
  uuid,
  text,
  jsonb,
  text,
  text,
  text
) from public, anon, authenticated;

grant execute on function public.repay_advances_batch(
  uuid,
  text,
  jsonb,
  text,
  text,
  text
) to authenticated, service_role;
