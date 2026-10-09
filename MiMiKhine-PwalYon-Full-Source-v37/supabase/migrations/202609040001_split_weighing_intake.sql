-- One immutable physical receipt, followed by an atomic net-weight split.
-- Sale reservation is NOT a purchase, payment, debt repayment or settlement.
begin;

alter table public.weighing_batches
  alter column intake_mode set default 'UNALLOCATED';
alter table public.weighing_batches drop constraint weighing_batches_intake_mode_valid;
alter table public.weighing_batches add constraint weighing_batches_intake_mode_valid
  check (intake_mode in ('UNALLOCATED','DIRECT_SALE','FARMER_CONSIGNMENT','SPLIT'));

-- Preserve the original gross/deductions on a partial custody lot. Its actual
-- bag count is the SOURCE RECEIPT count, never a fractional custody bag count.
alter table public.consignment_lots
  add column sale_reserved_centi_pyitha bigint not null default 0
  check (sale_reserved_centi_pyitha >= 0);
alter table public.consignment_lots drop constraint consignment_lots_net_formula;
alter table public.consignment_lots add constraint consignment_lots_net_formula check (
  original_net_weight_centi_pyitha = gross_weight_centi_pyitha
    - moisture_deduction_centi_pyitha - waste_deduction_centi_pyitha
    - tare_deduction_centi_pyitha - sale_reserved_centi_pyitha
  and original_net_weight_centi_pyitha > 0
);

create table public.intake_allocations (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null unique,
  batch_id uuid not null unique references public.weighing_batches(id) on delete restrict,
  allocation_ref text not null unique,
  business_date date not null,
  accepted_business_date date not null,
  customer_id text not null references public.farmers(customer_id) on delete restrict,
  customer_name text not null,
  crop_type_id text not null references public.crop_types(crop_type_id) on delete restrict,
  crop_name text not null,
  location_id text not null references public.stock_locations(location_id) on delete restrict,
  actual_bags integer not null check (actual_bags > 0),
  gross_centi_pyitha bigint not null check (gross_centi_pyitha > 0),
  moisture_centi_pyitha bigint not null check (moisture_centi_pyitha >= 0),
  waste_centi_pyitha bigint not null check (waste_centi_pyitha >= 0),
  tare_centi_pyitha bigint not null check (tare_centi_pyitha >= 0),
  net_centi_pyitha bigint not null check (net_centi_pyitha > 0),
  sale_reserved_centi_pyitha bigint not null check (sale_reserved_centi_pyitha >= 0),
  consigned_centi_pyitha bigint not null check (consigned_centi_pyitha >= 0),
  consignment_lot_id uuid unique references public.consignment_lots(id) on delete restrict,
  sale_state text not null,
  notes text check (notes is null or char_length(notes) <= 500),
  accepted_by uuid not null references auth.users(id) on delete restrict,
  accepted_at timestamptz not null default now(),
  constraint intake_allocation_net_valid check (
    net_centi_pyitha = gross_centi_pyitha - moisture_centi_pyitha - waste_centi_pyitha - tare_centi_pyitha
    and sale_reserved_centi_pyitha + consigned_centi_pyitha = net_centi_pyitha
  ),
  constraint intake_allocation_lot_valid check (
    (consigned_centi_pyitha > 0 and consignment_lot_id is not null)
    or (consigned_centi_pyitha = 0 and consignment_lot_id is null)
  ),
  constraint intake_allocation_sale_pending check (
    (sale_reserved_centi_pyitha > 0 and sale_state = 'PENDING_SETTLEMENT')
    or (sale_reserved_centi_pyitha = 0 and sale_state = 'NOT_APPLICABLE')
  )
);
create index intake_allocations_date_idx on public.intake_allocations(accepted_at desc,id desc);
create index intake_allocations_farmer_idx on public.intake_allocations(customer_id,business_date desc);

create trigger intake_allocations_no_mutation before update or delete
  on public.intake_allocations for each row
  execute function public.prevent_consignment_movement_mutation();
create trigger intake_allocations_no_truncate before truncate
  on public.intake_allocations for each statement
  execute function public.prevent_consignment_movement_mutation();

create function public.guard_allocated_weighing_receipt()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if (new.status, new.total_bags, new.total_gross_weight_centi_pyitha,
      new.customer_id, new.crop_type_id, new.business_date, new.intake_mode)
     is distinct from
     (old.status, old.total_bags, old.total_gross_weight_centi_pyitha,
      old.customer_id, old.crop_type_id, old.business_date, old.intake_mode)
    and (exists(select 1 from public.intake_allocations where batch_id = old.id)
      or exists(select 1 from public.consignment_lots where batch_id = old.id)) then
    raise exception 'Allocated receipt is immutable; use a linked correction workflow' using errcode = '55000';
  end if;
  return new;
end;
$$;
revoke all on function public.guard_allocated_weighing_receipt() from public;
create trigger weighing_batches_guard_allocation before update on public.weighing_batches
  for each row execute function public.guard_allocated_weighing_receipt();

