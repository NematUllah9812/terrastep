# TERRASTEP — Complete Technical Build Plan
**GPS territory-control MMO on a zero-budget stack**

Version 1.0 · Target: solo dev / 2-person team · Timeline: ~16–20 weeks part-time

---

## 0. Executive Summary

Terrastep converts the physical world into a hex grid (Uber H3, resolution 9 ≈ 0.1 km²
per cell). Players claim cells by physically walking inside them. Ownership is contested
by "effort score", decays without upkeep, and is rendered live on a vector map.

**The single most important architectural decision:** the phone is the *sensor*, but the
server is the *referee*. Never let the client write `territories` directly. All claims go
through a Postgres RPC (`claim_cell`) that revalidates plausibility, applies contest rules,
and writes an immutable ledger row. This is the difference between a game and a GPS-spoofing
free-for-all.

**Second most important:** the free tier is small (500 MB DB, 200 concurrent realtime
connections, 5 GB egress/month). The design below batches writes (1 per 60–120 s, not
1 per GPS fix), pushes geometry generation to the client (H3 is deterministic — never store
polygons), and keeps the realtime channel scoped to a geographic bucket rather than global.

**Reading order for this repo:**

| File | What it is |
|---|---|
| `00_MASTER_PLAN.md` | This file — architecture, phases, milestones |
| `01_DATA_MODEL.sql` | Complete Postgres schema, RLS, indexes |
| `02_CLAIM_ENGINE.sql` | The `claim_cell` RPC, contest + decay logic |
| `03_CLIENT_ARCHITECTURE.md` | Flutter app structure, background tracking, code |
| `04_ANTI_CHEAT.md` | Spoof detection, plausibility gates, rate limits |
| `05_COST_MODEL.md` | Free-tier budget math + when you must upgrade |
| `06_MILESTONE_CHECKLIST.md` | 34 numbered thresholds with acceptance tests |
| `prototype/` | Runnable browser prototype of the grid + claim loop |

---

## 1. Core Design Decisions (make these before writing code)

### 1.1 Grid: H3 over S2

| | H3 (hexagons) | S2 (quadkeys) |
|---|---|---|
| Neighbours | 6, all equidistant | 8, corners are further |
| "Walk across boundary" feel | Natural, no diagonal exploit | Diagonal movement is cheap |
| Library support | `h3` (JS), `h3_flutter`/`h3_dart`, `h3-pg` (Postgres) | Good, but weaker Dart story |
| Hierarchy | Approximate (children not perfectly nested) | Perfect nesting |

**Choose H3.** Territory games are about adjacency and border pressure; hexes make that
fair. The imperfect hierarchy only matters for exact area rollups, which you don't need.

**Resolution choice — this is a game-balance decision, not a technical one:**

| Res | Avg edge length | Avg area | Steps to cross | Feel |
|---|---|---|---|---|
| 8 | ~460 m | ~0.74 km² | ~600–1200 | Too big; one cell = a whole neighbourhood |
| **9** | **~174 m** | **~0.105 km²** | **~250–450** | **A city block cluster. Recommended.** |
| 10 | ~66 m | ~0.015 km² | ~90–170 | Grindy in cars, great for dense cities |
| 11 | ~25 m | ~0.002 km² | ~35–60 | Too granular; map becomes noise |

**Ship with res 9 as the ownership layer.** Optionally add res 10 later as a "influence
sub-grid" for contest scoring. Store the resolution in a column so you can migrate.

A single H3 index at res 9 is a 15-char hex string (`8928308280fffff`) or a 64-bit int.
**Store it as `TEXT` for readability in v1** — 15 bytes, and Postgres will index it fine.
If you exceed ~2M rows, migrate to `BIGINT` (h3 indexes fit in int64) to halve the index size.

### 1.2 Claim rule: "Effort Score", not raw steps

Raw steps are trivially spoofable (shake the phone). Use a composite:

```
effort = (steps_in_cell × 1.0)
       + (distance_m_in_cell × 0.35)
       + (dwell_seconds_in_cell × 0.05)
```

