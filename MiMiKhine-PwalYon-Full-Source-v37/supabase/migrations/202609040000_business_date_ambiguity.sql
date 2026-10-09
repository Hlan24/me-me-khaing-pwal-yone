-- Resolve the RETURNS TABLE business_date variable vs ON CONFLICT column ambiguity.
-- Existing data and the authenticated 72-hour device context rules are unchanged.
begin;
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
  on conflict on constraint weighing_device_business_contexts_pk
  do update set confirmed_at = excluded.confirmed_at;

  return query select
    v_date,
    v_confirmed_at,
    v_confirmed_at + interval '72 hours';
end;
$$;
-- AFTER STATEMENT fires even if its UPDATE matches zero rows. Prevent the
-- compatibility update from invoking itself indefinitely during submit.
create or replace function public.finish_legacy_bag_submission()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if pg_trigger_depth() > 1 then return null; end if;
  update public.bag_weights as bags set status = 'SUBMITTED', batch_ref = batch.batch_ref
    from public.weighing_batches as batch
    where bags.batch_id = batch.id and batch.status = 'SUBMITTED' and bags.status = 'DRAFT';
  return null;
end;
$$;
revoke all on function public.finish_legacy_bag_submission() from public;
notify pgrst, 'reload schema';
commit;
