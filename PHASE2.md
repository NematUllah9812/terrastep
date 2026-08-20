# Phase 2 — work map

**Started:** 2026-08-19  
**Ship stays:** v0.1.4+5 (pocket FGS). Battery (O12) is parked.  
**Project:** `iaoqwxcyjkpvpqwoszih` → `https://iaoqwxcyjkpvpqwoszih.supabase.co`  
**Exit:** claim on phone A, log in on phone B, see the same territory.

Do these in order. Do not skip ahead to multiplayer (Phase 3).

```
  2.1  Real Supabase + apply SQL          ← done 2026-08-19 (cfg → 9, redirect added)
  2.2  Auth (magic link)                  ← PROVEN on device 2026-08-19 (email linked, user registered)
  2.3  Profile auto-create                ← already in 01_DATA_MODEL.sql
  2.4  RLS hostile test                   ← after login, with a real JWT
  2.5  claim_cells on the real project    ← RPC live (anon correctly denied)
  2.6  Outbox → real RPC                  ← built on phase-2/cloud-sync (v0.1.7+8). Needs build + walk.
  2.7  get_cells_in_view                  ← RPC live (empty view)
  2.8  Map draws SERVER hexes             ← built on phase-2/cloud-sync (v0.1.7+8). Needs two phones.
  2.9  Rename / recolour own hex          ← SQL already written
```

## 2.6 / 2.8 status (2026-08-19) — branch `phase-2/cloud-sync`

**Why this existed:** v0.1.6+7 only wrote claims to local SharedPreferences
and never called `claim_cells` (`SyncWorker` was untested wiring). That is why
a reinstall wiped the hex even though Supabase showed one user — there was no
duplicate user, the claim simply never reached the server. Reinstall always
shows the login screen (the local session token is erased); same email signs
back into the *same* `auth.users` row.

**Built (v0.1.7+8):**
- `PrefsOutbox` — durable outbox (SharedPreferences JSON); claims survive
  force-quit before delivery.
- `SupabaseClaimApi` — real `claim_cells` RPC with auth/transport error mapping.
- `SyncCoordinator` — 90 s flush + flush on app resume; reports
  pending/accepted/newlyOwned to the debug overlay.
- `TerritoryRepository` + `MapScreen` — debounced viewport sampling →
  `get_cells_in_view` → server-owned hexes coloured by owner; a `cloud` pill
  shows `mine:N view:M`. Restores your hexes after reinstall.
- Backend: `claim_cells` now wraps `realtime.send` in an exception block so a
  realtime failure can never roll back an earned claim.

**To build a cloud-enabled APK:** the anon key must be present at build time:
```
cd app
flutter build apk --debug \
  --dart-define=SUPABASE_ANON_KEY=eyJhbGci...<anon/publishable key>
```
CI does the same from the `SUPABASE_ANON_KEY` Actions secret (without it, CI
still builds an offline-only APK).

**Acceptance:**
1. Walk a hex signed in → overlay `sync pending:1 ok:1 new:1`, pill `mine:1`.
2. Force-quit / reinstall → sign in → the blue hex returns (server draw).
3. Phone B signs in and walks to the same spot → both show the same hex.

Still to do after this: **2.4 RLS hostile test** with a real JWT, then the
two-phone exit above. The SQL re-deploy for the realtime wrap must be applied
to project `iaoqwxcyjkpvpqwoszih`.

## 2.1 status (2026-08-19)

Done on project `iaoqwxcyjkpvpqwoszih`:

- `01_DATA_MODEL.sql` applied (extensions `h3` / `postgis` / `pg_cron` commented — expected).
- `02_CLAIM_ENGINE.sql` applied (`Success. No rows returned` is correct).
- `select cfg('h3_resolution')` → **9**. All 18 `game_config` rows present.
- REST: `get_cells_in_view` returns `[]`. `claim_cells` is **denied to anon** (correct).
- Redirect added: `io.terrastep.app://login-callback/`

**2.2 APK:** `releases/terrastep-debug.apk` is **v0.1.6+7**. Dump first line
must say that. Same FGS tracking as Walk 7. Login screen + Continue offline.
Magic link not yet proven on a phone.

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