capped per visit at `MAX_EFFORT_PER_VISIT = 600`, and requiring **all three** floors:

```
CLAIM_THRESHOLD:
  steps_in_cell     >= 120
  AND distance_m    >= 80      (proves movement, not shaking)
  AND dwell_seconds >= 90      (proves presence, not a drive-by)
  AND unique_gps_fixes >= 5    (proves a real track)
```

The dwell floor is what kills the "drive through 40 hexes at 60 km/h" exploit, and the
distance floor kills the "sit at a desk shaking the phone" exploit. Together they mean the
only cheap way to claim is to actually walk.

### 1.3 Contest rule: decaying accumulator

Each `(user, cell)` pair holds an `influence` value. Ownership = highest influence, provided
it exceeds the runner-up by a **hysteresis margin** (prevents ownership flip-flopping every
sync and spamming your realtime quota).

```
new_influence = old_influence × decay(Δt) + effort_this_session
decay(Δt)     = 0.5 ^ (Δt_days / HALF_LIFE_DAYS)      HALF_LIFE_DAYS = 7

Owner changes only if:  challenger_influence > owner_influence × 1.15 + 50
Cell → neutral if:      max_influence < 100  (after decay)
```

Half-life decay is far better than a hard "expires in 14 days" timer because:
- It's continuous — no cron job needed, computed lazily on read/write.
- It rewards consistency over one huge burst.
- A defender who walks their block twice a week is effectively unbeatable by a one-off visitor,
  which is exactly the incentive you want (habit formation).

**Lazy decay is the trick:** never run a batch job to decay millions of rows. Store
`influence` + `influence_at` (timestamp). Compute the current value on demand:

```sql
influence * power(0.5, extract(epoch from (now() - influence_at)) / (7*86400))
```

This makes decay free. A nightly cron only needs to *delete* rows that have decayed below
the neutral floor, to reclaim disk space.

### 1.4 Realtime scoping: geographic channels

Do **not** subscribe every client to the whole `territories` table. With 200 concurrent
connections and 2M messages/month on the free tier, a global channel dies at ~50 users.

Subscribe to a **res-5 parent cell** channel (`~250 km²`, roughly a metro area):

```dart
supabase.channel('region:${h3.cellToParent(myCell, 5)}')
```

The server broadcasts claim events to the res-5 parent only. A user in Abbottabad never
receives a message about a claim in Lahore. This is a ~1000× message reduction and is the
single change that makes the free tier viable.

---

## 2. System Architecture

```
┌────────────────────────── PHONE (Flutter) ──────────────────────────┐
│                                                                      │
│  ┌─────────────┐   ┌──────────────┐   ┌───────────────────────────┐ │
│  │ HealthKit / │   │ flutter_     │   │  Foreground service        │ │
│  │ Health      │   │ background_  │   │  (Android) / Significant   │ │
│  │ Connect     │   │ geolocation  │   │  Location Change (iOS)     │ │
│  └──────┬──────┘   └──────┬───────┘   └────────────┬──────────────┘ │
│         │ steps           │ lat/lng/acc/speed      │                 │
│         └─────────┬───────┴────────────────────────┘                 │
│                   ▼                                                   │
│        ┌──────────────────────────┐                                  │
│        │  SessionAccumulator      │  ← pure Dart, unit-testable      │
│        │  · latLngToCell(res 9)   │                                  │
│        │  · per-cell step/dist/   │                                  │
│        │    dwell tally           │                                  │
│        │  · plausibility filter   │                                  │
│        └────────────┬─────────────┘                                  │
│                     ▼                                                 │
│        ┌──────────────────────────┐   ┌─────────────────────────┐   │
│        │  Drift/SQLite outbox     │──▶│  Sync worker (60–120 s) │   │
│        │  (survives app kill)     │   │  batched, retry+backoff │   │
│        └──────────────────────────┘   └───────────┬─────────────┘   │
│                                                    │                  │
│        ┌──────────────────────────┐                │                  │
│        │ MapLibre GL + H3 polygon │◀───────────────┘                  │
│        │ fill layer (GeoJSON src) │   ← geometry generated on-device  │
│        └──────────────────────────┘                                   │
└───────────────────────────────┬───────────────────────────────────────┘
                                │ HTTPS / WSS
┌───────────────────────────────▼───────────────────────────────────────┐
│                        SUPABASE (Free Tier)                            │
│                                                                        │
│  Auth (GoTrue)  ──▶  auth.users ──▶ profiles (1:1, trigger-created)   │
│                                                                        │
│  Postgres 15 + PostGIS + h3-pg                                        │
│   ├─ profiles          (username, colour, totals)                     │
│   ├─ territories       (cell_id PK, owner, influence, name, colour)   │
│   ├─ user_cell_influence (user × cell accumulator)                    │
│   ├─ claim_events      (immutable ledger — audit + anti-cheat)        │
│   └─ RPC: claim_cells(batch jsonb) ── SECURITY DEFINER, the referee   │
│                                                                        │
│  RLS: read = public, write = NOBODY (only the RPC writes)             │
│                                                                        │
│  Realtime: broadcast on channel `region:<res5cell>`                   │
│  pg_cron:  nightly cleanup of fully-decayed rows + leaderboard MV     │
└────────────────────────────────────────────────────────────────────────┘
```

