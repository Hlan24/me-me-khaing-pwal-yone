begin;

-- Historical advance အသစ်ဖန်တီးရာတွင် user ရေးသော note ကိုသာ
-- advance_lots.notes ထဲ သိမ်းမည်။
create or replace function public.create_opening_advance_lot()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_farmer_name text;
  v_created_by uuid;
  v_product public.products%rowtype;
  v_type text;
begin
  if new.entry_type not in ('FARMER_DEBT', 'FARMER_ADVANCE') then
    return new;
  end if;

  select farmers.full_name
    into strict v_farmer_name
  from public.farmers as farmers
  where farmers.customer_id = new.customer_id;

  select imports.created_by
    into strict v_created_by
  from public.opening_balance_imports as imports
  where imports.id = new.import_id;

  v_type := case
    when new.entry_type = 'FARMER_DEBT' then 'CASH'
    else new.advance_type
  end;

  if v_type = 'GOODS' then
    select products.*
      into strict v_product
    from public.products as products
    where products.product_id = new.product_id;
  end if;

  insert into public.advance_lots (
    opening_balance_entry_id,
    advance_ref,
    customer_id,
    farmer_name_snapshot,
    advance_type,
    product_id,
    location_id,
    product_name_snapshot,
    unit_name_snapshot,
    whole_units_only,
    unit_price_kyat,
    original_quantity,
    remaining_quantity,
    original_principal_kyat,
    remaining_principal_kyat,
    monthly_interest_rate,
    issued_date,
    status,
    notes,
    created_by
  ) values (
    new.id,
    'AD-OB-' || lpad(new.id::text, 8, '0'),
    new.customer_id,
    v_farmer_name,
    v_type,
    case when v_type = 'GOODS' then new.product_id else null end,
    case when v_type = 'GOODS' then new.location_id else null end,
    case when v_type = 'GOODS' then v_product.name else null end,
    case when v_type = 'GOODS' then v_product.unit_name else 'ကျပ်' end,
    case when v_type = 'GOODS' then v_product.whole_units_only else true end,
    case when v_type = 'GOODS' then new.unit_price_kyat else 1 end,
    case when v_type = 'GOODS' then new.quantity else null end,
    case when v_type = 'GOODS' then new.quantity else null end,
    new.principal_kyat,
    new.principal_kyat,
    new.monthly_interest_rate,
    new.opening_date,
    'OPEN',

    -- System prefix မပေါင်းတော့ဘဲ user note ကိုသာ သိမ်းမည်။
    new.notes,

    v_created_by
  )
  on conflict (opening_balance_entry_id) do nothing;

  return new;
end;
$$;


-- အရင်သိမ်းထားသော Historical Advance notes များမှ
-- "Historical Advance · OB-..." prefix ကို တစ်ကြိမ်တည်း ရှင်းမည်။
-- User ပြင်ပြီးသား clean notes များကို မထိပါ။
do $$
begin
  perform set_config('app.finance_post', 'on', true);

  update public.advance_lots as lots
  set
    notes = entries.notes,
    updated_at = now()
  from public.opening_balance_entries as entries
  where lots.opening_balance_entry_id = entries.id
    and (
      coalesce(lots.notes, '') like 'Historical Advance · OB-%'
      or coalesce(lots.notes, '') like 'Opening Balance · OB-%'
    );
end
$$;


-- Advance အရင်း၊ ရက်စွဲ၊ အတိုး စသည်တို့ကို မပြောင်းဘဲ
-- မှတ်ချက်တစ်ခုတည်းကို Owner က ပြင်နိုင်မည့် RPC။
create or replace function public.update_advance_lot_note(
  p_advance_lot_id uuid,
  p_notes text
)
returns table (
  advance_lot_id uuid,
  document_ref text,
  saved_notes text
)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_lot public.advance_lots%rowtype;
  v_note text := nullif(trim(coalesce(p_notes, '')), '');
begin
  perform public.require_staff_roles(array['owner']::text[]);

  if p_advance_lot_id is null then
    raise exception 'Advance lot ID is required'
      using errcode = '22023';
  end if;

  if v_note is not null and length(v_note) > 500 then
    raise exception 'Advance note cannot exceed 500 characters'
      using errcode = '22023';
  end if;

  select lots.*
    into v_lot
  from public.advance_lots as lots
  where lots.id = p_advance_lot_id
  for update;

  if not found then
    raise exception 'Advance lot was not found'
      using errcode = 'P0002';
  end if;

  -- advance_lots ရဲ့ mutation guard ကို Server RPC အတွင်းမှသာ ဖွင့်သည်။
  perform set_config('app.finance_post', 'on', true);

  update public.advance_lots as lots
  set
    notes = v_note,
    updated_at = now()
  where lots.id = p_advance_lot_id;

  -- မှတ်ချက်အဟောင်းနှင့် အသစ်ကို Audit Log ထဲ ထိန်းသိမ်းမည်။
  insert into public.finance_audit_events (
    transaction_id,
    document_ref,
    action,
    payload,
    created_by
  ) values (
    v_lot.transaction_id,
    v_lot.advance_ref,
    'ADVANCE_NOTE_UPDATED',
    jsonb_build_object(
      'previous_notes', v_lot.notes,
      'new_notes', v_note,
      'source',
        case
          when v_lot.opening_balance_entry_id is not null
            then 'HISTORICAL_OPENING'
          else 'OPERATIONAL'
        end
    ),
    auth.uid()
  );

  return query
  select
    lots.id,
    lots.advance_ref,
    lots.notes
  from public.advance_lots as lots
  where lots.id = p_advance_lot_id;
end;
$$;

revoke all on function public.update_advance_lot_note(uuid, text)
  from public;

grant execute on function public.update_advance_lot_note(uuid, text)
  to authenticated;

grant execute on function public.update_advance_lot_note(uuid, text)
  to service_role;

commit;

notify pgrst, 'reload schema';
