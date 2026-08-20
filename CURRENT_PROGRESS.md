# Terrastep — Current Progress

**Last updated:** 2026-08-20
**Repo:** `NematUllah9812/terrastep` (private)
**Latest:** **2.8 done.** Uninstall → login → home hex still blue. Ship **v0.1.7+8**. Battery parked (O12).
**Field data:** [`FIELD_REPORT_2026-08-19.md`](FIELD_REPORT_2026-08-19.md)
**Phase 2 map:** [`PHASE2.md`](PHASE2.md)
**Next:** install **v0.1.8+9**. Long-press your hex, name it, pick a colour.

| | |
|---|---|
| **Walk 7** | 21:47 elapsed, raw gps **1289**, accepted **1284**, pedo **765**, **territory 1**, fgs **on**, last fix **now**. |
| **vs Walk 6** | Same prayer/pocket trip. 12 GPS / 0 steps → 1289 / 765. FGS works. |
| **Battery** | 24% → 21% in ~21 min ≈ **8.5 %/hr**. Over the 4 % target. **Deferred — come back later.** |
| **1.7** | ✅. **1.8 tracking** ✅. **1.8 battery** ⏸ deferred (O12). |

> **Resuming on a new machine?** Read §0, then `ISSUES_LOG.md` → *Recurring
> Patterns*. The sandbox is ephemeral — reinstall Postgres and re-set git
> identity before anything runs.

---

## Contents

