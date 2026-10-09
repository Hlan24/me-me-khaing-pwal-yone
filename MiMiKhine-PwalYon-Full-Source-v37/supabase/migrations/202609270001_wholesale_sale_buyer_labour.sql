-- Buyer-paid warehouse labour for wholesale bean/chili sales.
--
-- The warehouse records an actual bag count and a labour rate per bag. The
-- buyer owes that labour in addition to the crop value. Existing sales remain
-- unchanged because the new immutable snapshot columns default to zero.

begin;

alter table public.wholesale_crop_sales
  add column if not exists labour_rate_kyat bigint not null default 0,
  add column if not exists labour_total_kyat bigint not null default 0;

comment on column public.wholesale_crop_sales.labour_rate_kyat is
  'Buyer-paid warehouse labour rate per actual bag at sale time.';
comment on column public.wholesale_crop_sales.labour_total_kyat is
  'Buyer-paid warehouse labour: actual_bags multiplied by labour_rate_kyat.';

alter table public.wholesale_crop_sales
  drop constraint if exists wholesale_crop_sale_value_valid;

alter table public.wholesale_crop_sales
  add constraint wholesale_crop_sale_value_valid check (
    weight_centi_pyitha > 0 and actual_bags >= 0
    and pricing_divisor_pyitha > 0 and rate_kyat > 0
    and gross_value_kyat = round(weight_centi_pyitha::numeric
      / (100 * pricing_divisor_pyitha) * rate_kyat)::bigint
    and labour_rate_kyat >= 0
    and labour_total_kyat = actual_bags::bigint * labour_rate_kyat
    and freight_kyat >= 0 and freight_kyat <= gross_value_kyat
    and net_value_kyat
      = gross_value_kyat + labour_total_kyat - freight_kyat
    and received_kyat >= 0 and received_kyat <= net_value_kyat
    and receivable_kyat = net_value_kyat - received_kyat
  );

-- Keep the original 13-argument function for an older open browser. Calls
-- carrying p_labour_rate_kyat resolve to this new, unambiguous overload.
create or replace function public.record_wholesale_crop_sale(
  p_request_id uuid,
  p_buyer_name text,
  p_crop_type_id text,
  p_location_id text,
  p_weight_centi_pyitha bigint,
  p_actual_bags integer,
  p_pricing_divisor_pyitha integer,
  p_rate_kyat bigint,
  p_labour_rate_kyat bigint,
  p_freight_kyat bigint,
  p_received_kyat bigint,
  p_payment_method text,
  p_payment_reference text,
  p_notes text
)
returns table(
  sale_id uuid,
  sale_ref text,
  business_date date,
  gross_value_kyat bigint,
  labour_rate_kyat bigint,
  labour_total_kyat bigint,
  freight_kyat bigint,
  net_value_kyat bigint,
  received_kyat bigint,
  receivable_kyat bigint,
  stock_before_centi_pyitha bigint,
  stock_after_centi_pyitha bigint,
  idempotent boolean
)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_existing_tx public.finance_transactions%rowtype;
  v_existing public.wholesale_crop_sales%rowtype;
  v_crop public.crop_types%rowtype;
  v_date date;
  v_buyer text := trim(coalesce(p_buyer_name, ''));
  v_location text := trim(coalesce(p_location_id, ''));
  v_method text := upper(trim(coalesce(p_payment_method, '')));
  v_reference text := nullif(trim(coalesce(p_payment_reference, '')), '');
  v_notes text := nullif(trim(coalesce(p_notes, '')), '');
  v_payload jsonb;
  v_transaction_id uuid;
  v_sale_id uuid;
  v_ref text;
  v_gross bigint;
  v_labour bigint;
  v_net bigint;
  v_receivable bigint;
  v_before bigint;
  v_after bigint;