### 2.1 Why client-side H3 + server-side validation (and not PostGIS everywhere)

The temptation is to send raw GPS tracks to PostGIS and let it do `ST_Contains`. Don't:

- **Egress.** A 30-min walk at 1 fix/5 s = 360 points × ~80 bytes = 29 KB per session.
  With 1000 users × 2 sessions/day that's 58 MB/day → blows 5 GB/month in 3 months.
- **Compute.** Free tier is a shared CPU with 500 MB RAM. Polygon containment on every
  fix will saturate it.

Instead the client sends **aggregates only** — one row per cell visited:

```json
{ "cell": "8928308280fffff", "steps": 340, "dist_m": 265, "dwell_s": 410,
  "fixes": 78, "t0": "...", "t1": "...", "max_speed": 1.7, "mean_acc": 8.2 }
```

A 30-min walk touching 6 cells = 6 rows ≈ 900 bytes. That's a **32× reduction**. The server
still validates: it recomputes `effort`, checks the speed/accuracy envelope, checks the cells
form a connected path in H3 space (`gridDistance <= 2` between consecutive cells), and checks
the claimed dwell doesn't exceed wall-clock time. Cheating requires forging a *coherent* fake
walk, which is a much higher bar than spoofing a single coordinate.

---

## 3. The Phased Roadmap — 5 Phases, 34 Thresholds

Each threshold is 2–8 hours of work with a binary acceptance test. Full checklist with
tests in `06_MILESTONE_CHECKLIST.md`.

### PHASE 1 — Local Prototype (Weeks 1–3) · No backend, no account
> **Goal:** you can walk around your neighbourhood and watch hexes fill in. Offline.

| # | Threshold | Output |
|---|---|---|
| 1.1 | Flutter project + MapLibre GL renders an OSM raster/vector basemap | Map on screen |
| 1.2 | Location permission flow (foreground → "always" escalation, iOS + Android) | Blue dot |
| 1.3 | `h3_flutter` wired; `latLngToCell(lat,lng,9)` prints current cell | Cell ID in debug |
| 1.4 | Render current cell + 2-ring neighbours as a GeoJSON fill layer | Hex grid visible |
| 1.5 | Pedometer/Health Connect/HealthKit reads step deltas | Live step counter |
| 1.6 | `SessionAccumulator` (pure Dart) tallies steps/dist/dwell per cell | Unit tests pass |
| 1.7 | Threshold reached → hex fills with your colour, persisted to SQLite | **Core loop works** |
| 1.8 | Background tracking survives screen-off for 30 min with <4%/hr battery | Battery report |