1. [0b — Get the APK](#0b-get-the-apk)
2. [0 — Pick up where we left off](#0-pick-up-where-we-left-off)
3. [1 — Honest summary](#1-honest-summary)
4. [2 — Threshold-by-threshold status](#2-threshold-by-threshold-status)
5. [3 — Scorecard](#3-scorecard)
6. [4 — What actually got verified](#4-what-actually-got-verified)
7. [5 — Known gaps & risks](#5-known-gaps--risks)
8. [6 — Next actions](#6-next-actions)
9. [7 — Changelog](#7-changelog)

---

## 0b. Get the APK

**Download from the repo (easiest on a phone):**

[`releases/terrastep-debug.apk`](releases/terrastep-debug.apk)

Tap → download → open → allow *install from unknown sources*. Grant
**Location (precise)** and **Physical activity** when the app asks.

Also available from Actions (rebuilds on every relevant push): repo →
**Actions** → newest *Build Android APK* → Artifacts → `terrastep-debug-apk`.

| | |
|---|---|
| File | `releases/terrastep-debug.apk` |
| Version | **v0.1.9+10** (dump first line) |
| Size | 45 MB |
| ABI | `arm64-v8a` |
| Signed | Debug (not Play Store) |
| Built | 2026-08-19, Flutter 3.27.4, locally |
| Offline | **Continue offline** still walks. Login is optional. |

### What it does

- OSM map + live blue dot
- Real H3 res-9 hexes (2-ring around you; claimed hexes stay drawn)
- Walk-to-claim: **120 steps AND 80 m AND 90 s AND 5 GPS fixes**
- Territory persists across force-quit (SharedPreferences)
- Debug overlay: steps, distance, dwell, GPS accuracy, rejected fixes,
  **live battery %**, session elapsed time
- Tap the copy icon on the overlay to dump those numbers

### What was added so the first walk can actually succeed

| Addition | Why |
|---|---|
| Runtime `ACTIVITY_RECOGNITION` | Without it the pedometer is silent on Android 10+ and no hex can fill (#25) |
| Stride-estimated steps after 8 s with no sensor | Overlay says `EST. from dist`. Devices without a pedometer can still claim. |
| Live battery % + elapsed | The numbers threshold 0.3 needs, on screen |
| Hex ids padded to 15 chars | `BigInt.toRadixString` drops leading zeros; h3-js does not (O9) |
| MapController guarded until ready | First GPS fix used to crash if the map was not attached |

### Walk 7 result (pocket / prayer, v0.1.4+5)

**Tracking survived. A hex claimed.** Same trip as Walk 6, opposite outcome.

| | 00:32 (20:43) | 21:47 (21:05) |
|---|---|---|
| fgs | on | on |
| last fix | now | now |
| raw / accepted | 28 / 28 | **1289 / 1284** |
| pedometer | 0 | **765** |
| gps acc | 6.7 m | 3.7 m |
| claim | 0 | **territory 1** (home `89209a0aa73ffff`) |
| m/step | 0.00 | **0.66** |
| battery | 24% | 21% |

~1 Hz the whole pocket session. 5 teleports rejected (noise). HUD after the claim is a fresh visit (129 steps / 84.7 m) — expected.

**Battery ~8.5 %/hr** (some screen-on for screenshots). Target was &lt;4, abort was &gt;6. **Owner decision 2026-08-18: skip the battery gate for now, come back later (O12).** Do not treat 1.8 as fully closed.

---

## 0. Pick Up Where We Left Off

Everything needed to continue is committed. No local state matters.

### Repo map

| File | Purpose |
|---|---|
| `README.md` | Orientation + quick start |
| `00_MASTER_PLAN.md` | Architecture, 5 core decisions, roadmap |
| `01_DATA_MODEL.sql` | Schema, RLS, decay, matviews, cron |
| `02_CLAIM_ENGINE.sql` | `claim_cells` RPC — the referee |
| `03_CLIENT_ARCHITECTURE.md` | Flutter structure, battery, sync |
| `04_ANTI_CHEAT.md` | Threat model, 4 defence layers |
| `05_COST_MODEL.md` | Free-tier ceilings, upgrade triggers |
| `06_MILESTONE_CHECKLIST.md` | 45 thresholds + acceptance tests (the work queue) |
| **`CURRENT_PROGRESS.md`** | **This file — status against the queue** |
| **`ISSUES_LOG.md`** | **Every blocker, how it was fixed, open items** |
| `SECURITY.md` | Credential handling rules |
| **`releases/terrastep-debug.apk`** | **Installable testing APK** |
| **`FIELD_REPORT_2026-08-18.md`** | **First real walk — raw dump + diagnosis** |
| `packages/terrastep_core/` | Pure-Dart game logic. 43 tests, no Flutter dep. |
| `app/` | Flutter Android app (sensors, map, UI) |
| `scripts/` | `patch_android_manifest.sh` — permissions after `flutter create` |
| `prototype/index.html` | Playable claim-loop prototype |
| `tests/` | 48-assertion suite + Supabase shim |

### Restore a working environment

```bash
git clone https://github.com/NematUllah9812/terrastep.git && cd terrastep

# 1. Toolchain (NOT persisted — ISSUES_LOG #3)
sudo apt-get install -y postgresql        # or: brew install postgresql@17

# 2. Git identity (resets — ISSUES_LOG #4)
git config user.email "nematullah9812@users.noreply.github.com"
git config user.name  "NematUllah9812"

# 3. Verify everything still works
./tests/run_tests.sh                      # expect: ALL 48 TESTS PASSED

# 4. Core logic (Dart only; Flutter not required)
cd packages/terrastep_core && dart pub get && dart test   # expect: 43 passed
```

If both suites are green, backend and client core are intact.
The prototype needs nothing — open `prototype/index.html` in any browser.
The APK needs nothing — download `releases/terrastep-debug.apk`.

---

## 1. Honest Summary

**Threshold 1.7 is done.** A real phone claimed a hex, and the hex
survived force-quit. Phase 1’s remaining boss fight is **1.8**
(pocket / screen-off), which is also Phase 0’s GO/NO-GO (**0.3**).

The backend is real code, not a sketch: 48 behavioural assertions pass
(claiming, contesting, hysteresis, decay, idempotency, teleport rejection,
shadow-banning).

The client is past "not started". Sensors, map, H3, local persist and the
debug overlay compile into an installable APK that lives in this repo.
The only test that matters has not happened: a human walking a block with
the screen on, then (later) a 30-minute pocket test with a foreground
service.

The referee is done. The board exists. A real phone claimed a hex in a
pocket (Walk 7). Battery &lt;4 %/hr is **deferred** (O12), not failed-and-forgotten.

| | Status |
|---|---|
| Design & architecture | ✅ Complete |
| Database schema | ✅ Written + verified deploys |
| Claim / contest / decay engine | ✅ Written + 48 tests passing |
| Server-side anti-cheat rules | 🟡 Mostly written, partially tested |
| Supabase deployment | 🟡 Schema + RPCs live. Magic link + cloud hex restore proven. `cells_owned` still 0. |
| Flutter app | 🟡 Claims + persist + FGS on Android. No iOS. |
| Real GPS / steps / battery | 🟡 Pocket claim proven (Walk 7). Battery %/hr deferred (O12). |
| Store submission | ❌ Not started |

---

## 2. Threshold-by-Threshold Status

Legend: ✅ done & verified · 🟡 implemented, waiting on a device · ⬜ not started

### PHASE 0 — De-risk Spike *(0 / 3 done, 2 waiting on a walk)*

| # | Threshold | Status | Note |
|---|---|---|---|
| 0.1 | Flutter + MapLibre basemap + blue dot | 🟡 | **On device** (flutter_map + OSM, not MapLibre — #21). |
| 0.2 | h3_flutter returns res-9 cell; hexes drawn | 🟡 | **On device.** Cell `89209a0aa73ffff`. Still unverified vs h3-js (O9). |
| 0.3 | Background location + pedometer, 2 h, screen off | 🟡 | **Tracking ✅ Walk 7.** Battery ~8.5 %/hr. Gate **deferred** (O12). |

### PHASE 1 — Local Prototype *(2 / 8 done)*

| # | Threshold | Status | Note |
|---|---|---|---|
| 1.1 | Map basemap | 🟡 | OSM + follow on a real Android |
| 1.2 | Location permissions | 🟡 | Android grant flow works. iOS / “Always” not done. |
| 1.3 | H3 integration | 🟡 | Live cell ids. Not compared to h3-js (O9). |
| 1.4 | Hex grid overlay | 🟡 | 2-ring + claimed blue fill on device |
| 1.5 | Step source | 🟡 | Pedometer matches HUD. Health Connect later. |
| 1.6 | `SessionAccumulator` + unit tests | ✅ | 27/27. Armchair-claim exploit fixed (#17). |
| 1.7 | Local claim + persist | ✅ | **Claim + force-quit × N, hex stayed blue.** SharedPreferences, not SQLite. |
| 1.8 | Background survival, <4%/hr | 🟡 | **Pocket tracking ✅.** Battery &lt;4 %/hr **deferred** (O12). |

### PHASE 2 — Backend & Persistence *(6 / 9 done, 3 partial)*

| # | Threshold | Status | Note |
|---|---|---|---|
| 2.1 | Supabase project + schema applied | ✅ | **On `iaoqwxcyjkpvpqwoszih`.** `cfg` → 9. Redirect added. Extensions commented (ok). |
| 2.2 | Auth (magic link + OAuth) | 🟡 | Magic link + sign-out + restart persist. No Google/Apple. |
| 2.3 | Profile auto-creation trigger | ✅ | `walker_cda70d49` exists. Counters stuck at 0 (trigger). |
| 2.4 | RLS hostile test | 🟡 | Policies written. Hostile test needs a real JWT. |
| 2.5 | `claim_cells` RPC | ✅ | Live: dump `sync ok claimed`. Home hex on server. |
| 2.6 | Outbox + sync worker | 🟡 | Upload on claim works. Not durable SQLite / airplane test. |
| 2.7 | `get_cells_in_view` | ✅ | Hydrate used it on reinstall. |
| 2.8 | Server-driven map render | ✅ | **Uninstall → login → `89209a0aa73ffff` still blue.** |
| 2.9 | Naming + colour | 🟡 | **v0.1.8+9** long-press UI. Not yet walked on a phone. |

### PHASE 3 — Multiplayer *(2 / 8)*

| # | Threshold | Status | Note |
|---|---|---|---|
| 3.1 | Region-scoped realtime subscribe | ⬜ | Channel strategy decided (res-5 parent). |
| 3.2 | Broadcast on ownership change | 🟡 | `realtime.send()` fires in tests against a **shim** |
| 3.3 | Contest + hysteresis | ✅ | C6–C10, D1–D3 — exact 395 flip point |
| 3.4 | Lazy decay + prune | ✅ | E1–E6 — half-life exact, prune → neutral |
| 3.5 | Contested-state rendering | 🟡 | Works in the JS prototype; not in Flutter |
| 3.6 | Profile & stats | 🟡 | Counters tested (C10); no UI |
| 3.7 | Leaderboards | 🟡 | Matviews + cron written; never populated |
| 3.8 | Push notification | ⬜ | |

### PHASE 4 — Anti-Cheat *(3 / 8)*

| # | Threshold | Status | Note |
|---|---|---|---|
| 4.1 | Mock-location detection | ⬜ | Client side |
| 4.2 | Accuracy + jitter filter | 🟡 | Server gate tested (A7). Client uses displacement-anchor, not Kalman. |
| 4.3 | Server speed envelope | ✅ | A3 |
| 4.4 | Path continuity / teleport | ✅ | G1–G4 |
| 4.5 | Ratio sanity | ✅ | A2a, A2b, A4 |
| 4.6 | Rate limiting | 🟡 | Written, **not tested**. Needs a 60-cell fixture. |
| 4.7 | Behavioural scoring | 🟡 | `score_suspicion()` written, not deployed |
| 4.8 | Rollback tooling | 🟡 | `admin_rollback_user()` written, untested |

### PHASE 5 — Polish & Launch *(0 / 9)*

All ⬜. Not started.

---

## 3. Scorecard

| Phase | ✅ Done | 🟡 Partial | ⬜ Not started | Total |
|---|---|---|---|---|
| 0 — Spike | 0 | 2 | 1 | 3 |
| 1 — Prototype | 2 | 5 | 1 | 8 |
| 2 — Backend | 6 | 3 | 0 | 9 |
| 3 — Multiplayer | 2 | 4 | 2 | 8 |
| 4 — Anti-cheat | 3 | 4 | 1 | 8 |
| 5 — Launch | 0 | 0 | 9 | 9 |
| **Total** | **13** | **18** | **14** | **45** |

**Fully complete: 13 / 45 (29%).**
Partials at half credit: 22 / 45 (**~49%**).

1.7 is the first on-device acceptance test that fully passed.

**Hours burned vs. estimate:** roughly 35–40 h of the ~215 h estimate —
front-loaded on design. Remaining work is more implementation-dense than
the raw percentage suggests.

---

## 4. What Actually Got Verified

"Written" and "working" are different things. This is the working list.

```
Postgres 17 · 01_DATA_MODEL.sql + 02_CLAIM_ENGINE.sql applied cleanly
48 / 48 SQL assertions passing
43 / 43 Dart core tests passing
flutter analyze: No issues found
flutter build apk --debug --target-platform android-arm64: 45 MB APK
APK contains lib/arm64-v8a/libh3.so + libflutter.so
```

| Group | Assertions | Covers |
|---|---|---|
| A — Validation rules | 13 | All 9 rejection rules + valid-walk acceptance |
| B — Effort scoring | 2 | Formula exactness (529.50), cap at 600 |
| C — Ownership lifecycle | 10 | claim → reinforce → contest → capture |
| D — Hysteresis | 3 | Exact 395 flip boundary, both sides |
| E — Decay | 6 | Half-life precision, neutral reversion, prune |
| F — Idempotency | 3 | Retry returns cache, no double-count |
| G — Path continuity | 4 | Teleport rejected, adjacent walk accepted |
| H — Enforcement | 3 | Shadow ban returns success but writes nothing |
| I — Customisation | 4 | Owner can rename, non-owner cannot |

Reproduce SQL: `./tests/run_tests.sh`
Reproduce Dart: `cd packages/terrastep_core && dart pub get && dart test`

**Not verified yet:** rate limiting (4.6), behavioural scoring (4.7),
rollback (4.8), real Supabase Realtime, RLS under a genuine JWT, any
latency target, and **pocket battery (1.8 / Walk 7)**.

---

## 5. Known Gaps & Risks

**Test debt — clear before Phase 3**

1. Rate-limit path (4.6) — 60-cell fixture, 51st refused.
2. `score_suspicion()` (4.7) — deploy + synthetic bot profile.
3. `admin_rollback_user()` (4.8) — reassignment fixture.
4. RLS hostile test (2.4) — needs a real Supabase JWT.

**Must re-check on real Supabase**

- `h3` extension available? (`select * from pg_available_extensions where name like 'h3%'`)
- `realtime.send()` inside a `SECURITY DEFINER` function.

**Project-level risks — all still ahead**

1. Background battery drain (O12) — Walk 7 measured ~8.5 %/hr. **Deferred.**
   Come back before any public release. Adaptive idle sampling is the fix.
2. Google Play background-location review — most first submissions rejected.
3. Cold-start emptiness — launch to one neighbourhood, not the world.

---

## 6. Next Actions

**Do these in this order. Nothing else first.**

1. **You:** install **v0.1.8+9**. Dump first line must match. Long-press your blue hex, name it, pick a colour. Reinstall should keep the name.
2. **Then 2.4** RLS hostile test.
3. Fix `profiles.cells_owned` still 0.
4. **O12 battery later.** Do not reintroduce idle sampling until asked.
5. Do **not** start Phase 3 until 2.9 is proven on a phone.

Pocket hex-fill (Phase 1 exit *loop*) is proven. The &lt;4 %/hr number is
parked, not forgotten.

**Already in place**

- ✅ CI — `.github/workflows/tests.yml` (48 SQL assertions + secret scan)
- ✅ APK CI — `.github/workflows/build-apk.yml` (Flutter 3.27.4)
- ✅ `SECURITY.md` — written before Phase 2 introduces real keys
- ✅ Testing APK — `releases/terrastep-debug.apk`

---

## 7. Changelog

| Date | Change | Issues |
|---|---|---|
| 2026-08-20 | **v0.1.9+10.** Fix 2.9 crash (`dependents.isEmpty`) and hex fill ignoring saved colour. | 2.9 |
| 2026-08-20 | **v0.1.8+9.** Long-press own hex → rename + colour (`update_territory`). | 2.9 |
| 2026-08-20 | **2.8 done.** Uninstall → login → home hex `89209a0aa73ffff` still blue. `sync ok claimed`. | 2.8 |
| 2026-08-20 | **v0.1.7+8.** Sign out + `claim_cells` upload + hydrate. SQL harden (no st_point / realtime abort). | 2.2, 2.6 |
| 2026-08-19 | **v0.1.6+7.** Login screen + magic-link deep link. Anon key via dart-define (not committed). FGS unchanged. | 2.2 |
| 2026-08-19 | **2.1 done.** Schema + RPCs on `iaoqwxcyjkpvpqwoszih`. `cfg` → 9. Redirect added. | 2.1 |
| 2026-08-19 | **Phase 2 opened.** Project `iaoqwxcyjkpvpqwoszih`. Login screen + `PHASE2.md`. | 2.1 |
| 2026-08-19 | **v0.1.5 rolled back.** Ship stays v0.1.4+5. | O12 |
| 2026-08-18 | **Walk 7.** Pocket/prayer on v0.1.4+5. 1289 GPS, 765 steps, hex claimed, fgs on. Battery ~8.5 %/hr. **Battery gate deferred (O12)** — come back later. | O11 ✅, O12 |
| 2026-08-18 | **v0.1.4+5.** Geolocator FGS + wake lock + POST_NOTIFICATIONS + battery-exemption. 1 Hz, no distance filter (so a standing prayer test cannot look like a freeze). Dump header + pubspec bumped together. | O11, #31 |
| 2026-08-18 | **Walk 6.** 23 min pocket/prayer. 12 GPS, 0 steps. 1.8 cannot pass without FGS. | O11 |
| 2026-08-18 | **1.7 complete.** Claim + persist. Force-quit multiple times, hex stayed blue. | — |
| 2026-08-18 | **Walk 4 / first claim.** v0.1.2+3, brother. Territory 1. 512/512 fixes. | — |
| 2026-08-18 | **Walk 3 (cellular).** 578 steps, dist 0. Still the v0.1.0 / 35 m APK. | — |
| 2026-08-18 | **Walk 2.** GNSS 24.5 m. 412 steps, 64.1/80 m. No claim — 16 m short. | — |
| 2026-08-18 | **v0.1.2+3 + field report.** Client acc gate 35→80 m. GPS-chip fallback when the lock is Wi‑Fi-only. | #29 |
| 2026-08-18 | **v0.1.1+2 — first-walk fix.** Permission dialog + GPS-on button; 1 Hz stream with no 25 m filter; last-known + current-position seed; LocationManager fallback; overlay shows `raw gps` / errors. | #28 |
| 2026-08-18 | **APK committed to the repo.** `releases/terrastep-debug.apk` (45 MB). Docs reorganized so install / status / issues agree. | #27 |
| 2026-08-18 | **First green APK.** Flutter 3.27.4, analyzer clean, `libh3.so` packed. Built on a 2 GB box with 4 GB swap and Temurin 17 (Debian 13 has no JDK 17). | #23, #24, #25, #26 |
| 2026-08-18 | **APK build #1 failed** on open carets pulling plugins that need Flutter 3.38. Versions pinned against pub.dev. | #22 |
| 2026-08-18 | Android app + APK CI. Logic split into `packages/terrastep_core`. | — |
| 2026-08-18 | Threshold 2.6: outbox + sync worker. 43 client tests. | #19 |
| 2026-08-18 | Threshold 1.6: `SessionAccumulator`. Fixed armchair-claim exploit. | #17, #18 |
| 2026-08-18 | `ISSUES_LOG.md`, resume-anywhere section, CI + `SECURITY.md`. | #10–#12, #16 |
| 2026-08-17 | Fine-grained one-repo 7-day token. | #13–#15 |
| 2026-08-17 | Initial plan, schema, claim engine, prototype, 48-test suite. | #1–#9 |
