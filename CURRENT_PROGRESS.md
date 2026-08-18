# Terrastep — Current Progress

**Last updated:** 2026-08-18
**Repo:** `NematUllah9812/terrastep` (private)
**Latest:** Walk 3 stored (cellular). Distance 0 again — still on **v0.1.0** (35 m gate).
**Field data:** [`FIELD_REPORT_2026-08-18.md`](FIELD_REPORT_2026-08-18.md)
**Next deliverable:** uninstall old APK → install **v0.1.2+3** → dump must say `v0.1.2+3` → walk

| | |
|---|---|
| **Walk 1** | Wi‑Fi lock. Dist 0. Acc 42–300 m. |
| **Walk 2** | GNSS 24.5 m. Dist **64.1 / 80**. Almost a claim. |
| **Walk 3** | Cellular, pin ok. 578 steps, dist **0**. Acc 22–87 m. 15× poor acc + 1 too fast. **Old 35 m APK.** |
| **Battery** | ~1 % / 7 min screen-on. |

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
| Size | 45 MB |
| ABI | `arm64-v8a` (every phone we care about for this test) |
| Signed | Debug (not Play Store) |
| Built | 2026-08-18, Flutter 3.27.4, locally, then committed |
| Offline | Yes — no account, no server, no Supabase |

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

### What we need from the walk

Test with the **screen on and the app open**. This build has no foreground
service (O11) — tracking stops when you lock the screen.

| Question | Why |
|---|---|
| Did a hex fill after ~120 steps? | Core loop on real GPS |
| `m/step` while walking | Server rejects outside 0.30–1.60 |
| Typical `gps acc` | Routinely >35 m = accuracy gate too strict |
| Rejected-fix counts | Tells us which filter to tune |
| `pedometer` ok / EST. from dist | Hardware vs. fallback |
| Battery % over 15–20 min, screen ON | Foreground drain (worst case) |

Screenshot the overlay. That one picture answers 0.1, 0.2, 1.1–1.5 and 1.7.

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

**Three walks.** Walk 2 proved the loop (64 m of 80). Walk 3 was still the
old 35 m APK on cellular — 15 rejects in the 36–87 m band that v0.1.2
would have kept. Next is install, not another walk on v0.1.0.

The backend is real code, not a sketch: 48 behavioural assertions pass
(claiming, contesting, hysteresis, decay, idempotency, teleport rejection,
shadow-banning).

The client is past "not started". Sensors, map, H3, local persist and the
debug overlay compile into an installable APK that lives in this repo.
The only test that matters has not happened: a human walking a block with
the screen on, then (later) a 30-minute pocket test with a foreground
service.

The referee is done. The board exists. We have not yet played a real game
on it.

| | Status |
|---|---|
| Design & architecture | ✅ Complete |
| Database schema | ✅ Written + verified deploys |
| Claim / contest / decay engine | ✅ Written + 48 tests passing |
| Server-side anti-cheat rules | 🟡 Mostly written, partially tested |
| Supabase deployment | ❌ Local Postgres only |
| Flutter app | 🟡 Claims on device; persist untested |
| Real GPS / steps / battery | 🟡 Walk 4: claim + 3.4 m lock. Pocket test not done |
| Store submission | ❌ Not started |

---

## 2. Threshold-by-Threshold Status

Legend: ✅ done & verified · 🟡 implemented, waiting on a device · ⬜ not started

### PHASE 0 — De-risk Spike *(0 / 3 done, 2 waiting on a walk)*

