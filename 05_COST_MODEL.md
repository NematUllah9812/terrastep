# TERRASTEP — Cost Model & Scaling Ceilings

Verified against Supabase Free tier limits (Aug 2026):
500 MB DB · 5 GB egress/mo · 1 GB storage · 50k MAU · 200 peak realtime
connections · 2M realtime messages/mo · 500k edge fn invocations · 2 projects ·
**paused after 7 days of inactivity** · no backups.

---

## 1. Storage Budget (the binding constraint)

Per-row estimates including index and tuple overhead:

| Table | Bytes/row | Notes |
|---|---|---|
| `profiles` | ~250 | Negligible at any realistic scale |
| `territories` | ~180 | 15-byte cell_id + uuid + numerics + 2 indexes |
| `user_cell_influence` | ~110 | **The one that grows fastest** |
| `claim_events` | ~150 | Partitioned; drop partitions >3 months |

**Growth model.** An active user walking 5 km/day at res 9 touches ~35 cells/day,
of which maybe 15 are new. Revisits dominate after week 2.

| Users (MAU) | territories | user_cell_influence | claim_events (90 d) | **Total** |
|---|---|---|---|---|
| 100 | 25k (4.5 MB) | 40k (4.4 MB) | 300k (45 MB) | **~55 MB** ✅ |
| 500 | 110k (20 MB) | 200k (22 MB) | 1.5M (225 MB) | **~270 MB** ⚠️ |
| 1,000 | 200k (36 MB) | 420k (46 MB) | 3M (450 MB) | **~530 MB** ❌ |
| 5,000 | 900k (162 MB) | 2.2M (242 MB) | — | **exceeds** ❌ |

**Verdict: the free tier breaks at ~600–800 MAU, and `claim_events` is what kills
you.** Fixes, in order of effort:

1. **Only log rejected + ownership-changing events** (not `reinforced`). Cuts
   `claim_events` by ~70%. Do this from day one:
   ```sql
   if v_outcome <> 'reinforced' or random() < 0.05 then  -- 5% sample
     insert into public.claim_events ...
   end if;
   ```
   This single change moves the ceiling from ~700 to ~2,500 MAU.
2. **Drop partitions at 30 days**, not 90. `claim_events` is forensics, not
   history — 30 days is plenty for suspicion scoring.
3. **Migrate `cell_id` TEXT → BIGINT.** H3 indexes are 64-bit. Saves ~7 bytes/row
   plus much more in index size. Do it at ~1M rows, not before.
4. **Prune aggressively.** The nightly `prune_decayed()` deletes influence rows
   below 5 — after 6 half-lives (~6 weeks) an untouched row is gone.

Realistic ceiling with fixes 1+2 applied: **~2,500–3,000 MAU on $0.**

---

## 2. Egress Budget

5 GB/month. Where it goes:

| Operation | Size | Freq/user/day | MB/user/month |
|---|---|---|---|
| `get_cells_in_view` (300 cells) | ~18 KB | 15 map opens | 8.1 |
| `claim_cells` request | ~2 KB | 12 syncs | 0.7 |
| `claim_cells` response | ~1 KB | 12 | 0.4 |
| Realtime messages inbound | ~0.5 KB | 40 | 0.6 |
| Leaderboard | ~25 KB | 2 | 1.5 |
| Profile/avatar | ~40 KB | 0.2 (cached) | 0.2 |
| **Total** | | | **~11.5 MB** |

**5,000 MB ÷ 11.5 MB ≈ 430 daily-active users.** Egress binds *before* storage.

Reductions:
- **Cache territory data locally in SQLite with an ETag.** Send
  `if_modified_since` and return only cells changed since. Cuts the 8.1 MB item
  by ~85% → total drops to ~4.5 MB/user/mo → **~1,100 DAU**.
- Serve avatars from Supabase Storage with a long `Cache-Control` (cached egress
  has its own separate 5 GB allowance).
- Cap `get_cells_in_view` at 300 cells and never fetch on every camera move —
  debounce 300 ms and only refetch when the viewport moves >30% of its width.

---

## 3. Realtime Budget

2M messages/month, 200 peak concurrent connections.

