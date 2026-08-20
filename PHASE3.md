# Phase 3 — work map (handoff)

**Opened:** 2026-08-20  
**Ship:** **v0.1.10+11** (dump first line). FGS 1 Hz, same as Walk 7.  
**Battery (O12):** parked. Do **not** reintroduce idle GPS.  
**Project:** `iaoqwxcyjkpvpqwoszih` → `https://iaoqwxcyjkpvpqwoszih.supabase.co`  
**Owner account:** `khannmat12@gmail.com` / `walker_cda70d49`  
`cda70d49-2d70-4776-bd5e-2d346f8a4170`  
**Home region (res-5):** `85209a0bfffffff` (Abbottabad)

**Phase 2 player loop is done.** Claim → `claim_cells` → uninstall restore → name/colour.

**Exit:** two accounts, one neighbourhood, one contested hex. The right person
wins, both phones agree within ~2 s, neither can cheat by editing the app.

Do these in order. Do not skip to Play Store or battery.

```
  3.0  Draw OTHER players' hexes from get_cells_in_view   ← first code (map only shows mine today)
  3.1  Subscribe to region:<res5>                          ← channel 85209a0bfffffff
  3.2  Broadcast on ownership change                       ← SQL has realtime.send (try/catch)
  3.3  Contest + hysteresis on two phones                  ← SQL proven (395 flip). Need 2nd account
  3.4  Lazy decay + prune                                  ← SQL proven. Verify on real project later
  3.5  Contested-state rendering                           ← hatch/pulse in Flutter
  3.6  Profile & stats UI                                  ← blocked by cells_owned=0 trigger bug
  3.7  Leaderboards                                        ← matviews exist, never populated
  3.8  Push notification                                   ← last. FCM. Not first.
```

## Where we stand (2026-08-20)

**APK:** `releases/terrastep-debug.apk` **v0.1.10+11**. Overlay dump first line.

**Live server territories (REST, 2026-08-20):**

| cell_id | name | colour | influence | claimed |
|---|---|---|---|---|
| `89209a0aa73ffff` | **Home** | `#06b6d4` cyan | 1587.50 | 09:56 UTC |
| `89209a0aa0fffff` | **T1** | `#ef4444` red | 214.90 | 12:22 UTC |

Both owned by `walker_cda70d49`. Profile `cells_owned` is still **0** (trigger
`guard_profile_update` overwrites RPC counters when `role=authenticated`).
Map does not use that counter.

**Auth:** magic link `io.terrastep.app://login-callback/`. One Auth user.
Built-in email cap ~2–4 / hour — don't spam Send.

## Phase 2 leftovers (do not block 3.0–3.3)

| # | Item | Honest status |
|---|---|---|
| 2.4 | RLS hostile test | Policies written. Never run with a real JWT. |
| 2.6 | Airplane / durable outbox | Live upload works. Not SQLite. Not airplane-tested. |
| 2.2 | Google / Apple | Magic link only. |
| — | `cells_owned` = 0 | Fix before 3.6 / 3.7. |

## First code (3.0)

Today `CloudSync.myCells` **filters `is_mine`**. Enemy hexes never draw.
Change hydrate to keep all `get_cells_in_view` rows. Own = editable fill +
name. Other = their colour, no long-press editor.

Then 3.1: subscribe `region:85209a0bfffffff`. Re-subscribe when walking into
a new res-5. Then 3.2: confirm `realtime.send` in `claim_cells` actually
reaches the other phone (it is wrapped in try/catch after the 2.6 rollback
bug — if it no-ops, 3.2 is the fix).

## Constraints for the next agent

- Flutter **3.27.4** / Dart 3.6.2 / JDK 17. `supabase_flutter >=2.8.4 <2.9.0`.
- Anon key **only** via `--dart-define=SUPABASE_ANON_KEY=…`. Never commit JWTs.
- Push via `http.extraheader` only. Never write PAT to `.git/config`.
- `android/` not committed. `scripts/patch_android_manifest.sh` after `flutter create`.
- Bump `app/lib/app_version.dart` **with** `pubspec.yaml` on every APK.
- Dump first line is the version check. APKs go in `releases/`.
- Do not revive v0.1.5 idle GPS.
- User location: Abbottabad, PK. Home hex `89209a0aa73ffff`.

## Do not do yet

- Phase 4/5, Play Store, iOS.
- Battery / idle sampling (O12).
- 3.8 push until 3.2 works on two phones.