**Threshold 1.8 is the real boss fight of Phase 1.** Everything else is straightforward.
Budget a full week for it. iOS will kill your app; you must use the Significant-Location-Change
API + `UIBackgroundModes: location` and accept coarser sampling when backgrounded. Android
requires a persistent foreground-service notification and an exemption request from battery
optimisation. Details and code in `03_CLIENT_ARCHITECTURE.md §4`.

### PHASE 2 — Backend & Persistence (Weeks 4–6) · Single-player, cloud-saved
> **Goal:** log in on a second device, see your territory.

| # | Threshold | Output |
|---|---|---|
| 2.1 | Supabase project; run `01_DATA_MODEL.sql`; enable `h3` + `postgis` | Schema live |
| 2.2 | Email-magic-link + Google/Apple OAuth in app | Login screen |
| 2.3 | `profiles` auto-created by `on_auth_user_created` trigger | Row appears |
| 2.4 | RLS: public read, zero direct write; verified with a hostile test | Test suite red→green |
| 2.5 | `claim_cells(jsonb)` RPC deployed (`02_CLAIM_ENGINE.sql`) | pgTAP tests pass |
| 2.6 | Client outbox: queue in SQLite, flush on connectivity, idempotent | Airplane-mode test |
| 2.7 | `get_cells_in_view(cells text[])` returns ownership for viewport | JSON in <200 ms |
| 2.8 | Map paints owner colours on startup from server data | **Cloud persistence** |
| 2.9 | Territory naming + colour picker → `update_territory` RPC | Named hexes |

### PHASE 3 — Multiplayer (Weeks 7–10)
> **Goal:** two phones, one contested hex, correct winner.

| # | Threshold | Output |
|---|---|---|
| 3.1 | Realtime subscribe to `region:<res5>` channel; re-subscribe on region change | WS connected |
| 3.2 | RPC broadcasts `cell_changed` on ownership flip | Device B updates in <2 s |
| 3.3 | Contest logic + hysteresis verified with a 2-user pgTAP fixture | Correct winner |
| 3.4 | Lazy decay function `current_influence()` + nightly `pg_cron` sweep | Old cells go neutral |
| 3.5 | Contested-state rendering (hatched fill, pulsing border) | Visual states |
| 3.6 | Profile screen: total cells, area km², distance, longest streak | Stats page |
| 3.7 | Leaderboards — global + local (res-5 scoped) via materialised view | Refresh ≤5 min |
| 3.8 | Push notification "your territory is under attack" (FCM, free) | Notification lands |

### PHASE 4 — Anti-Cheat & Hardening (Weeks 11–13)
> **Do this before any public launch. Retrofitting anti-cheat is 5× the work.**

| # | Threshold | Output |
|---|---|---|
| 4.1 | Client: reject fixes where `isMocked == true` (Android) | Flag logged |
| 4.2 | Client: Kalman/accuracy filter, drop `accuracy > 35 m` | Cleaner tracks |
| 4.3 | Server: speed envelope — reject cell hops implying >8 m/s sustained | Rejections logged |
| 4.4 | Server: H3 path continuity — consecutive cells must be `gridDistance ≤ 2` | Teleport blocked |
| 4.5 | Server: step-vs-distance ratio sanity (0.4–1.2 m/step) | Shake detection |
| 4.6 | Rate limit: max 50 cells/user/hour, 200/day, enforced in RPC | 429 path |
| 4.7 | `claim_events` ledger + a `suspicion_score` on profiles; shadow-ban flag | Admin query |
| 4.8 | Rollback tooling: revert all claims from a user in one transaction | Admin RPC |

### PHASE 5 — Polish & Launch (Weeks 14–18)

