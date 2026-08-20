# Phase 2 — work map

**Started:** 2026-08-19  
**Ship stays:** v0.1.4+5 (pocket FGS). Battery (O12) is parked.  
**Project:** `iaoqwxcyjkpvpqwoszih` → `https://iaoqwxcyjkpvpqwoszih.supabase.co`  
**Exit:** claim on phone A, log in on phone B, see the same territory.

Do these in order. Do not skip ahead to multiplayer (Phase 3).

```
  2.1  Real Supabase + apply SQL          ← done 2026-08-19 (cfg → 9, redirect added)
  2.2  Auth (magic link)                  ← proven 2026-08-19. Sign out in v0.1.7+8.
  2.3  Profile auto-create                ← already in 01_DATA_MODEL.sql
  2.4  RLS hostile test                   ← after login, with a real JWT
  2.5  claim_cells on the real project    ← RPC live (anon correctly denied)
  2.6  Outbox → real RPC                  ← v0.1.7+8 uploads on claim (best-effort)
  2.7  get_cells_in_view                  ← RPC live (empty view)
  2.8  Map draws SERVER hexes             ← two phones agree
  2.9  Rename / recolour own hex          ← SQL already written
```

## 2.1 status (2026-08-19)

Done on project `iaoqwxcyjkpvpqwoszih`:

- `01_DATA_MODEL.sql` applied (extensions `h3` / `postgis` / `pg_cron` commented — expected).
- `02_CLAIM_ENGINE.sql` applied (`Success. No rows returned` is correct).
- `select cfg('h3_resolution')` → **9**. All 18 `game_config` rows present.
- REST: `get_cells_in_view` returns `[]`. `claim_cells` is **denied to anon** (correct).
- Redirect added: `io.terrastep.app://login-callback/`

**2.2 proven (2026-08-19):** magic link, session persist, sign-out.
One Auth user (`walker_cda70d49`). Sign-out → sign-in keeping the hex is
**local only** — `territories` was still empty.

**2.6 blocker:** `claim_cells` likely aborted the whole transaction
(`st_point` / `realtime.send`). Patched in `02_CLAIM_ENGINE.sql`:
centroid is null, realtime is try/catch, `max_accuracy_m` 35→80.

**You (SQL Editor):** paste **updated** `02_CLAIM_ENGINE.sql` → Run
(`create or replace` is safe). Then:

```sql
select cfg('max_accuracy_m');          -- expect 80
select count(*) from public.territories;
```

When the email cap lifts: log in on v0.1.7+8, walk a hex, overlay `sync`
must show `ok claimed`. Then uninstall is the 2.8 test.

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
