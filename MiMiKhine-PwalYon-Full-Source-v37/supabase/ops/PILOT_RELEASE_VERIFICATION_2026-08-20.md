# Weighing Pilot V2 release verification — 2026-08-20 through 2026-08-27

## Live Supabase checks

- Applied `202608130001_weighing_batches_master_data.sql` to project `usufheovofmqchjlzlsz`.
- Confirmed the applied migration source matched the repository file byte-for-byte (`SHA-256 64de75fd9640113c1030db6b3c39f7a39b78a94d0cf58f739c9f7d696f378e71`).
- Ran the complete read-only `verify_weighing_master_schema.sql` verifier: **16/16 PASS**.
- Confirmed the server business date was `2026-08-20` (Asia/Yangon policy).
- Confirmed existing durable data remained present after migration:
  - staff members: 1
  - bag weights: 10
  - weighing batches: 4
  - weighing audit events: 4
- Confirmed master seed/backfill counts:
  - farmers: 4
  - crop types: 8
  - products: 5
  - stock locations: 1
- Confirmed Supabase Auth **Allow new users to sign up** is disabled. Staff accounts must be created or invited by an authorized administrator.

## Offline integrity follow-up — 2026-08-27

- Applied `202608260001_offline_queue_integrity.sql` after the final release audit identified two ambiguous offline state transitions.
- Added server-issued, per-user/device/business-date contexts with a 72-hour validity window. Overnight replay retains the original server-confirmed date without trusting the phone clock; an expired/unverified context remains queued for supervisor review.
- An `ADD_BAG` or parent `CREATE_BATCH` that has ever been attempted can no longer be removed offline. It must reconnect, reconcile idempotently by UUID, and then use an audited server VOID if cancellation is required.
- Re-ran the expanded read-only schema verifier: **18/18 PASS**.
- Confirmed the server business date was `2026-08-27` and existing data remained intact: 1 staff member, 10 bag rows, 4 batches, 4 farmer rows, 8 crop rows, 5 product rows, and 1 stock location.

## Backup and restore drill

- Created a fresh logical JSON export before applying V2 and stored it outside the source repository.
- Backup manifest contained 1 staff row and 10 bag-weight rows.
- Ran `restore_drill_weighing_backup.sql` against typed `pg_temp` tables only: **8/8 checks passed**.
- Confirmed the verifier and restore-drill sources run in the private SQL session matched the repository files byte-for-byte.
- The drill verified row counts, UUID identity, staff roles, bag identity, `(batch_id, bag_no)` uniqueness, measurement/status validity, and creator attribution.
- The temporary drill did not insert, update, or delete any live `public` or `auth` rows.

## Source verification

- Static Sites build: PASS.
- JavaScript/HTML integration tests: **39/39 PASS**.
- ESLint for `public/js`, `scripts`, and `tests`: PASS with zero warnings and zero errors.
- `git diff --check`: PASS (line-ending conversion notices are informational on Windows).

## Scope boundary

This verification releases only Supabase Auth/staff metadata, weighing batches and bag details, read-only history, the durable offline weighing queue, and master-data management. Finance, farmer debt, settlement posting, inventory balances, cashbook posting, vouchers, and day-close writes remain deliberately locked until their immutable ledgers and atomic server posting functions are implemented and separately verified.

The Supabase Free plan does not provide the same managed point-in-time recovery guarantees as a production backup plan. The logical export and temporary-table restore drill prove that the current pilot export is internally restorable; they do not replace scheduled off-project backups, retention, alerting, or a full disaster-recovery restore test.