With **region-scoped broadcast** (res-5 parent, ~250 km²):
- Only users in the same metro receive a claim event.
- Assume 50 active users per region, each claiming 15 cells/day, batched into
  ~6 broadcasts/day → 300 broadcasts/day/region × 50 recipients = 15,000
  messages/day/region → **450k/month per region.**

**You can support ~4 active metro regions before hitting 2M messages.** That's
fine for a launch, and it degrades gracefully: when you approach the cap, disable
broadcast and fall back to a 30 s poll (which costs egress, not messages).

Without region scoping (global channel), 50 users generate the same 450k — but
500 users generate 45M. **Region scoping is not optional.**

The 200-connection cap is the softer limit because you only hold a WS while the
map screen is foregrounded — realistically ~8% of MAU at peak, so ~2,500 MAU
before you hit 200 concurrent.

---

## 4. The Real Money

| Item | Cost | Avoidable? |
|---|---|---|
| Apple Developer Program | **$99/year** | No, if you want iOS |
| Google Play Developer | **$25 one-off** | No, if you want Android |
| `flutter_background_geolocation` Android licence | ~$300 one-off | Yes — use `geolocator` + foreground_task |
| Domain name (privacy policy hosting) | ~$12/yr | Yes — use GitHub Pages |
| Map tiles | $0 | Yes — Protomaps PMTiles self-hosted, or MapTiler free tier (100k loads/mo) |
| Push notifications (FCM) | $0 | Free, unlimited |
| Crash reporting (Sentry) | $0 | Free tier: 5k errors/mo |
| Analytics (PostHog) | $0 | Free tier: 1M events/mo |

**Unavoidable year-one cost: $124.** Everything else is genuinely $0.

---

## 5. Upgrade Triggers — know your break-glass points

| Signal | Threshold | Action | New cost |
|---|---|---|---|
| DB size | >400 MB | Apply storage fixes 1+2 | $0 |
| DB size | >450 MB after fixes | Supabase Pro | $25/mo |
| Egress | >4 GB/mo | Implement delta-sync caching | $0 |
| Realtime msgs | >1.6M/mo | Disable broadcast, poll fallback | $0 |
| Peak connections | >180 | Foreground-only WS + connection budget | $0 |
| Cold-start complaints | any | Pro (free tier pauses + shared CPU) | $25/mo |

**Pro plan at $25/mo** gets you 8 GB DB, 250 GB egress, 500 connections, daily
backups, and no pausing — comfortably good for ~20,000 MAU. That's your only
planned spend until real traction.

---

## 6. Free-Tier Operational Gotchas

1. **Projects pause after 7 days of low activity.** The `keepalive` cron in
   `01_DATA_MODEL.sql` prevents this. Verify it's running — a paused project
   means a dead app with no warning email that anyone reads.
2. **No backups on Free.** Set up your own: a GitHub Action running
   `pg_dump` nightly to a private repo or R2 bucket. ~20 lines of YAML. Do this
   before you have your first real user, not after you lose them.
3. **Shared CPU, 500 MB RAM.** The `claim_cells` RPC does a `FOR UPDATE` row lock
   per cell. A 30-cell batch holds locks for ~50 ms. Fine at low concurrency;
   watch `pg_stat_activity` if syncs bunch up.
4. **1-day log retention.** Ship anything you need for forensics into your own
   tables (`claim_events` already does this).
5. **2 projects max.** Use one for prod, one for staging. You will not get a
   third — so don't plan a separate dev environment; run dev against local
   Supabase (`supabase start`, free, Docker).

---

## 7. Suggested Monitoring Query (run weekly)

```sql
select
  (select pg_size_pretty(pg_database_size(current_database())))       as db_size,
  (select count(*) from public.profiles)                              as users,
  (select count(*) from public.territories)                           as cells,
  (select count(*) from public.user_cell_influence)                   as influence_rows,
  (select count(*) from public.claim_events
     where created_at > now() - interval '7 days')                    as events_7d,
  (select pg_size_pretty(pg_total_relation_size('public.claim_events')))
                                                                      as events_size,
  (select count(*) from public.profiles where suspicion_score > 50)   as flagged;
```

Put it on a cron that emails you. The free tier gives no alerting.
