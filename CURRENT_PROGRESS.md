# Terrastep — Current Progress

**Last updated:** 2026-08-18
**Repo:** `NematUllah9812/terrastep` (private)
**Latest commit:** CI workflow + SECURITY.md

---

## 1. Honest Summary

**Where we are: the design is complete and the server-side game logic is built
and verified. No mobile app exists yet.**

The backend is genuinely working code, not pseudocode — Postgres 17 was stood up
locally, the real schema and claim engine were applied, and 48 behavioural
assertions pass covering claiming, contesting, hysteresis, decay, idempotency,
teleport rejection and shadow-banning.

What has *not* started is the entire client: no Flutter project, no GPS, no
step counting, no map, no battery testing. That is the majority of the remaining
work and contains the single riskiest unknown in the project (background
tracking battery drain).

**A useful way to think about it:** the "referee" is finished and tested. The
"game" — the thing a user actually holds — has not been started.

| | Status |
|---|---|
| Design & architecture | ✅ Complete |
| Database schema | ✅ Written + verified deploys |
| Claim/contest/decay engine | ✅ Written + 48 tests passing |
| Server-side anti-cheat rules | 🟡 Mostly written, partially tested |
| Supabase deployment | ❌ Not done (tested locally only) |
| Flutter app | ❌ Not started |
| Real GPS / steps / battery | ❌ Not started |
| Store submission | ❌ Not started |

---

## 2. Threshold-by-Threshold Status

Legend: ✅ done & verified · 🟡 partial · ⬜ not started

### PHASE 0 — De-risk Spike *(0 / 3)*

| # | Threshold | Status | Note |
|---|---|---|---|
| 0.1 | Flutter + MapLibre basemap + blue dot | ⬜ | Not started |
| 0.2 | h3_flutter returns res-9 cell; hexes drawn | ⬜ | Hex maths proven in the JS prototype, but not in Flutter/H3 |
| 0.3 | Background location + pedometer, 2 h, screen off | ⬜ | **The GO/NO-GO gate. Highest project risk.** |

### PHASE 1 — Local Prototype *(0 / 8, 1 partial credit)*

| # | Threshold | Status | Note |
|---|---|---|---|
| 1.1 | MapLibre basemap at 60 fps | ⬜ | |
| 1.2 | Location permissions both OS | ⬜ | Flow *designed* in `03_CLIENT_ARCHITECTURE.md §9` |
| 1.3 | H3 integration | ⬜ | |
| 1.4 | Hex grid overlay | 🟡 | Rendering approach written + working in `prototype/`, but on a stand-in axial grid, not real H3 |
| 1.5 | Step source (HealthKit / Health Connect) | ⬜ | Packages selected, code sketched |
| 1.6 | `SessionAccumulator` + 6 unit tests | 🟡 | **Source written** in `03_CLIENT_ARCHITECTURE.md §5`; tests specified but not run |
| 1.7 | Local claim + SQLite persist | ⬜ | |
| 1.8 | Background survival, <4%/hr | ⬜ | **Boss fight of Phase 1** |

### PHASE 2 — Backend & Persistence *(3 / 9)*

| # | Threshold | Status | Note |
|---|---|---|---|
| 2.1 | Supabase project + schema applied | 🟡 | Schema **written and verified to deploy cleanly** on Postgres 17. Not yet run on a real Supabase project. |
| 2.2 | Auth (magic link + OAuth) | ⬜ | |
| 2.3 | Profile auto-creation trigger | ✅ | `on_auth_user_created` written; exercised by the test fixtures |
| 2.4 | RLS hostile test | 🟡 | Policies written (public read, zero direct write). The hostile test itself is **not** written — needs a real JWT to be meaningful. |
| 2.5 | `claim_cells` RPC deployed | ✅ | **48 assertions passing**, incl. all 5 required rejection fixtures |
| 2.6 | Outbox + sync worker | ⬜ | Design + code sketch done; server-side idempotency (`sync_receipts`) ✅ tested |
| 2.7 | `get_cells_in_view` | ✅ | Written; not yet load-tested for the <200 ms target |
| 2.8 | Server-driven map render | ⬜ | Needs the app |
| 2.9 | Naming + colour | ✅ | `update_territory` + auth checks tested (I1–I4) |

### PHASE 3 — Multiplayer *(2 / 8)*

| # | Threshold | Status | Note |
|---|---|---|---|
| 3.1 | Region-scoped realtime subscribe | ⬜ | Client side. Channel strategy decided (res-5 parent). |
| 3.2 | Broadcast on ownership change | 🟡 | `realtime.send()` call written and firing correctly in tests — but against a **shim**, not real Supabase Realtime |
| 3.3 | Contest + hysteresis | ✅ | **Verified.** Tests C6–C10, D1–D3 confirm the exact 395 flip point |
| 3.4 | Lazy decay + prune | ✅ | **Verified.** Tests E1–E6: half-life exact, prune reverts to neutral |
| 3.5 | Contested-state rendering | 🟡 | Working in the JS prototype (hatch overlay); not in Flutter |
| 3.6 | Profile & stats | 🟡 | Counters maintained + tested (C10); no UI |
| 3.7 | Leaderboards | 🟡 | Matviews + cron refresh written; never populated or benchmarked |
| 3.8 | Push notification | ⬜ | |

### PHASE 4 — Anti-Cheat *(3 / 8)*