begin
  perform public.require_staff_roles(array['owner']);
  if p_request_id is null then
    raise exception 'Crop-sale request ID is required' using errcode = '22023';
  end if;
  v_payload := jsonb_build_object(
    'buyer_name', v_buyer, 'crop_type_id', trim(coalesce(p_crop_type_id,'')),
    'location_id', v_location, 'weight_centi_pyitha', p_weight_centi_pyitha,
    'actual_bags', p_actual_bags,
    'pricing_divisor_pyitha', p_pricing_divisor_pyitha,
    'rate_kyat', p_rate_kyat, 'labour_rate_kyat', p_labour_rate_kyat,
    'freight_kyat', p_freight_kyat, 'received_kyat', p_received_kyat,
    'payment_method', v_method, 'payment_reference', v_reference,
    'notes', v_notes
  );
  select transactions.* into v_existing_tx
  from public.finance_transactions as transactions
  where transactions.request_id = p_request_id;
  if found then
    if v_existing_tx.document_type <> 'CROP_SALE'
      or v_existing_tx.request_payload <> v_payload then
      raise exception 'Request ID was already used with different crop-sale data'
        using errcode = '23505';
    end if;
    select sales.* into strict v_existing
    from public.wholesale_crop_sales as sales
    where sales.transaction_id = v_existing_tx.id;
    return query select v_existing.id, v_existing.sale_ref,
      v_existing.business_date, v_existing.gross_value_kyat,
      v_existing.labour_rate_kyat, v_existing.labour_total_kyat,
      v_existing.freight_kyat, v_existing.net_value_kyat,
      v_existing.received_kyat, v_existing.receivable_kyat,
      v_existing.stock_before_centi_pyitha,
      v_existing.stock_after_centi_pyitha, true;
    return;
  end if;

  v_date := public.assert_business_day_open();
  if length(v_buyer) not between 1 and 160 or v_location = ''
    or p_weight_centi_pyitha is null or p_weight_centi_pyitha <= 0
    or p_actual_bags is null or p_actual_bags <= 0
    or p_pricing_divisor_pyitha is null or p_pricing_divisor_pyitha <= 0
    or p_rate_kyat is null or p_rate_kyat <= 0
    or p_labour_rate_kyat is null or p_labour_rate_kyat < 0
    or p_freight_kyat is null or p_freight_kyat < 0
    or p_received_kyat is null or p_received_kyat < 0
    or v_method not in ('CASH', 'BANK', 'MOBILE', 'CREDIT')
    or (v_notes is not null and length(v_notes) > 500) then
    raise exception 'Invalid wholesale crop-sale input' using errcode = '22023';
  end if;
  if not exists(select 1 from public.stock_locations
      where location_id = v_location and active) then
    raise exception 'Active stock location not found' using errcode = '23503';
  end if;
  select crops.* into v_crop from public.crop_types as crops
  where crops.crop_type_id = trim(coalesce(p_crop_type_id,''))
    and crops.active for update;
  if not found then
    raise exception 'Active crop type not found' using errcode = '23503';
  end if;
  v_gross := round(p_weight_centi_pyitha::numeric
    / (100 * p_pricing_divisor_pyitha) * p_rate_kyat)::bigint;
  v_labour := p_actual_bags::bigint * p_labour_rate_kyat;
  if p_freight_kyat > v_gross then
    raise exception 'Sale freight exceeds gross value' using errcode = '22023';
  end if;
  v_net := v_gross + v_labour - p_freight_kyat;
  if (v_method = 'CREDIT' and p_received_kyat <> 0)
    or (v_method <> 'CREDIT' and p_received_kyat <> v_net) then
    raise exception 'Immediate payment must equal net value; CREDIT must receive zero'
      using errcode = '22023';
  end if;
  if v_method in ('BANK', 'MOBILE') and v_reference is null then
    raise exception 'Bank or mobile sale reference is required'
      using errcode = '22023';
  end if;
  v_receivable := v_net - p_received_kyat;
  v_before := public.crop_stock_quantity(v_crop.crop_type_id, v_location);
  if p_weight_centi_pyitha > v_before then
    raise exception 'Insufficient owned crop stock' using errcode = '22023';
  end if;
  v_after := v_before - p_weight_centi_pyitha;
  v_ref := public.next_finance_document_ref('SL', v_date);

  insert into public.finance_transactions(
    request_id, request_payload, document_ref, document_type,
    business_date, created_by
  ) values (
    p_request_id, v_payload, v_ref, 'CROP_SALE', v_date, auth.uid()
  ) returning id into v_transaction_id;
  insert into public.wholesale_crop_sales(
    transaction_id, sale_ref, business_date, buyer_name, crop_type_id,
    crop_name_snapshot, location_id, weight_centi_pyitha, actual_bags,
    pricing_divisor_pyitha, rate_kyat, gross_value_kyat,
    labour_rate_kyat, labour_total_kyat, freight_kyat,
    net_value_kyat, received_kyat, receivable_kyat, payment_method,
    payment_reference, notes, stock_before_centi_pyitha,
    stock_after_centi_pyitha, created_by
  ) values (
    v_transaction_id, v_ref, v_date, v_buyer, v_crop.crop_type_id,
    v_crop.name, v_location, p_weight_centi_pyitha, p_actual_bags,
    p_pricing_divisor_pyitha, p_rate_kyat, v_gross,
    p_labour_rate_kyat, v_labour, p_freight_kyat,
    v_net, p_received_kyat, v_receivable, v_method, v_reference, v_notes,
    v_before, v_after, auth.uid()
  ) returning id into v_sale_id;
  if v_receivable > 0 then
    insert into public.buyer_receivable_lots(
      sale_id, sale_ref, business_date, buyer_name,
      opening_kyat, remaining_kyat, created_by
    ) values (
      v_sale_id, v_ref, v_date, v_buyer,
      v_receivable, v_receivable, auth.uid()
    );
  end if;
  insert into public.crop_stock_movements(
    transaction_id, movement_ref, business_date, crop_type_id, location_id,
    crop_name_snapshot, movement_type, quantity_delta_centi_pyitha,
    quantity_before_centi_pyitha, quantity_after_centi_pyitha, created_by
  ) values (
    v_transaction_id, v_ref, v_date, v_crop.crop_type_id, v_location,
    v_crop.name, 'WHOLESALE_OUT', -p_weight_centi_pyitha,
    v_before, v_after, auth.uid()
  );
  if p_received_kyat > 0 then
    insert into public.cash_ledger_entries(
      transaction_id, document_ref, business_date, direction, amount_kyat,
      payment_method, category, label, principal_kyat, interest_kyat,
      created_by
    ) values (
      v_transaction_id, v_ref, v_date, 'IN', p_received_kyat, v_method,
      'CROP_SALE', 'သီးနှံလက်ကားအရောင်း · ' || v_buyer
        || ' · ' || v_crop.name, 0, 0, auth.uid()
    );
  end if;
  insert into public.finance_audit_events(
    transaction_id, document_ref, action, payload, created_by
  ) values (
    v_transaction_id, v_ref, 'WHOLESALE_CROP_SOLD', jsonb_build_object(
      'buyer_name', v_buyer, 'crop_type_id', v_crop.crop_type_id,
      'location_id', v_location, 'weight_centi_pyitha', p_weight_centi_pyitha,
      'actual_bags', p_actual_bags, 'labour_rate_kyat', p_labour_rate_kyat,
      'labour_total_kyat', v_labour, 'net_value_kyat', v_net,
      'received_kyat', p_received_kyat, 'receivable_kyat', v_receivable,
      'stock_after', v_after
    ), auth.uid()
  );
  return query select v_sale_id, v_ref, v_date, v_gross,
    p_labour_rate_kyat, v_labour, p_freight_kyat, v_net,
    p_received_kyat, v_receivable, v_before, v_after, false;
end;
$$;

revoke all on function public.record_wholesale_crop_sale(
  uuid,text,text,text,bigint,integer,integer,bigint,bigint,bigint,bigint,
  text,text,text
) from public, anon, authenticated;

grant execute on function public.record_wholesale_crop_sale(
  uuid,text,text,text,bigint,integer,integer,bigint,bigint,bigint,bigint,
  text,text,text
) to authenticated, service_role;

comment on function public.record_wholesale_crop_sale(
  uuid,text,text,text,bigint,integer,integer,bigint,bigint,bigint,bigint,
  text,text,text
) is 'Atomically sells owned crop stock and adds buyer-paid labour per actual bag.';

notify pgrst, 'reload schema';

commit;
