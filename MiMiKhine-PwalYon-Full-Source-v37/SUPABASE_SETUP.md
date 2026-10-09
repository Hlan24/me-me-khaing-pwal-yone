# Supabase production bootstrap — Mi Mi Khine Pwal Yon

The dashboard currently has two production-backed pilot modules: **bag weighing** and **daily market prices**. Bag weighing uses the canonical `weighing_batches` header, server-generated `batch_ref` and `voucher_ref`, a server-confirmed business date, idempotent workflow RPCs, an IndexedDB durable outbox, Realtime updates, and server-side history pagination. Daily market prices are also mirrored into IndexedDB on the current PC, with an offline retry queue. Finance, debt, product stock, settlement, cash-book, and day-close writes remain locked until those modules have their own server transactions, RLS, audit history, and backup coverage.

The site is already locked to this Supabase project:

- Project host: `usufheovofmqchjlzlsz.supabase.co`
- Browser credential: the project **publishable** key only
- Never place a `service_role`, `sb_secret_...`, database password, or personal access token in the HTML.

## 1. Install the database and staff gate

Open **Supabase Dashboard → SQL Editor**, paste the full contents of:

`supabase/migrations/202608120001_bag_weights_realtime.sql`

Run the complete script. It is idempotent and creates:

- `public.staff_members`, with roles and an `active` approval flag;
- an Auth trigger that creates every new staff row as **inactive**;
- `public.bag_weights`, validation constraints, indexes, and fixed-point `weight_centi_pyitha` storage;
- RLS policies that block anonymous, unapproved, and inactive accounts;
- the `supabase_realtime` publication entry for `bag_weights`.

Next paste and run the full contents of:

`supabase/migrations/202608130001_weighing_batches_master_data.sql`

This canonical migration creates:

- farmer, crop, product, stock-location, business-setting, and staff-role master data;
- `public.weighing_batches` with server-generated batch and voucher references;
- validated header/detail lifecycle rules, totals, and append-only weighing audit events;
- idempotent `create_weighing_batch`, `add_bag_weight`, `submit_weighing_batch`, `void_bag_weight`, and `void_weighing_batch` RPCs;
- server-side history indexes, RLS, and Realtime authorization.

Then paste and run:

`supabase/migrations/202608260001_offline_queue_integrity.sql`

This migration adds:

- `register_weighing_business_date`, which records a server-issued user/device/date context;
- a 72-hour window for replaying an offline batch with its original confirmed business date; and
- the five-argument `create_weighing_batch(..., p_business_date)` overload used by the durable queue.

Then paste and run:

`supabase/migrations/202608310001_daily_market_prices.sql`

This daily-price migration creates:

- `public.market_prices`, with one unique crop/condition/unit row per business day;
- bean `STANDARD` plus chili `WET`, `DRY`, and `MIXED` conditions;
- owner/admin/accountant writes and active-staff read-only access;
- the idempotent `upsert_market_price` RPC used by offline retries; and
- the `supabase_realtime` publication entry for `market_prices`.

Finally paste and run the full contents of:

`supabase/migrations/202609010001_weighing_batches_offline_history.sql`

This final compatibility/hardening migration deliberately **does not recreate the canonical header or replace its workflow RPCs**. It:

- checks that the canonical schema and every required RPC are already present;
- validates `bag_weights.batch_id → weighing_batches.id`;
- adds deterministic status-filtered history pagination;
- removes legacy direct browser writes so all weighing changes pass through audited RPCs;
- confirms active-staff read policies, full Realtime identity, and both publication entries.

For an already-live database that already has the canonical 20260813 and 20260826 objects, deploy the matching dashboard first, close/reload old tabs, and run only the final 20260901 hardening migration. It is atomic and fails without partial changes when a prerequisite or orphan detail is found.

If the app reports `PGRST205`, this SQL has not been run successfully yet (or PostgREST has not refreshed its schema cache). Wait a few seconds after a successful run and log in again.

## 2. Create and activate the first owner account

The browser intentionally provides **login only**. Do not add public sign-up to the site.

1. Open **Authentication → Users → Add user**.
2. Enter the owner's real email and a unique password. Use the dashboard's confirmed-user option for the initial account, or complete the confirmation email before trying to log in.
3. Run the following in SQL Editor, replacing the example email and display name:

```sql
update public.staff_members
set
  display_name = 'မီမီခိုင်',
  role = 'owner',
  active = true,
  activated_at = now(),
  activated_by = user_id
where lower(email) = lower('owner@example.com');
```

Verify that exactly one row was changed:

```sql
select user_id, email, display_name, role, active
from public.staff_members
order by created_at;
```

If the first query updates zero rows, confirm that the Auth user exists and that the migration completed. Never change the trigger to make all new users active automatically.

## 3. Add other staff safely

Create each account in **Authentication → Users**. The trigger gives it the default `weigher` role with `active = false`. An owner/admin then approves the exact email in SQL Editor:

```sql
update public.staff_members
set
  display_name = 'ဝန်ထမ်းအမည်',
  role = 'weigher',
  active = true,
  activated_at = now(),
  activated_by = (
    select user_id
    from public.staff_members
    where role = 'owner' and active = true
    order by created_at
    limit 1
  )
where lower(email) = lower('staff@example.com');
```

Available roles:

