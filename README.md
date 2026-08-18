# Terrastep — Complete Build Plan

A GPS territory-control MMO on a zero-budget stack. This repo is the full
technical plan: architecture, runnable database, verified game rules, client
code, anti-cheat design, cost ceilings, and a 45-threshold roadmap.

**Status of what's here: the backend runs, and there is a testing APK.**
`tests/run_tests.sh` asserts 48 behavioural tests (claiming, contesting,
hysteresis, decay, idempotency, teleport, shadow-ban). All 48 pass.
The Android debug build lives at
[`releases/terrastep-debug.apk`](releases/terrastep-debug.apk).
It has not been walked on a real phone yet — that is the next step.
See [`CURRENT_PROGRESS.md`](CURRENT_PROGRESS.md).

---

## Read in this order

| File | What it gives you |
|---|---|
| **`00_MASTER_PLAN.md`** | Start here. Architecture diagram, the 5 core design decisions (H3 res 9, effort scoring, decay-based contest, region-scoped realtime), the phased roadmap, and the honest list of hard problems. |
| **`01_DATA_MODEL.sql`** | Complete Postgres schema — tables, RLS, indexes, lazy-decay function, leaderboard matviews, `pg_cron` maintenance. Runs as-is on Supabase. |
| **`02_CLAIM_ENGINE.sql`** | The `claim_cells` RPC: the only code path allowed to write territory. Validation, contest resolution, ledger, realtime broadcast, idempotency. Plus read RPCs and admin rollback. |
| **`03_CLIENT_ARCHITECTURE.md`** | Flutter structure, package set, the background-tracking battery strategy, `SessionAccumulator` source, H3→MapLibre rendering, outbox sync worker, permission onboarding. |
| **`04_ANTI_CHEAT.md`** | Threat model (9 attacks), the 4 defence layers, why the step/distance ratio rule is the strongest single check, behavioural scoring SQL, and the shadow-ban ladder. |
| **`05_COST_MODEL.md`** | Where the free tier actually breaks (~600 MAU on storage, ~430 DAU on egress) and the specific changes that push it to ~2,500 MAU. Real year-one cost: **$124**. |
| **`06_MILESTONE_CHECKLIST.md`** | 45 thresholds across 6 phases, each with a binary acceptance test and an hour estimate. This is your actual work queue. |
| **`CURRENT_PROGRESS.md`** | Where we are against those 45 thresholds. **Start here when picking the project back up.** |
| **`releases/terrastep-debug.apk`** | Installable testing APK. Tap, install, walk. |
| **`packages/terrastep_core/`** | Pure-Dart game logic (accumulator, config, sync). 43 tests, no Flutter dependency. |
| **`app/`** | Flutter Android app — sensors, map, debug overlay. |
| **`ISSUES_LOG.md`** | Every blocker — symptom, cause, fix, prevention — plus open items. |
| **`SECURITY.md`** | Credential handling: the Supabase publishable/secret split, token scoping, leak response. |
| **`prototype/index.html`** | Zero-dependency browser prototype of the claim loop. Walk around, claim hexes, spawn rivals, watch territory decay. |
| **`tests/`** | The acceptance suite + a local-Postgres shim for Supabase. |

---

## Quick start

### 0. Get the APK on your Android phone

**[Download `releases/terrastep-debug.apk`](releases/terrastep-debug.apk)**
→ open the file → allow *install from unknown sources* → grant Location
and Physical activity.

Screen on, app open, walk a block. Screenshot the debug overlay.
Details in [`app/README.md`](app/README.md) and
[`CURRENT_PROGRESS.md`](CURRENT_PROGRESS.md) §0b.

This build does **not** track with the screen off.

### 1. Play the browser prototype (30 seconds)

Open `prototype/index.html` in any browser — no build, no network, no deps.

- **WASD** or drag to walk
- Watch the HUD fill: steps → distance → dwell → hex claimed
- **Spawn rivals** to see contest + hysteresis
- **Skip 3 days** to watch half-life decay rot your empire

It implements the exact constants and formulas from `02_CLAIM_ENGINE.sql`, so
tuning here transfers directly to the server.

### 2. Verify the backend

```bash
./tests/run_tests.sh                                       # 48 SQL assertions
cd packages/terrastep_core && dart pub get && dart test    # 43 Dart assertions
```

Needs only `postgresql` and the Dart SDK — no Flutter, no emulator. It applies the real SQL files
(nothing mocked but Supabase's `auth.uid()` and `realtime.send()`) and runs
all 48 assertions.

### 3. Deploy to Supabase

```bash
# In the Supabase SQL editor, in order:
#   1. 01_DATA_MODEL.sql
#   2. 02_CLAIM_ENGINE.sql
# Then check whether h3-pg is available on your region:
select * from pg_available_extensions where name like 'h3%';
# If yes, uncomment the [H3-PG] blocks in 02_CLAIM_ENGINE.sql — they close the
# telemetry-replay hole completely.
```

---

## The five decisions that define this design

1. **H3 resolution 9** (~0.1 km², ~250–450 steps to cross). Hexes over quadkeys
   because territory games are about fair adjacency; res 9 because it's a city
   block cluster, not a neighbourhood.

2. **Effort score, not raw steps.** `steps + 0.35×distance + 0.05×dwell`, gated
   behind *all three* floors (120 steps AND 80 m AND 90 s). The distance floor
   kills phone-shaking; the dwell floor kills drive-bys.

3. **Half-life decay, computed lazily.** Influence halves every 7 days. Never
   run a batch decay job — store `(influence, influence_at)` and compute on
   read. Decay costs nothing and quietly doubles as your best anti-cheat
   mechanic: a cheater's 5,000 stolen hexes evaporate in three weeks.

4. **Hysteresis on takeover.** A challenger must exceed `owner × 1.15 + 50`.
   Without this, ownership flip-flops on every sync and burns your realtime
   message quota.

5. **Region-scoped realtime.** Broadcast to a res-5 parent cell (~250 km²), not
   a global channel. This is a ~1000× message reduction and is the single change
   that makes the free tier viable at all.

---

## The three things most likely to kill this project

1. **Background battery drain** (threshold 1.8). If you can't track at
   <4%/hour, nothing downstream matters. That's why it's in the 3-day spike.
2. **Google Play background-location review** (threshold 5.8). Most first
   submissions are rejected. Record the demo video early.
3. **Cold-start emptiness.** A territory game with one player is a walking app
   with extra steps. Launch to *one neighbourhood* — a campus, a district — not
   the world. 30 players in 5 km² beats 3,000 scattered across a continent.

---

## Effort summary

| Phase | Thresholds | Hours |
|---|---|---|
| 0 — De-risk spike | 3 | 13 |
| 1 — Local prototype | 8 | 46 |
| 2 — Backend & persistence | 9 | 40 |
| 3 — Multiplayer | 8 | 40 |
| 4 — Anti-cheat | 8 | 27 |
| 5 — Polish & launch | 9 | 47 |
| **Total** | **45** | **~215 h** + 4 weeks review/beta |

≈ 5 months part-time at 12 h/week.

**Next action:** install `releases/terrastep-debug.apk` **v0.1.2**, set
Location to High accuracy (GPS on), walk again. First-walk write-up:
[`FIELD_REPORT_2026-08-18.md`](FIELD_REPORT_2026-08-18.md).
