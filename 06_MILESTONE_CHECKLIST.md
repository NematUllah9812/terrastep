# TERRASTEP — Milestone Checklist
### 45 thresholds, each with a binary acceptance test

Work strictly top to bottom. Do not start a phase until the previous one's
**exit criteria** pass. Estimated effort assumes one developer, part-time.

**Live status lives in [`CURRENT_PROGRESS.md`](CURRENT_PROGRESS.md), not
here.** This file is the work queue: a box is checked only when the
acceptance test has actually been run. Code that compiles but has not
been walked is still unchecked.

**Where we are (2026-08-18):** **1.6 and 1.7 are ✅.** Walk 7 proved
pocket tracking on **v0.1.4+5** (hex claimed at ~1 Hz). **1.8 battery
&lt;4 %/hr is deferred (O12)** — measured ~8.5 %/hr, come back later.
Next product work: Phase 2.1 real Supabase. APK: `releases/terrastep-debug.apk`.

---

## PHASE 0 — The 3-Day Spike  *(de-risk before committing)*

- [ ] **0.1** Flutter + MapLibre renders a basemap and your blue dot — *2 h*
- [ ] **0.2** `h3_flutter` returns a res-9 cell for your position; hexes drawn — *3 h*
- [ ] **0.3** Background location + pedometer run for 2 h with screen off — *8 h*

> **GO/NO-GO:** measure battery drain in 0.3. If it exceeds **6%/hour**, stop and
> redesign sampling (adaptive intervals, geofence-based stationary detection)
> before writing anything else. Every downstream assumption depends on users
> being willing to leave this running.

---

## PHASE 1 — Local Prototype  *(Weeks 1–3)*

| # | Threshold | Acceptance test | Est. |
|---|---|---|---|
| 1.1 | Flutter project scaffolded, MapLibre basemap | Map pans/zooms at 60 fps on a mid-range Android | 3 h |
| 1.2 | Location permissions (foreground → always, both OS) | Cold install → permission granted → blue dot, on a real iPhone AND a real Android | 6 h |
| 1.3 | H3 integration | `latLngToCell(34.1688, 73.2215, 9)` matches h3-js output exactly | 2 h |
| 1.4 | Hex grid overlay | 2-ring around current cell renders; hexes align with roads when zoomed | 4 h |
| 1.5 | Step source | Steps increment within 5 s of walking; works after app restart | 6 h |
| 1.6 | `SessionAccumulator` | **✅ Unit tests pass.** | 8 h |
| 1.7 | Local claim + persist | **✅ Walk → hex fills → force-quit → still blue.** (SharedPreferences, not SQLite.) | 5 h |
| 1.8 | Background survival | 30-min walk, screen off, phone pocketed → correct hexes claimed, <4%/hr drain | 12 h |

**Exit criteria:** You can hand your phone to a friend, they walk around the
block, and hexes fill in correctly with the app in their pocket. No backend yet.

---

## PHASE 2 — Backend & Ownership Persistence  *(Weeks 4–6)*

| # | Threshold | Acceptance test | Est. |
|---|---|---|---|
| 2.1 | Supabase project + `01_DATA_MODEL.sql` applied | `\dt` shows all tables; `select cfg('h3_resolution')` → 9 | 3 h |
| 2.2 | Auth (magic link + Google/Apple) | Sign up, sign out, sign back in, session persists across restart | 6 h |
| 2.3 | Profile auto-creation | New signup → `profiles` row exists with a generated username | 1 h |
| 2.4 | **RLS hostile test** | With an `authenticated` JWT, all of these FAIL: direct `insert into territories`, `update territories set owner_id=me`, `update profiles set cells_owned=9999`, `select * from user_cell_influence` (other user) | 4 h |
| 2.5 | `claim_cells` RPC deployed | The 5 rejection fixtures in `04_ANTI_CHEAT.md §7` all return the expected reason; the golden valid track is accepted | 6 h |
| 2.6 | Outbox + sync worker | Enable airplane mode, walk 3 hexes, re-enable → all 3 sync exactly once (verify `claim_events` has no duplicates) | 8 h |
| 2.7 | `get_cells_in_view` | 300-cell request returns in <200 ms; payload <20 KB | 3 h |
| 2.8 | Server-driven map render | Fresh install on device B, same account → all territory from device A appears | 4 h |
| 2.9 | Naming + colour | Long-press own hex → rename + recolour → persists; long-press enemy hex → no edit option | 5 h |

**Exit criteria:** Claim territory on phone A, log in on phone B, see it. Kill
the app mid-walk and nothing is lost or double-counted.

---

## PHASE 3 — Multiplayer  *(Weeks 7–10)*

| # | Threshold | Acceptance test | Est. |
|---|---|---|---|
| 3.1 | Region-scoped realtime subscribe | WS connects to `region:<res5>`; walking into a new res-5 area re-subscribes exactly once | 5 h |
| 3.2 | Broadcast on ownership change | User A captures a hex → User B's map updates in <2 s without a manual refresh | 4 h |
| 3.3 | **Contest + hysteresis** | Two accounts, one hex: A claims (effort 300). B walks effort 320 → **stays A** (320 < 300×1.15+50=395). B walks to 400 → **flips to B**. Verified in SQL and on both devices | 6 h |
| 3.4 | Lazy decay + prune | `update territories set influence_at = now() - interval '30 days'` → `get_cell_detail` shows near-zero influence → nightly `prune_decayed()` reverts it to neutral | 4 h |
| 3.5 | Contested-state rendering | A hex where another user has >30% of your influence renders with a hatch/pulse distinct from owned and enemy | 5 h |
| 3.6 | Profile & stats | Cells owned, km² controlled, total distance, current + longest streak — all match a hand-computed SQL check | 5 h |
| 3.7 | Leaderboards | Global top-500 and local (res-5) leaderboard render; matview refresh ≤15 min; shadow-banned users absent | 5 h |
| 3.8 | Push notification | User B captures User A's hex → A receives "Hilltop Ridge is under attack" via FCM within 60 s | 6 h |

