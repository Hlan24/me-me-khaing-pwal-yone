-- Mi Mi Khine Pwal Yon: staff-gated mobile bag weighing + PC realtime sync.
-- Safe to run more than once in Supabase Dashboard > SQL Editor.
--
-- IMPORTANT: this migration never activates an account automatically. New and
-- existing Auth users are inserted into staff_members as inactive. After the
-- first owner account is created, activate it explicitly with the SQL shown in
-- SUPABASE_SETUP.md. This prevents an open Auth signup from granting business
-- data access.

create extension if not exists pgcrypto;

create table if not exists public.staff_members (
  user_id uuid primary key references auth.users (id) on delete cascade,
  email text,
  display_name text not null default 'ဝန်ထမ်း',
  role text not null default 'weigher',
  active boolean not null default false,
  activated_at timestamptz,
  activated_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint staff_members_role_valid check (
    role in ('owner', 'admin', 'weigher', 'accountant', 'viewer')
  )
);

create unique index if not exists staff_members_email_unique_idx
  on public.staff_members (lower(email))
  where email is not null;

create or replace function public.set_staff_members_updated_at()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists staff_members_set_updated_at on public.staff_members;
create trigger staff_members_set_updated_at
before update on public.staff_members
for each row execute function public.set_staff_members_updated_at();

create or replace function public.create_inactive_staff_member()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.staff_members (
    user_id,
    email,
    display_name,
    role,
    active
  )
  values (
    new.id,
    new.email,
    coalesce(
      nullif(trim(new.raw_user_meta_data ->> 'full_name'), ''),
      nullif(split_part(coalesce(new.email, ''), '@', 1), ''),
      'ဝန်ထမ်း'
    ),
    'weigher',
    false
  )
  on conflict (user_id) do nothing;

  return new;
end;
$$;

drop trigger if exists auth_user_create_inactive_staff on auth.users;
create trigger auth_user_create_inactive_staff
after insert on auth.users
for each row execute function public.create_inactive_staff_member();

-- Backfill Auth users created before this migration. They remain inactive.
insert into public.staff_members (user_id, email, display_name, role, active)
select
  users.id,
  users.email,
  coalesce(
    nullif(trim(users.raw_user_meta_data ->> 'full_name'), ''),
    nullif(split_part(coalesce(users.email, ''), '@', 1), ''),
    'ဝန်ထမ်း'
  ),
  'weigher',
  false
from auth.users as users
on conflict (user_id) do nothing;

alter table public.staff_members enable row level security;
alter table public.staff_members force row level security;

revoke all on table public.staff_members from anon;
revoke all on table public.staff_members from authenticated;
grant select on table public.staff_members to authenticated;
grant update (display_name, role, active, activated_at, activated_by)
  on table public.staff_members to authenticated;
grant all on table public.staff_members to service_role;

-- SECURITY DEFINER helpers avoid recursive RLS checks on staff_members.
create or replace function public.current_staff_is_active()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.staff_members as staff
    where staff.user_id = auth.uid()
      and staff.active = true
  );
$$;

create or replace function public.current_staff_has_role(required_roles text[])
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.staff_members as staff
    where staff.user_id = auth.uid()
      and staff.active = true
      and staff.role = any(required_roles)
  );
$$;

revoke all on function public.current_staff_is_active() from public;
revoke all on function public.current_staff_has_role(text[]) from public;
grant execute on function public.current_staff_is_active() to authenticated;
grant execute on function public.current_staff_has_role(text[]) to authenticated;

drop policy if exists "Staff can read their own membership" on public.staff_members;
create policy "Staff can read their own membership"
on public.staff_members
for select
to authenticated
using (
  user_id = (select auth.uid())
  or public.current_staff_has_role(array['owner', 'admin'])
);

drop policy if exists "Owners and admins can manage staff" on public.staff_members;
create policy "Owners and admins can manage staff"
on public.staff_members
for update
to authenticated
using (public.current_staff_has_role(array['owner', 'admin']))
with check (public.current_staff_has_role(array['owner', 'admin']));

create table if not exists public.bag_weights (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null,
  batch_ref text,
  business_date date not null default ((timezone('Asia/Yangon', now()))::date),
  bag_no integer not null,
  customer_id text not null,
  customer_name text not null,
  crop_type_id text not null,
  crop_name text not null,
  weight_centi_pyitha integer not null,
  condition text,
  moisture_pct numeric(5, 2),
  quality_grade text,
  status text not null default 'DRAFT',
  device_id text not null default 'WEB-MOBILE',
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint bag_weights_bag_no_positive check (bag_no > 0),
  constraint bag_weights_weight_range check (
    weight_centi_pyitha between 1 and 20000
  ),
  constraint bag_weights_condition_valid check (
    condition is null or condition in ('WET', 'DRY')
  ),
  constraint bag_weights_moisture_valid check (
    moisture_pct is null or moisture_pct between 0 and 100
  ),
  constraint bag_weights_grade_valid check (
    quality_grade is null or quality_grade in ('A', 'B', 'C')
  ),
  constraint bag_weights_status_valid check (
    status in ('DRAFT', 'SUBMITTED', 'VOID')
  ),
  constraint bag_weights_batch_bag_unique unique (batch_id, bag_no)
);

create index if not exists bag_weights_business_date_created_idx
  on public.bag_weights (business_date, created_at desc);

create index if not exists bag_weights_batch_order_idx
  on public.bag_weights (batch_id, bag_no);

create or replace function public.set_bag_weights_updated_at()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists bag_weights_set_updated_at on public.bag_weights;
create trigger bag_weights_set_updated_at
before update on public.bag_weights
for each row execute function public.set_bag_weights_updated_at();

alter table public.bag_weights enable row level security;
alter table public.bag_weights force row level security;

revoke all on table public.bag_weights from anon;
revoke all on table public.bag_weights from authenticated;
grant select, insert on table public.bag_weights to authenticated;
grant update (status, batch_ref) on table public.bag_weights to authenticated;
grant all on table public.bag_weights to service_role;

-- Remove policies from earlier pilot versions before creating the staff gates.
drop policy if exists "Authenticated staff can read bag weights" on public.bag_weights;
drop policy if exists "Authenticated staff can insert own bag weights" on public.bag_weights;
drop policy if exists "Creators can update their bag weights" on public.bag_weights;
drop policy if exists "Active staff can read bag weights" on public.bag_weights;
drop policy if exists "Active weighing staff can insert own bag weights" on public.bag_weights;
drop policy if exists "Active staff can update allowed bag status" on public.bag_weights;

create policy "Active staff can read bag weights"
on public.bag_weights
for select
to authenticated
using (public.current_staff_is_active());

create policy "Active weighing staff can insert own bag weights"
on public.bag_weights
for insert
to authenticated
with check (
  public.current_staff_has_role(array['owner', 'admin', 'weigher', 'accountant'])
  and created_by = (select auth.uid())
);

create policy "Active staff can update allowed bag status"
on public.bag_weights
for update
to authenticated
using (
  public.current_staff_is_active()
  and (
    created_by = (select auth.uid())
    or public.current_staff_has_role(array['owner', 'admin', 'accountant'])
  )
)
with check (
  public.current_staff_is_active()
  and (
    created_by = (select auth.uid())
    or public.current_staff_has_role(array['owner', 'admin', 'accountant'])
  )
);

alter table public.bag_weights replica identity full;

do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'bag_weights'
  ) then
    alter publication supabase_realtime add table public.bag_weights;
  end if;
end
$$;
