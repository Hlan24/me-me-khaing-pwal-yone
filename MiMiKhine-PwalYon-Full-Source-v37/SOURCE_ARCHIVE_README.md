# Mi Mi Khine Pwal Yon — Full Source Archive

This archive contains the application source used for Live Site version 37,
plus this export guide and a placeholder-only `.env.example`.

## Main components

- `public/pwal-yon-dashboard.html` — complete responsive dashboard UI and browser application logic.
- `app/` — vinext/Next application wrapper and ChatGPT/Sites authentication helpers.
- `supabase/migrations/` — database schema, RLS, RPC, Realtime, finance, stock, weighing, consignment, settlement, and day-close migrations.
- `supabase/ops/` — read-only production verification and restore-drill scripts.
- `worker/`, `build/`, and `scripts/` — hosting/build source and static packaging scripts.
- `tests/` — database, workflow, UI, voucher, and rendered-output regression tests.
- `.openai/hosting.json` and root configuration files — project hosting/build configuration.
- `.env.example` — placeholder-only environment template; it contains no private credentials.

## Install and verify

Use Node.js 22.13 or newer.

```bash
pnpm install
pnpm test
```

The production database is Supabase. Read `SUPABASE_SETUP.md` and apply the files in `supabase/migrations/` in filename order to a controlled project. Never expose a `service_role` key, database password, personal access token, or other private credential in browser code.

## Deliberately excluded

The archive does not include Git history, dependency folders, local caches, generated build output, temporary work files, private `.env` files, or `secure-backups/`. Install dependencies from the supplied lockfiles and generate build output with the supplied scripts.