**Exit criteria:** Two people, one neighbourhood, one contested hex — the right
person wins, both phones agree within 2 seconds, and neither can cheat the result
by editing the app.

---

## PHASE 4 — Anti-Cheat & Hardening  *(Weeks 11–13)*
> Non-negotiable before any public release.

| # | Threshold | Acceptance test | Est. |
|---|---|---|---|
| 4.1 | Mock-location detection | Enable a mock-location app on Android → fixes rejected client-side, `mockDetected` telemetry increments | 3 h |
| 4.2 | Accuracy + jitter filter | Stand still indoors 10 min → accumulated distance <20 m (not 400 m of drift) | 4 h |
| 4.3 | Server speed envelope | Submit a forged payload with `max_speed_mps: 20` via raw REST → `implausible_speed` | 2 h |
| 4.4 | Path continuity | Forged payload: Abbottabad cell then Karachi cell 60 s apart → `teleport_between_cells` | 3 h |
| 4.5 | Ratio sanity | Forged: 2000 steps / 5 m → `steps_without_distance`; 150 steps / 900 m → `distance_without_steps` | 2 h |
| 4.6 | Rate limiting | Script 60 valid-looking cells in one hour → 51st returns `rate_limited`, suspicion +5 | 3 h |
| 4.7 | Behavioural scoring | `score_suspicion()` runs nightly; a synthetic bot profile (zero effort variance, 3 AM activity) scores >75 and is shadow-banned | 6 h |
| 4.8 | Rollback tooling | `admin_rollback_user(uuid)` reverts every claim, reassigns to next contender, in one transaction | 4 h |

**Exit criteria:** You personally spend 4 hours actively trying to cheat your own
game — mock GPS, modified payloads, driving a route, shaking the phone — and
either fail, or succeed in a way the suspicion score catches by the next morning.

---

## PHASE 5 — Polish & Launch  *(Weeks 14–18)*

| # | Threshold | Acceptance test | Est. |
|---|---|---|---|
| 5.1 | Onboarding + delayed "Always" prompt | 5 fresh testers complete onboarding unaided; ≥3 grant "Always" | 8 h |
| 5.2 | Offline map tiles | Airplane mode → map still renders your city from cached PMTiles | 8 h |
| 5.3 | First-claim celebration | First hex triggers animation + haptic; only once | 4 h |
| 5.4 | Weekly recap | Cron generates and sends a recap; unsubscribe link works | 5 h |
| 5.5 | Sentry + PostHog | A deliberate crash appears in Sentry with a symbolicated stack trace | 4 h |
| 5.6 | Privacy & compliance | Privacy policy live; `delete_my_data()` RPC verifiably removes all rows; HealthKit disclosure in App Store Connect | 8 h |
| 5.7 | Closed beta | 20 users × 2 weeks; crash-free sessions >98%; bug list triaged | 2 wk |
| 5.8 | Store submission | Approved on both stores (expect 1–2 rejections on background-location justification) | 2 wk |
| 5.9 | Load test | 500 synthetic users hammering `claim_cells` → p95 latency <800 ms; record the break point | 6 h |

**Exit criteria:** Live on both stores, monitored, backed up, and you know
exactly which metric will force the $25/mo upgrade and when.

---

## Cross-Cutting: Do These Continuously

- [ ] **Nightly `pg_dump` to a private repo** — the free tier has *no backups*.
      Set this up in Phase 2, not Phase 5.
- [ ] **Keepalive cron verified** — free projects pause after 7 days idle.
- [ ] **Weekly capacity query** (`05_COST_MODEL.md §7`) emailed to yourself.
- [ ] **Golden track fixture** — capture one real walk in Phase 1 and run it
      against the validator on every deploy. It's what stops you from tightening
      anti-cheat rules until honest users get rejected.
- [ ] **`game_config` tuning log** — record every balance change and the
      retention/complaint effect. This is your real product work post-launch.

---

## Effort Summary

| Phase | Thresholds | Est. hours |
|---|---|---|
| 0 — Spike | 3 | 13 |
| 1 — Prototype | 8 | 46 |
| 2 — Backend | 9 | 40 |
| 3 — Multiplayer | 8 | 40 |
| 4 — Anti-cheat | 8 | 27 |
| 5 — Launch | 9 | 47 + 4 wk calendar |
| **Total** | **45** | **~215 h + 4 wk waiting** |

At 12 h/week that's ~18 weeks of build plus overlapping beta/review time —
call it **5 months part-time** to a real launch.

---

## The Three Things Most Likely To Kill This Project

1. **Threshold 1.8 (background battery).** If you can't track reliably at <4%/hr,
   nothing else matters. This is why it's in the 3-day spike.
2. **Threshold 5.8 (Play Store background-location review).** Google rejects most
   first submissions. Record the demo video early and write the justification
   before you need it.
3. **Cold-start emptiness.** A territory game with one player is a walking app
   with extra steps. Launch to a *single neighbourhood* — one university campus,
   one city district — not to the world. 30 players in 5 km² beats 3,000 players
   scattered across a continent.