create function public.allocate_weighing_intake(
  p_batch_id uuid, p_location_id text,
  p_moisture_centi_pyitha bigint, p_waste_centi_pyitha bigint,
  p_tare_centi_pyitha bigint, p_sale_centi_pyitha bigint,
  p_notes text, p_request_id uuid
)
returns public.intake_allocations
language plpgsql volatile security definer set search_path = '' as $$
declare
  b public.weighing_batches%rowtype;
  a public.intake_allocations%rowtype;
  l public.consignment_lots%rowtype;
  n bigint;
  calculated_net numeric;
  c bigint;
  note text := nullif(btrim(coalesce(p_notes,'')), '');
begin
  perform public.require_staff_roles(array['owner','admin','accountant']);
  if p_batch_id is null or p_request_id is null or p_location_id is null
    or p_moisture_centi_pyitha is null or p_waste_centi_pyitha is null
    or p_tare_centi_pyitha is null or p_sale_centi_pyitha is null
    or least(p_moisture_centi_pyitha,p_waste_centi_pyitha,p_tare_centi_pyitha,p_sale_centi_pyitha) < 0
    or char_length(coalesce(note,'')) > 500 then
    raise exception 'Invalid intake allocation input' using errcode = '22023';
  end if;
  select * into b from public.weighing_batches where id = p_batch_id for update;
  if not found then raise exception 'Weighing batch not found' using errcode = 'P0002'; end if;
  -- Keep parent-first lock order used by the legacy bag/acceptance RPCs.
  select * into a from public.intake_allocations
    where request_id = p_request_id;
  if found and a.batch_id <> p_batch_id then
    raise exception 'Request id belongs to another receipt' using errcode = '23514';
  end if;
  select * into a from public.intake_allocations where batch_id = p_batch_id;
  if found then
    if a.batch_id <> p_batch_id or a.location_id <> p_location_id
      or a.moisture_centi_pyitha <> p_moisture_centi_pyitha
      or a.waste_centi_pyitha <> p_waste_centi_pyitha
      or a.tare_centi_pyitha <> p_tare_centi_pyitha
      or a.sale_reserved_centi_pyitha <> p_sale_centi_pyitha
      or a.notes is distinct from note then
      raise exception 'Receipt already allocated or request id reused with different data' using errcode = '23514';
    end if;
    return a;
  end if;
  if b.status <> 'SUBMITTED' then
    raise exception 'Submit all bags before allocating this receipt' using errcode = '55000';
  end if;
  if exists(select 1 from public.consignment_lots where batch_id = b.id) then
    raise exception 'Legacy consignment already accepted; cannot allocate again' using errcode = '55000';
  end if;
  if not exists(select 1 from public.crop_types where crop_type_id = b.crop_type_id and category = 'BEAN' and active) then
    raise exception 'Net weight splitting currently supports beans only; chili requires per-bag allocation' using errcode = '22023';
  end if;
  if not exists(select 1 from public.stock_locations where location_id = p_location_id and active) then
    raise exception 'Active stock location required' using errcode = '23503';
  end if;
  calculated_net := b.total_gross_weight_centi_pyitha::numeric - p_moisture_centi_pyitha::numeric
    - p_waste_centi_pyitha::numeric - p_tare_centi_pyitha::numeric;
  if b.total_bags <= 0 or calculated_net <= 0 or p_sale_centi_pyitha > calculated_net then
    raise exception 'Sale weight must be between zero and final net weight' using errcode = '22023';
  end if;
  n := calculated_net::bigint;
  c := n - p_sale_centi_pyitha;
  -- Label only. Status stays SUBMITTED; no money or ownership transfer occurs.
  update public.weighing_batches set intake_mode = case
    when p_sale_centi_pyitha = 0 then 'FARMER_CONSIGNMENT'
    when c = 0 then 'DIRECT_SALE' else 'SPLIT' end,
    intake_mode_set_at = now(), intake_mode_set_by = auth.uid(), updated_at = now()
    where id = b.id;
  if c > 0 then
    insert into public.consignment_lots(
      lot_ref,acceptance_request_id,batch_id,business_date,customer_id,customer_name,
      crop_type_id,crop_name,location_id,actual_bags,gross_weight_centi_pyitha,
      moisture_deduction_centi_pyitha,waste_deduction_centi_pyitha,tare_deduction_centi_pyitha,
      sale_reserved_centi_pyitha,original_net_weight_centi_pyitha,available_weight_centi_pyitha,notes,accepted_by
    ) values (
      public.next_consignment_lot_ref(public.get_business_date()),p_request_id,b.id,public.get_business_date(),
      b.customer_id,b.customer_name,b.crop_type_id,b.crop_name,p_location_id,b.total_bags,
      b.total_gross_weight_centi_pyitha,p_moisture_centi_pyitha,p_waste_centi_pyitha,p_tare_centi_pyitha,
      p_sale_centi_pyitha,c,c,note,auth.uid()
    ) returning * into l;
    insert into public.consignment_movements(request_id,lot_id,movement_type,business_date,
      quantity_centi_pyitha,balance_after_centi_pyitha,notes,actor_user_id)
      values(p_request_id,l.id,'DEPOSIT',l.business_date,c,c,note,auth.uid());
  end if;
  insert into public.intake_allocations(request_id,batch_id,allocation_ref,business_date,
    accepted_business_date,customer_id,customer_name,crop_type_id,crop_name,location_id,
    actual_bags,gross_centi_pyitha,moisture_centi_pyitha,waste_centi_pyitha,tare_centi_pyitha,
    net_centi_pyitha,sale_reserved_centi_pyitha,consigned_centi_pyitha,consignment_lot_id,
    sale_state,notes,accepted_by)
    values(p_request_id,b.id,b.batch_ref||'-A',b.business_date,public.get_business_date(),
      b.customer_id,b.customer_name,b.crop_type_id,b.crop_name,p_location_id,b.total_bags,
      b.total_gross_weight_centi_pyitha,p_moisture_centi_pyitha,p_waste_centi_pyitha,p_tare_centi_pyitha,
      n,p_sale_centi_pyitha,c,l.id,case when p_sale_centi_pyitha > 0 then 'PENDING_SETTLEMENT'
      else 'NOT_APPLICABLE' end,note,auth.uid()) returning * into a;
  return a;
