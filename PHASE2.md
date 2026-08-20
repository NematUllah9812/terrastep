# Phase 2 — work map

**Started:** 2026-08-19  
**Ship stays:** v0.1.4+5 (pocket FGS). Battery (O12) is parked.  
**Project:** `iaoqwxcyjkpvpqwoszih` → `https://iaoqwxcyjkpvpqwoszih.supabase.co`  
**Exit:** claim on phone A, log in on phone B, see the same territory.

Do these in order. Do not skip ahead to multiplayer (Phase 3).

```
  2.1  Real Supabase + apply SQL          ← done
  2.2  Auth (magic link)                  ← done (no Google/Apple yet)
  2.3  Profile auto-create                ← done (walker_cda70d49). cells_owned still 0 — trigger bug
  2.4  RLS hostile test                   ← next-but-one, with a real JWT
  2.5  claim_cells on the real project    ← done. sync ok claimed
  2.6  Outbox → real RPC                  ← first cut (upload on claim). Not durable SQLite
  2.7  get_cells_in_view                  ← done (hydrate used it)
  2.8  Map draws SERVER hexes             ← done 2026-08-20. Uninstall → login → hex back
  2.9  Rename / recolour own hex          ← NEXT. SQL exists, no UI
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

**2.8 proven (2026-08-20):** dump `sync ok claimed`. Server row
`89209a0aa73ffff` owner `walker_cda70d49`. Uninstall → reinstall → magic
link → hex still there. Same-phone reinstall counts as device B.

**Next:** 2.9 long-press own hex → rename + colour. Then 2.4 RLS. Do not
start Phase 3 realtime until 2.9 is on a phone.

**Never paste the `service_role` / `sb_secret_` key into chat or git.**  
The anon/publishable key is enough for the app. CI rejects raw JWTs, so the
anon key is passed at **build time** (`--dart-define=SUPABASE_ANON_KEY=…`),
not committed.

## What the app does in this first cut

- Knows the project URL.
- Login screen: email magic link, plus **Continue offline** (Walk 7 still works).
- After login, map hydrates from `get_cells_in_view`. Claims upload via `claim_cells`.

## Do not do yet

- Idle GPS / battery (O12) — you asked to wait.
- Realtime / contests on two phones (Phase 3).
- Play Store.