| # | Threshold | Status | Note |
|---|---|---|---|
| 0.1 | Flutter + MapLibre basemap + blue dot | 🟡 | Compiles. flutter_map + OSM + blue dot (not MapLibre — #21). Needs tiles + tracking on a phone. |
| 0.2 | h3_flutter returns res-9 cell; hexes drawn | 🟡 | Compiles. Real `h3_flutter` 0.7.1, ids padded to 15 chars. Unverified against h3-js (O9). |
| 0.3 | Background location + pedometer, 2 h, screen off | ⬜ | **GO/NO-GO.** This APK is foreground-only. Pocket test waits on O11. |

### PHASE 1 — Local Prototype *(1 / 8 done, 6 waiting on a walk)*

| # | Threshold | Status | Note |
|---|---|---|---|
| 1.1 | Map basemap | 🟡 | flutter_map + OSM compile; needs on-device fps / tile check |
| 1.2 | Location permissions | 🟡 | Foreground location + ACTIVITY_RECOGNITION implemented |
| 1.3 | H3 integration | 🟡 | `H3Indexer` on the `CellIndexer` seam; unverified vs h3-js |
| 1.4 | Hex grid overlay | 🟡 | Real H3 polygons; claimed hexes stay on the map |
| 1.5 | Step source | 🟡 | Hardware pedometer + 0.78 m stride fallback. Health Connect later. |
| 1.6 | `SessionAccumulator` + unit tests | ✅ | 27/27 passing. Fixed the armchair-claim exploit (#17). |
| 1.7 | Local claim + persist | 🟡 | SharedPreferences written; needs force-quit test on device |
| 1.8 | Background survival, <4%/hr | ⬜ | Foreground service not implemented (O11). |

### PHASE 2 — Backend & Persistence *(4 / 9)*

| # | Threshold | Status | Note |
|---|---|---|---|
| 2.1 | Supabase project + schema applied | 🟡 | Deploys cleanly on Postgres 17. Not on a real Supabase project. |
| 2.2 | Auth (magic link + OAuth) | ⬜ | |
| 2.3 | Profile auto-creation trigger | ✅ | `on_auth_user_created`; exercised by fixtures |
| 2.4 | RLS hostile test | 🟡 | Policies written. Hostile test needs a real JWT. |
| 2.5 | `claim_cells` RPC | ✅ | 48 assertions, including all 5 required rejections |
| 2.6 | Outbox + sync worker | 🟡 | Logic + 16 tests. Needs Drift/SQLite for real durability. |
| 2.7 | `get_cells_in_view` | ✅ | Written; not load-tested for <200 ms |
| 2.8 | Server-driven map render | ⬜ | Needs the app + a server |
| 2.9 | Naming + colour | ✅ | `update_territory` + auth checks (I1–I4) |

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
| 1 — Prototype | 1 | 6 | 1 | 8 |
| 2 — Backend | 4 | 4 | 1 | 9 |
| 3 — Multiplayer | 2 | 4 | 2 | 8 |
| 4 — Anti-cheat | 3 | 4 | 1 | 8 |
| 5 — Launch | 0 | 0 | 9 | 9 |
| **Total** | **10** | **20** | **15** | **45** |

**Fully complete: 10 / 45 (22%).**
Partials at half credit: ~20 / 45 (**~44%**).

The percentage barely moved because the APK is *instrumentation*, not
acceptance. 0.1 / 0.2 / 1.1–1.5 / 1.7 flip to ✅ the moment a hex fills
on a real sidewalk.

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
latency target, and **anything on a real phone**.

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

1. Background battery drain (0.3 / 1.8) — unproven. Everything depends on it.
2. Google Play background-location review — most first submissions rejected.
3. Cold-start emptiness — launch to one neighbourhood, not the world.

---

## 6. Next Actions

**Do these in this order. Nothing else first.**

1. **Force-quit Terrastep, reopen.** If the hex is still blue, 1.7 persist is done.
   Copy the overlay either way.
2. **Foreground service (O11)** so the real 0.3 / 1.8 pocket test can run.
3. **Deploy to a real Supabase project** (threshold 2.1, properly). ~1 hour.
4. **Clear the four test-debt items.** ~4 hours.

Then Phase 1 in order through 1.8, with 1.8 given a full week.

**Already in place**

- ✅ CI — `.github/workflows/tests.yml` (48 SQL assertions + secret scan)
- ✅ APK CI — `.github/workflows/build-apk.yml` (Flutter 3.27.4)
- ✅ `SECURITY.md` — written before Phase 2 introduces real keys
- ✅ Testing APK — `releases/terrastep-debug.apk`

---

## 7. Changelog

| Date | Change | Issues |
|---|---|---|
| 2026-08-18 | **Walk 3 (cellular).** 578 steps, dist 0, acc 22–87 m, 15× poor acc + 1 too fast. Still the v0.1.0 / 35 m APK. | — |
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