| # | Threshold | Status | Note |
|---|---|---|---|
| 4.1 | Mock-location detection | ⬜ | Client side |
| 4.2 | Accuracy + jitter filter | 🟡 | Server accuracy gate ✅ tested (A7); client Kalman filter not built |
| 4.3 | Server speed envelope | ✅ | Test A3 |
| 4.4 | Path continuity / teleport | ✅ | Tests G1–G4 (Abbottabad→Karachi rejected, adjacent walk accepted) |
| 4.5 | Ratio sanity | ✅ | Tests A2a, A2b, A4 |
| 4.6 | Rate limiting | 🟡 | **Written but NOT tested.** Needs a 60-cell fixture. Known gap. |
| 4.7 | Behavioural scoring | 🟡 | `score_suspicion()` written in `04_ANTI_CHEAT.md §4` but **not deployed or tested**. Suspicion *increments* are tested (G3). |
| 4.8 | Rollback tooling | 🟡 | `admin_rollback_user()` written, **untested** |

### PHASE 5 — Polish & Launch *(0 / 9)*

All ⬜. Not started.

---

## 3. Scorecard

| Phase | ✅ Done | 🟡 Partial | ⬜ Not started | Total |
|---|---|---|---|---|
| 0 — Spike | 0 | 0 | 3 | 3 |
| 1 — Prototype | 0 | 2 | 6 | 8 |
| 2 — Backend | 4 | 3 | 2 | 9 |
| 3 — Multiplayer | 2 | 4 | 2 | 8 |
| 4 — Anti-cheat | 3 | 4 | 1 | 8 |
| 5 — Launch | 0 | 0 | 9 | 9 |
| **Total** | **9** | **13** | **23** | **45** |

**Fully complete: 9 / 45 (20%).**
Counting partials at half credit: ~15.5 / 45 (**~34%**).

**Hours burned vs. estimate:** roughly 30–35 h of the ~215 h estimate — but
weighted heavily toward design, which front-loads. The remaining work is more
implementation-dense than the raw percentage suggests.

---

## 4. What Actually Got Verified

This is the part worth being precise about, because "written" and "working" are
different things.

```
Postgres 17.10 · 01_DATA_MODEL.sql + 02_CLAIM_ENGINE.sql applied cleanly
48 / 48 assertions passing
```

| Group | Assertions | Covers |
|---|---|---|
| A — Validation rules | 13 | All 9 rejection rules + valid-walk acceptance |
| B — Effort scoring | 2 | Formula exactness (529.50), cap at 600 |
| C — Ownership lifecycle | 10 | claim → reinforce → contest → capture, counter upkeep |
| D — Hysteresis | 3 | The exact 395 flip boundary, both sides |
| E — Decay | 6 | Half-life precision, neutral reversion, prune |
| F — Idempotency | 3 | Retry returns cache, no double-count, one ledger row |
| G — Path continuity | 4 | Teleport rejected, adjacent walk accepted, suspicion bump |
| H — Enforcement | 3 | Shadow ban returns success but writes nothing |
| I — Customisation | 4 | Owner can rename, non-owner cannot, bad colour rejected |

Reproduce with `./tests/run_tests.sh` (needs only local `postgresql`).

**Deliberately not verified yet:** rate limiting (4.6), behavioural scoring
(4.7), rollback (4.8), real Supabase Realtime delivery, RLS under a genuine
`authenticated` JWT, and any performance/latency target.

---

## 5. Known Gaps & Risks

**Carried-forward test debt** — small, worth clearing before Phase 3:
1. Rate-limit path (4.6) — needs a 60-cell fixture asserting the 51st is refused.
2. `score_suspicion()` (4.7) — needs deploying plus a synthetic bot profile.
3. `admin_rollback_user()` (4.8) — needs a fixture proving reassignment to the
   next-strongest contender.
4. RLS hostile test (2.4) — requires a real Supabase JWT; can't be faked by the
   local shim.

**Environmental caveat:** everything was validated against vanilla Postgres 17
using a shim for `auth.uid()`, `realtime.send()` and PostGIS. Two things must be
re-checked on real Supabase:
- Whether the `h3` extension is available (`select * from pg_available_extensions
  where name like 'h3%'`). If yes, uncomment the `[H3-PG]` blocks — they close
  the telemetry-replay hole completely.
- Whether `realtime.send()` behaves as expected from inside a `SECURITY DEFINER`
  function.

**The three project-level risks are unchanged and all still ahead of us:**
1. Background battery drain (threshold 0.3) — unproven, and everything depends
   on it.
2. Google Play background-location review — most first submissions rejected.
3. Cold-start emptiness — launch to one neighbourhood, not the world.

---

## 6. Next Actions

**Immediate (highest value per hour):**

1. **Run the Phase 0 spike.** Three days, and it either de-risks the project or
   tells you to redesign before you write 200 more hours of code. Nothing else
   should be started first.
2. **Deploy to a real Supabase project** (threshold 2.1 properly). ~1 hour, and
   it flushes out the h3-pg and realtime questions above.
3. **Clear the four test-debt items.** ~4 hours, keeps the suite honest.

**Then:** Phase 1 in order, 1.1 → 1.8, with 1.8 given a full week.

**Infrastructure now in place:**
- ✅ **CI** — `.github/workflows/tests.yml` runs the 48 assertions on every push
  touching `*.sql` or `tests/`, plus a secret scan that fails the build on
  committed GitHub PATs, `sb_secret_…` keys or raw JWTs.
- ✅ **SECURITY.md** — credential handling rules, the Supabase
  publishable/secret split, and leak-response steps. Written before Phase 2
  introduces real keys.

---

## 7. Changelog

| Date | Change |
|---|---|
| 2026-08-18 | Added CI workflow (48 assertions + secret scan) and `SECURITY.md`. Fixed `run_tests.sh`: lost executable bit, and Postgres discovery now handles Debian/Homebrew/Postgres.app with a clear error when missing. Verified clean-slate run on a bare machine. |
| 2026-08-17 | Initial plan, schema, claim engine, prototype, 48-test suite. |
