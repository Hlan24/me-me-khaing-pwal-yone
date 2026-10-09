-- Offline weighing integrity patch.
--
-- A mobile device first registers the current server business date while it is
-- online.  A queued batch may later reuse that exact user/device/date context
-- for up to 72 hours.  This preserves an overnight offline batch without
-- trusting the phone clock or silently moving it to the replay date.

begin;

create table if not exists public.weighing_device_business_contexts (
  user_id uuid not null,
  device_id text not null,
  business_date date not null,
  confirmed_at timestamptz not null default clock_timestamp(),
  constraint weighing_device_business_contexts_pk
    primary key (user_id, device_id, business_date),
  constraint weighing_device_business_contexts_device_check check (
    char_length(device_id) between 1 and 160
    and device_id = btrim(device_id)
  )
);

create index if not exists weighing_device_business_contexts_recent_idx
  on public.weighing_device_business_contexts
    (user_id, device_id, confirmed_at desc);

alter table public.weighing_device_business_contexts enable row level security;
alter table public.weighing_device_business_contexts force row level security;

revoke all on table public.weighing_device_business_contexts from public;
revoke all on table public.weighing_device_business_contexts from anon;
revoke all on table public.weighing_device_business_contexts from authenticated;
grant select, insert, update, delete
  on table public.weighing_device_business_contexts to service_role;

create or replace function public.register_weighing_business_date(
  p_device_id text
)
returns table (
  business_date date,
  confirmed_at timestamptz,
  valid_until timestamptz
)
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_device text := coalesce(nullif(btrim(p_device_id), ''), 'WEB-MOBILE');
  v_date date := public.get_business_date();
  v_confirmed_at timestamptz := clock_timestamp();
begin
  perform public.require_staff_roles(
    array['owner', 'admin', 'weigher', 'accountant']
  );

  if char_length(v_device) > 160 or v_device ~ '[[:cntrl:]]' then
    raise exception 'Invalid weighing device id'
      using errcode = '22023';
  end if;

  insert into public.weighing_device_business_contexts (
    user_id,
    device_id,
    business_date,
    confirmed_at
  )
  values (
    auth.uid(),
    v_device,
    v_date,
    v_confirmed_at
  )
  on conflict (user_id, device_id, business_date)
  do update set confirmed_at = excluded.confirmed_at;

  return query select
    v_date,
    v_confirmed_at,
    v_confirmed_at + interval '72 hours';
end;
$$;

-- Five explicit arguments avoid ambiguity with the original four-argument
-- online RPC.  The queued phone request must include the server-confirmed date.
create or replace function public.create_weighing_batch(
  p_customer_id text,
  p_crop_type_id text,
  p_device_id text,
  p_batch_id uuid,
  p_business_date date
)
returns public.weighing_batches
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_farmer public.farmers%rowtype;
  v_crop public.crop_types%rowtype;
  v_batch public.weighing_batches%rowtype;
  v_id uuid := coalesce(p_batch_id, gen_random_uuid());
  v_date date := p_business_date;
  v_device text := coalesce(nullif(btrim(p_device_id), ''), 'WEB-MOBILE');
  v_context_confirmed_at timestamptz;
