-- ============================================================
-- Product Category Master
-- Existing products and prices are NOT changed or deleted.
-- ============================================================

create table if not exists public.product_categories (
  category_id uuid primary key default gen_random_uuid(),

  name text not null,
  active boolean not null default true,
  sort_order integer not null default 100,
  notes text,

  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_by uuid,
  updated_at timestamptz not null default now(),

  constraint product_categories_name_not_blank
    check (length(trim(name)) between 1 and 100),

  constraint product_categories_sort_order_valid
    check (sort_order >= 0),

  constraint product_categories_notes_length
    check (notes is null or length(notes) <= 500)
);

-- Category name တူတာ မဖြစ်စေရန်
create unique index if not exists product_categories_name_unique_idx
  on public.product_categories (lower(trim(name)));

-- Update လုပ်လျှင် updated_at / updated_by ကို server က မှတ်ပေးမည်
drop trigger if exists product_categories_set_updated_at
  on public.product_categories;

create trigger product_categories_set_updated_at
before update on public.product_categories
for each row
execute function public.set_master_updated_at_and_actor();

-- အစပိုင်း အသုံးများမည့် Category များ
insert into public.product_categories (
  name,
  sort_order,
  active
)
values
  ('မြေဆီ', 10, true),
  ('အာမို / ဓာတ်မြေဩဇာ', 20, true),
  ('မျိုးစေ့', 30, true),
  ('စိုက်ပျိုးဆေး', 40, true),
  ('ပိုးသတ်ဆေး', 50, true),
  ('ကိရိယာ', 60, true),
  ('အိတ် / ထုပ်ပိုးပစ္စည်း', 70, true),
  ('ဆန် / စားသောက်ကုန်', 80, true),
  ('အခြား', 999, true)
on conflict do nothing;

-- လက်ရှိ ကုန်ပစ္စည်းတွင် ရှိပြီးသား Category များကို
-- Category Master ထဲသို့ ကူးထည့်မည်
insert into public.product_categories (
  name,
  sort_order,
  active
)
select distinct
  trim(p.category) as name,
  100 as sort_order,
  true as active
from public.products p
where p.category is not null
  and trim(p.category) <> ''
on conflict do nothing;

-- Security / RLS
alter table public.product_categories enable row level security;
alter table public.product_categories force row level security;

revoke all on table public.product_categories from anon;
grant select, insert, update on table public.product_categories to authenticated;
grant all on table public.product_categories to service_role;

drop policy if exists "Active staff can read product categories"
  on public.product_categories;

create policy "Active staff can read product categories"
on public.product_categories
for select
to authenticated
using (
  public.current_staff_has_role(
    array['owner', 'admin', 'accountant']
  )
);

drop policy if exists "Owners can create product categories"
  on public.product_categories;

create policy "Owners can create product categories"
on public.product_categories
for insert
to authenticated
with check (
  public.current_staff_has_role(
    array['owner', 'admin']
  )
);

drop policy if exists "Owners can update product categories"
  on public.product_categories;

create policy "Owners can update product categories"
on public.product_categories
for update
to authenticated
using (
  public.current_staff_has_role(
    array['owner', 'admin']
  )
)
with check (
  public.current_staff_has_role(
    array['owner', 'admin']
  )
);