- `owner` / `admin`: staff administration and all weighing operations;
- `accountant`: may manage another operator's weighing batch and may add/correct daily market prices;
- `weigher`: may create, add bags to, void, and submit only their own weighing batch;
- `viewer`: read-only bag and market-price access.

Only `owner`, `admin`, and `accountant` can synchronize daily market-price changes. Other active roles can still view the history and reports.

Once the intended staff accounts exist, turn off public email sign-up in **Authentication settings**. Continue creating/inviting staff from the Dashboard. For emailed invitations or confirmations to normal staff addresses, configure a production SMTP provider; the default mail service is only suitable for initial testing.

## 4. Log in on each phone and PC

Open the site and press the **Supabase** status chip. The project URL and publishable key are embedded and cannot be edited by staff. Enter only the staff email and password.

The password is handled by Supabase Auth and is not written to local storage by this dashboard. Logout uses local scope, so it clears this browser session without signing the same account out on every other phone or PC.

The app checks the signed-in user's own `staff_members` row before it loads, listens to, synchronizes, submits, or voids any bag. A valid Auth login is not sufficient: `active` must be `true`. Browser writes go through the RPCs; authenticated users no longer have direct `INSERT`/`UPDATE` privileges on `bag_weights` after the final hardening migration.

## 5. Verify live synchronization

1. Keep the live table open on the PC with an active staff account.
2. On the phone, log in with another active staff account.
3. Select the farmer and crop, enter one bag weight, and press **NEXT BAG**.
4. Confirm that the bag first shows **ဤစက်တွင် သိမ်းပြီး**, then changes to **Online + PC သိမ်းပြီး**.
5. Confirm that the PC displays the server batch number and the bag without a page refresh.
6. In **Table Editor → weighing_batches**, confirm one header with the server number, server business date, and correct totals. In `bag_weights`, confirm that its detail rows use the same batch ID.
7. Disconnect the phone network, record at least two more bags, refresh the page, and confirm that the draft and pending bags restore from IndexedDB.
8. Reconnect. Confirm that the queue becomes Synced and that each bag exists exactly once on the server.
9. Submit the batch and immediately press **Batch အသစ်**. Confirm that a new UUID opens without waiting for settlement and that the submitted batch remains in History.
10. Test History with a date range, every status filter, next/previous page, and bag detail expansion.

IndexedDB is an outbox and local recovery cache, not the official ledger. Supabase headers/details and RPC results remain authoritative. Before a new batch starts, the app stores a server-confirmed business date for the current staff/device. Offline replay keeps that original date; it does not silently move the batch to the reconnect date. A context older than 72 hours is retained for supervisor review instead of being rewritten.

The listener uses the Supabase browser API event named `postgres_changes`:

```js
supabaseClient
  .channel('pwal-yon-live')
  .on(
    'postgres_changes',
    { event: '*', schema: 'public', table: 'weighing_batches' },
    handleWeighingBatchChange,
  )
  .on(
    'postgres_changes',
    { event: '*', schema: 'public', table: 'bag_weights' },
    handleBagWeightChange,
  )
  .on(
    'postgres_changes',
    { event: '*', schema: 'public', table: 'market_prices' },
    handleMarketPriceChange,
  )
  .subscribe();
```

`onPostgresChanges` is not a standalone JavaScript method.

## Login and database messages

- **Email သို့မဟုတ် Password မမှန်ပါ** — wrong credentials or the Auth user does not exist.
- **Email အတည်ပြုရန်လိုသည်** — complete the confirmation message or confirm the user in the Dashboard.
- **အကောင့်ကို Admin က အသုံးပြုခွင့်မပေးရသေးပါ** — Auth worked, but `staff_members.active` is false.
- **Database SQL setup မလုပ်ရသေးပါ (PGRST205)** — run the migration in step 1.
- **အိတ်ချိန် Header / Offline Queue Migration မတင်ရသေးပါ** — run the canonical and hardening migrations in step 1; the browser keeps unsent entries in IndexedDB so Retry can send them afterward.
- **ဤ Batch ကို Server မှပိတ်ပြီးဖြစ်၍ ထပ်ပြင်မရပါ** — the header is already submitted/settled/void; open a new batch instead of editing the closed one.
- **RLS အသုံးပြုခွင့် မရှိပါ** — inspect the staff row's `active` flag and role; do not weaken the RLS policy to `true`.

## Verification and restore drill

After the migration succeeds, run `supabase/ops/verify_weighing_master_schema.sql` in the SQL Editor. It checks schema, constraints, functions, policies, privileges, indexes, publications, and orphan counts without inserting sample business data.

Keep the documented recovery rehearsal in `supabase/ops/restore_drill_weighing_backup.sql`. Run it only in a separate temporary restore/test project—not in the live project—after taking a Supabase backup. Record the date, backup identifier, restore duration, row counts, and verification result in `supabase/ops/PILOT_RELEASE_VERIFICATION_2026-08-20.md`.

## Before enabling finance and stock writes

Do not use the displayed finance, debt, settlement, stock, cash-book, voucher, or day-close values as official records yet. Each module still needs dedicated Supabase tables, immutable transaction/audit entries, role-specific RLS, database transactions, backup/restore testing, and reconciliation reports. The current UI leaves those calculations visible for workflow review but blocks their final write actions so staff cannot mistake local demo state for durable business records.