end;
$$;

-- Old clients may still accept a whole consignment receipt. Use the SAME
-- transaction path so they cannot bypass the split/duplicate protections.
create or replace function public.accept_farmer_consignment(
  p_batch_id uuid,p_location_id text,p_moisture_deduction_centi_pyitha bigint,
  p_waste_deduction_centi_pyitha bigint,p_tare_deduction_centi_pyitha bigint,
  p_notes text,p_request_id uuid
)
returns public.consignment_lots language plpgsql volatile security definer set search_path = '' as $$
declare a public.intake_allocations%rowtype; l public.consignment_lots%rowtype;
begin
  perform public.require_staff_roles(array['owner','admin','accountant']);
  if p_batch_id is null or p_request_id is null or p_location_id is null then
    raise exception 'Batch, location and request id are required' using errcode = '22023';
  end if;
  perform 1 from public.weighing_batches where id = p_batch_id for update;
  select * into l from public.consignment_lots where batch_id = p_batch_id;
  if found and not exists(select 1 from public.intake_allocations where batch_id = p_batch_id) then
    if l.location_id <> p_location_id or l.moisture_deduction_centi_pyitha <> coalesce(p_moisture_deduction_centi_pyitha,0)
      or l.waste_deduction_centi_pyitha <> coalesce(p_waste_deduction_centi_pyitha,0)
      or l.tare_deduction_centi_pyitha <> coalesce(p_tare_deduction_centi_pyitha,0)
      or l.notes is distinct from nullif(btrim(coalesce(p_notes,'')), '') then
      raise exception 'Legacy consignment already accepted with different data' using errcode = '23514';
    end if;
    return l;
  end if;
  a := public.allocate_weighing_intake(p_batch_id,p_location_id,
    coalesce(p_moisture_deduction_centi_pyitha,0),coalesce(p_waste_deduction_centi_pyitha,0),
    coalesce(p_tare_deduction_centi_pyitha,0),0,p_notes,p_request_id);
  select * into l from public.consignment_lots where id = a.consignment_lot_id;
  return l;
end;
$$;

alter table public.intake_allocations enable row level security;
alter table public.intake_allocations force row level security;
revoke all on table public.intake_allocations from anon, authenticated;
grant select on table public.intake_allocations to authenticated;
create policy "Active staff read intake allocations" on public.intake_allocations
  for select to authenticated using (public.current_staff_is_active());
revoke all on function public.allocate_weighing_intake(uuid,text,bigint,bigint,bigint,bigint,text,uuid) from public;
grant execute on function public.allocate_weighing_intake(uuid,text,bigint,bigint,bigint,bigint,text,uuid) to authenticated, service_role;
alter table public.intake_allocations replica identity full;
alter publication supabase_realtime add table public.intake_allocations;

create function public.list_unallocated_weighing_batches(p_limit integer default 50)
returns setof public.weighing_batches language plpgsql stable security invoker set search_path = '' as $$
begin
  perform public.require_staff_roles(array['owner','admin','accountant','weigher','viewer']);
  return query select b.* from public.weighing_batches b
    join public.crop_types crop on crop.crop_type_id = b.crop_type_id and crop.category = 'BEAN'
    where b.status = 'SUBMITTED'
      and not exists(select 1 from public.intake_allocations a where a.batch_id = b.id)
      and not exists(select 1 from public.consignment_lots l where l.batch_id = b.id)
    order by b.submitted_at, b.id limit least(greatest(coalesce(p_limit,50),1),100);
end;
$$;
revoke all on function public.list_unallocated_weighing_batches(integer) from public;
grant execute on function public.list_unallocated_weighing_batches(integer) to authenticated,service_role;

comment on table public.intake_allocations is
  'Immutable net-weight split. Sale reservation remains farmer-owned pending financial settlement; no cash/debt/purchase posting.';
comment on column public.consignment_lots.actual_bags is
  'Original source receipt bag count; not actual bags allocated to this custody portion. Display /30 only as equivalent bags.';
notify pgrst, 'reload schema';
commit;