| # | Threshold | Output |
|---|---|---|
| 5.1 | Onboarding: 3 screens explaining claim rules + permission rationale | Funnel |
| 5.2 | Offline map tile caching (MapLibre `MbTiles` or Protomaps PMTiles, free) | Works offline |
| 5.3 | Empty-state / first-claim celebration animation | Retention hook |
| 5.4 | Weekly recap ("you claimed 12 hexes, 8.3 km") | Engagement email |
| 5.5 | Crash + analytics (Sentry free tier, PostHog free tier) | Dashboards |
| 5.6 | Privacy policy, GDPR delete-my-data RPC, App Store health-data disclosure | Compliance |
| 5.7 | Closed beta, 20 users, 2 weeks | Bug list |
| 5.8 | Store submission (iOS $99/yr, Android $25 one-off — **only unavoidable cost**) | Live |
| 5.9 | Load test: simulate 500 synthetic users against free tier | Break point known |

---

## 4. Game Balance Constants (single source of truth)

Put these in a `game_config` table so you can tune without shipping an app update.

```
H3_RESOLUTION            = 9
CLAIM_MIN_STEPS          = 120
CLAIM_MIN_DISTANCE_M     = 80
CLAIM_MIN_DWELL_S        = 90
CLAIM_MIN_FIXES          = 5
EFFORT_STEP_WEIGHT       = 1.00
EFFORT_DIST_WEIGHT       = 0.35
EFFORT_DWELL_WEIGHT      = 0.05
MAX_EFFORT_PER_VISIT     = 600
DECAY_HALF_LIFE_DAYS     = 7
NEUTRAL_FLOOR            = 100
TAKEOVER_MULTIPLIER      = 1.15
TAKEOVER_FLAT_MARGIN     = 50
MAX_SPEED_MPS            = 8.0
MAX_ACCURACY_M           = 35
MAX_CELLS_PER_HOUR       = 50
MAX_CELLS_PER_DAY        = 200
SYNC_INTERVAL_S          = 90
REALTIME_PARENT_RES      = 5
```

**Tuning guidance:** the first thing beta testers will complain about is that claiming is
too slow. Resist lowering `CLAIM_MIN_STEPS` — instead lower `H3_RESOLUTION` to 10 so cells
are smaller and each claim feels achievable. Frequency of reward matters more than magnitude.

---

## 5. Known Hard Problems (and the honest answer)

**1. iOS background location is adversarial.** Apple will terminate your app. You cannot get
continuous 1 Hz GPS in the background for hours without the user seeing the blue status bar
and your app being flagged in the battery report. *Answer:* use `allowsBackgroundLocationUpdates`
+ significant-location-change, accept ~100–500 m granularity when fully backgrounded, and
backfill step counts from HealthKit (which the OS collects for free). Position accuracy only
needs to be good enough to attribute steps to the right hex, and HealthKit gives you
timestamped step buckets you can retroactively assign to your coarse location track.

**2. Rural players get 1 cell for a 5 km walk; urban players get 30.** This is inherent to a
fixed grid. *Answer:* score leaderboards on **effort and area**, not cell count, and run
local (res-5) leaderboards as the primary competitive surface.

**3. The 200-concurrent-realtime-connection ceiling.** At ~200 simultaneously-active users you
are done on the free tier. *Answer:* realtime is a luxury — degrade to a 30 s poll of
`get_cells_in_view` for users beyond the cap, and only open a WS when the map is in the
foreground. Realistically you will hit the 500 MB DB limit around 1.5–2M territory rows first.
See `05_COST_MODEL.md`.

**4. Safety and privacy.** You are building a database of where people walk. This is genuinely
sensitive. *Answer:* never expose another user's *track*, only aggregate cell ownership; snap
"home" cells out of leaderboards; offer a privacy radius the user can blank; and make the
data-deletion path real, not a form.

---

## 6. What to Build First — the 3-Day Spike

Before committing to the full plan, spend three days proving the riskiest assumption:

- **Day 1:** Flutter + MapLibre + `h3_flutter` → grid renders over your live position.
- **Day 2:** background location + pedometer running with screen off; measure battery drain
  over a 2-hour walk.
- **Day 3:** `SessionAccumulator` fills one hex correctly on a real walk around your block.

If Day 2's battery drain is above ~6%/hour, stop and redesign the sampling strategy before
building anything else. Everything downstream depends on people being willing to leave the
app running.

Start with `06_MILESTONE_CHECKLIST.md` threshold 1.1.