begin
  perform public.require_staff_roles(
    array['owner', 'admin', 'weigher', 'accountant']
  );

  if v_date is null then
    raise exception 'A server-confirmed business date is required'
      using errcode = '22023';
  end if;

  if char_length(v_device) > 160 or v_device ~ '[[:cntrl:]]' then
    raise exception 'Invalid weighing device id'
      using errcode = '22023';
  end if;

  -- Idempotent reconciliation is allowed even after the context expires.  It
  -- can only return the exact UUID/date/device/user identity already committed.
  if p_batch_id is not null then
    select batch.*
    into v_batch
    from public.weighing_batches as batch
    where batch.id = p_batch_id;

    if found then
      if v_batch.customer_id <> p_customer_id
        or v_batch.crop_type_id <> p_crop_type_id
        or v_batch.business_date <> v_date
        or v_batch.device_id <> v_device
        or v_batch.created_by <> auth.uid() then
        raise exception 'Existing batch identity does not match this request'
          using errcode = '23514';
      end if;
      return v_batch;
    end if;
  end if;

  select context.confirmed_at
  into v_context_confirmed_at
  from public.weighing_device_business_contexts as context
  where context.user_id = auth.uid()
    and context.device_id = v_device
    and context.business_date = v_date
    and context.confirmed_at >= clock_timestamp() - interval '72 hours';

  if not found then
    raise exception 'Server business-date context is missing or expired; queue retained for supervisor review'
      using errcode = '22023';
  end if;

  select farmer.* into v_farmer
  from public.farmers as farmer
  where farmer.customer_id = p_customer_id
    and farmer.active = true;

  if not found then
    raise exception 'Active farmer not found: %', p_customer_id
      using errcode = '23503';
  end if;

  if v_farmer.risk_level = 'BLACKLISTED' then
    raise exception 'This farmer is blocked from new weighing batches'
      using errcode = '42501';
  end if;

  select crop.* into v_crop
  from public.crop_types as crop
  where crop.crop_type_id = p_crop_type_id
    and crop.active = true;

  if not found then
    raise exception 'Active crop type not found: %', p_crop_type_id
      using errcode = '23503';
  end if;

  insert into public.weighing_batches (
    id,
    batch_ref,
    business_date,
    customer_id,
    customer_name,
    crop_type_id,
    crop_name,
    status,
    device_id,
    created_by
  )
  values (
    v_id,
    public.next_document_ref('WB', v_date),
    v_date,
    v_farmer.customer_id,
    v_farmer.full_name,
    v_crop.crop_type_id,
    v_crop.name,
    'DRAFT',
    v_device,
    auth.uid()
  )
  on conflict (id) do nothing
  returning * into v_batch;

  if not found then
    select batch.*
    into v_batch
    from public.weighing_batches as batch
    where batch.id = v_id;

    if not found then
      raise exception 'Batch idempotency conflict could not be resolved'
        using errcode = '40001';
    end if;

    if v_batch.customer_id <> p_customer_id
      or v_batch.crop_type_id <> p_crop_type_id
      or v_batch.business_date <> v_date
      or v_batch.device_id <> v_device
      or v_batch.created_by <> auth.uid() then
      raise exception 'Existing batch identity does not match this request'
        using errcode = '23514';
    end if;

    return v_batch;
  end if;

  insert into public.weighing_audit_events (
    batch_id,
    action,
    to_status,
    details,
    actor_user_id
  )
  values (
    v_batch.id,
    'BATCH_CREATED',
    v_batch.status,
    jsonb_build_object(
      'batch_ref', v_batch.batch_ref,
      'business_date', v_batch.business_date,
      'device_id', v_batch.device_id,
      'business_date_confirmed_at', v_context_confirmed_at
    ),
    auth.uid()
  );

  return v_batch;
end;
$$;

-- Preserve the existing online contract.  It registers today's server context
-- and delegates to the exact-date implementation above.
create or replace function public.create_weighing_batch(
  p_customer_id text,
  p_crop_type_id text,
  p_device_id text default 'WEB-MOBILE',
  p_batch_id uuid default null
)
returns public.weighing_batches
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_date date;
  v_batch public.weighing_batches%rowtype;
begin
  select registered.business_date
  into v_date
  from public.register_weighing_business_date(p_device_id) as registered
  limit 1;

  select created.*
  into v_batch
  from public.create_weighing_batch(
    p_customer_id,
    p_crop_type_id,
    p_device_id,
    p_batch_id,
    v_date
  ) as created;

  return v_batch;
end;
$$;

revoke all on function public.register_weighing_business_date(text)
  from public;
revoke all on function public.create_weighing_batch(
  text, text, text, uuid, date
) from public;
revoke all on function public.create_weighing_batch(
  text, text, text, uuid
) from public;

grant execute on function public.register_weighing_business_date(text)
  to authenticated;
grant execute on function public.create_weighing_batch(
  text, text, text, uuid, date
) to authenticated;
grant execute on function public.create_weighing_batch(
  text, text, text, uuid
) to authenticated;

grant execute on function public.register_weighing_business_date(text)
  to service_role;
grant execute on function public.create_weighing_batch(
  text, text, text, uuid, date
) to service_role;
grant execute on function public.create_weighing_batch(
  text, text, text, uuid
) to service_role;

comment on table public.weighing_device_business_contexts is
  'Server-issued short-lived user/device/business-date contexts for offline weighing replay.';
comment on function public.register_weighing_business_date(text) is
  'Registers the current server business date for this authenticated user and weighing device.';

notify pgrst, 'reload schema';

commit;
