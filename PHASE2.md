# Phase 2 — work map

**Started:** 2026-08-19  
**Ship stays:** v0.1.4+5 (pocket FGS). Battery (O12) is parked.  
**Project:** `iaoqwxcyjkpvpqwoszih` → `https://iaoqwxcyjkpvpqwoszih.supabase.co`  
**Exit:** claim on phone A, log in on phone B, see the same territory.

Do these in order. Do not skip ahead to multiplayer (Phase 3).

```
  2.1  Real Supabase + apply SQL          ← you paste SQL in the dashboard
  2.2  Auth (magic link)                  ← app login screen
  2.3  Profile auto-create                ← already in 01_DATA_MODEL.sql
  2.4  RLS hostile test                   ← after 2.1, with a real JWT
  2.5  claim_cells on the real project    ← SQL already written
  2.6  Outbox → real RPC                  ← client already has SyncWorker
  2.7  get_cells_in_view                  ← SQL already written
  2.8  Map draws SERVER hexes             ← two phones agree
  2.9  Rename / recolour own hex          ← SQL already written
```

## What you do once (2.1)

1. Open [SQL Editor](https://supabase.com/dashboard/project/iaoqwxcyjkpvpqwoszih/sql).
2. Paste **`01_DATA_MODEL.sql`** → Run. If `h3` / `postgis` / `pg_cron` fail,
   that is OK — local tests already shim those. Note the error and keep going
   after commenting those three `create extension` lines, then re-run.
3. Paste **`02_CLAIM_ENGINE.sql`** → Run.
4. New query: `select cfg('h3_resolution');` must return **9**.
5. Authentication → URL configuration → add redirect  
   `io.terrastep.app://login-callback/`
6. Tell me “schema applied” (or paste the error).

**Never paste the `service_role` / `sb_secret_` key into chat or git.**  
The anon/publishable key is enough for the app. CI rejects raw JWTs, so the
anon key is passed at **build time** (`--dart-define=SUPABASE_ANON_KEY=…`),
not committed.

## What the app does in this first cut

- Knows the project URL.
- Login screen: email magic link, plus **Continue offline** (Walk 7 still works).
- After login, same map as Phase 1. Cloud sync is 2.6 / 2.8 — next.

## Do not do yet

- Idle GPS / battery (O12) — you asked to wait.
- Realtime / contests on two phones (Phase 3).
- Play Store.
