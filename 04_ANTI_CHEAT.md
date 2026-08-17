# TERRASTEP — Anti-Cheat Design

> Every GPS game gets cheated. Pokémon GO, Ingress, Run An Empire — all of them.
> You will not stop a determined attacker with a rooted phone. Your goal is
> narrower and achievable: **make cheating more effort than walking**, and make
> the cheating that does happen *detectable and reversible*.

---

## 1. Threat Model

| # | Attack | Effort | Impact | Mitigation layer |
|---|---|---|---|---|
| T1 | Shake phone / desk fan → fake steps | Trivial | Low | Client + R6 ratio |
| T2 | Drive/cycle a route to claim many cells | Trivial | **High** | R4 speed, R2 dwell |
| T3 | Mock-location app (Android dev options) | Easy | **High** | `isMocked` + R9 |
| T4 | iOS location spoof via Xcode `.gpx` | Easy | High | R9 + R7 coherence |
| T5 | Direct REST calls to the RPC with forged JSON | Medium | **Critical** | Server rules R1–R9 |
| T6 | Modified APK bypassing client checks | Medium | Critical | Server rules (client is never trusted) |
| T7 | Replay a real walk's payload repeatedly | Medium | Medium | `sync_receipts` + R5 stale window |
| T8 | Multi-accounting to stack influence | Medium | Medium | Device fingerprint + rate limits |
| T9 | Automated bot farm w/ realistic tracks | High | High | Behavioural scoring (§4) |

**The design principle:** the client's job is UX and battery, not security. Assume
every field in the payload is attacker-controlled. That's why `validate_cell_claim()`
in `02_CLAIM_ENGINE.sql` re-derives everything and trusts nothing.

---

## 2. Layer 1 — Client-Side Filters (cheap, stops honest-mistake noise)

These reduce server load and false rejections. They are **not** security.

```dart
bool acceptFix(Position p) {
  if (p.isMocked) {                      // Android: Location.isFromMockProvider
    _telemetry.mockDetected++;
    return false;
  }
  if (p.accuracy > 35) return false;     // urban canyon / indoor drift
  if (p.speed > 8.0) return false;       // vehicle
  if (p.timestamp.isAfter(DateTime.now().add(Duration(minutes: 1))))
    return false;                        // clock tampering

  // Kalman-lite: reject a fix implying an impossible jump from the last one
  if (_last != null) {
    final d  = haversine(_last!, p);
    final dt = p.timestamp.difference(_last!.timestamp).inSeconds;
    if (dt > 0 && d / dt > 12.0) return false;
  }
  return true;
}
```

Also check on Android:
```dart
final devMode = await SafeDevice.isDevelopmentModeEnable;
final rooted  = await SafeDevice.isJailBroken;
// Don't block — flag it. Send as a header, let the server weight it.
```

On iOS, `CLLocation` has no mock flag. Use coherence instead: real GPS has
characteristic accuracy jitter and non-zero `speedAccuracy`; `.gpx` simulation
produces suspiciously perfect straight lines with constant speed. Track the
**variance of heading and speed** — a real human walk has σ(speed) > 0.15 m/s.

---

## 3. Layer 2 — Server-Side Rules (the real defence)

Implemented in `validate_cell_claim()`. Each rule maps to a threat:

| Rule | Check | Kills |
|---|---|---|
| R1 | `cell_id` well-formed, 15–16 chars | Malformed injection |
| R2 | steps ≥120 **AND** dist ≥80 m **AND** dwell ≥90 s **AND** fixes ≥5 | T1, T2 |
| R3 | `mean_accuracy_m ≤ 35` | Indoor/spoof noise |
| R4 | `max_speed_mps ≤ 8` | T2 (driving) |
| R5 | `dwell ≤ wall_clock × 1.05`; window not future, not >48 h old | T7 (replay) |
| R6 | `0.30 ≤ distance/steps ≤ 1.60` m per step | T1 (shake), T3/T4 (spoof drift) |
| R7 | `distance/dwell ≤ 8 m/s` | Fabricated distance |
| R8 | `steps/dwell ≤ 3.5` per second | T1 (shake) |
| R9 | Consecutive cells: no >15 m/s implied hop over >300 m | T3, T4 (teleport) |

### Why the ratio rule (R6) is the strongest single check

A human walking stride is 0.4–1.2 m. Attacks break this in both directions:

```
Shake the phone:    2000 steps,   5 m distance  → ratio 0.0025  ✗ REJECTED
Sit still, spoof:      0 steps, 800 m distance  → ratio ∞       ✗ REJECTED
Drive with phone:    150 steps, 900 m distance  → ratio 6.0     ✗ REJECTED
Genuine walk:        400 steps, 310 m distance  → ratio 0.78    ✓ ACCEPTED
```

To beat R6 an attacker must fake steps *and* distance *and* dwell *and* fix count
in a mutually consistent way, and keep it consistent across adjacent cells (R9).
At that point they've written a walking simulator — which is fine, honestly.
That's the 1% you handle with behavioural analysis, not rules.

### If `h3-pg` is available — enable these two

They're commented out in `02_CLAIM_ENGINE.sql` and are worth turning on:

```sql
-- Verify the client's cell_id actually corresponds to the lat/lng it sent.
-- Stops an attacker submitting a real walk's telemetry against a DIFFERENT cell.
h3_lat_lng_to_cell(point(lng, lat), 9)::text = cell_id

-- Verify the path is contiguous in hex space.
h3_grid_distance(prev_cell::h3index, cell::h3index) <= 3
```

The first one is important: without it, an attacker can do one legitimate walk
and then re-submit that same telemetry against every cell in the city. R9's
haversine check catches the crude version (because the lat/lng would also have to
move), but the h3-pg check closes it completely.

Check availability first:
```sql
select * from pg_available_extensions where name like 'h3%';
```
If it's absent, an acceptable substitute is to store the `center` geography and
verify submitted lat/lng falls within ~200 m of the previously-recorded centroid
for that cell — imperfect, but it catches bulk replay.

---

## 4. Layer 3 — Behavioural Scoring (catches the sophisticated 1%)

Rules catch mechanical cheats. Patterns catch bots. Run this as a nightly
`pg_cron` job over `claim_events`:

```sql
create or replace function public.score_suspicion()
returns void language plpgsql security definer set search_path = public as $$
begin
  with signals as (
    select
      user_id,
      -- S1: high rejection rate = probing the validator
      (count(*) filter (where outcome='rejected'))::numeric
        / greatest(count(*),1)                                as reject_rate,
      -- S2: robotic consistency. Humans vary; bots don't.
      coalesce(stddev_pop(effort),0) / greatest(avg(effort),1) as effort_cv,
      -- S3: activity at implausible hours, every day
      count(*) filter (where extract(hour from created_at) between 2 and 5)
        ::numeric / greatest(count(*),1)                      as night_ratio,
      -- S4: no rest days
      count(distinct date_trunc('day', created_at))           as active_days,
      count(*)                                                as total_events,
      -- S5: perfect GPS accuracy is a spoofer tell (real GPS jitters)
      coalesce(stddev_pop(mean_accuracy_m),0)                 as acc_stddev,
      -- S6: sustained cell acquisition rate
      max(cells_per_hour)                                     as peak_rate
    from (
      select ce.*,
             count(*) over (partition by user_id,
                            date_trunc('hour', created_at)) as cells_per_hour
      from public.claim_events ce
      where created_at > now() - interval '14 days'
    ) x
    group by user_id
    having count(*) > 20
  )
  update public.profiles p
     set suspicion_score = least(100,
           (case when s.reject_rate  > 0.35 then 25 else 0 end) +
           (case when s.effort_cv    < 0.05 then 30 else 0 end) +
           (case when s.night_ratio  > 0.40 then 15 else 0 end) +
           (case when s.acc_stddev   < 0.5  then 20 else 0 end) +
           (case when s.peak_rate    > 35   then 20 else 0 end) +
           (case when s.total_events::numeric / greatest(s.active_days,1) > 120
                 then 15 else 0 end))
    from signals s
   where p.id = s.user_id;
end $$;

select cron.schedule('score-suspicion', '45 4 * * *',
  $$ select public.score_suspicion(); $$);
```

**Response ladder — never insta-ban:**

| Score | Action | Visible to user? |
|---|---|---|
| 0–29 | Nothing | — |
| 30–49 | Log + tighten their rate limit to 20 cells/hr | No |
| 50–74 | Manual review queue; claims still land | No |
| 75–89 | **Shadow ban** — RPC returns success, writes nothing | No |
| 90–100 | Exclude from leaderboards, flag for `admin_rollback_user` | Yes, on appeal |

Shadow banning is the right tool here. A cheater who knows they're banned makes a
new account in 30 seconds. A cheater who thinks they're winning while invisible
to everyone else wastes weeks and stops on their own. Keep an appeals path —
false positives will happen (a user on a train, a rural user with terrible GPS).

---

## 5. Layer 4 — Structural Deterrents

These are game-design choices that reduce the *value* of cheating:

1. **Decay makes cheating a chore, not a win.** A cheater who claims 5,000 hexes
   in one night watches them all decay in 3 weeks unless they keep cheating.
   Half-life decay is quietly the best anti-cheat mechanic you have.
2. **Local leaderboards.** A global leaderboard is a magnet for cheaters. A res-5
   neighbourhood leaderboard, where your rival is someone you might physically
   meet, is socially self-policing.
3. **Rate caps.** 50 cells/hour, 200/day. A genuine 10 km walk at res 9 touches
   ~30–50 cells. The cap costs honest players nothing and caps damage.
4. **No trading, no transfers.** The moment territory has transferable value you
   have created a market, and markets attract industrial cheating.
5. **Report button.** Cheap, effective. Route reports into the same review queue
   as high suspicion scores. Weight a report from a high-reputation local player
   heavily.

---

## 6. What NOT To Do

- **Don't rely on client-side integrity checks alone** (Play Integrity API /
  DeviceCheck). They're worth adding as *one signal*, but they're bypassable and
  they lock out legitimate users on rooted/de-Googled phones — a real segment.
- **Don't ban on a single event.** GPS genuinely teleports you 2 km inside a mall.
  Trains genuinely produce 30 m/s walks. Always score over a window.
- **Don't store raw GPS tracks to catch cheaters.** It's a privacy liability far
  larger than the cheating problem, and it will blow your 500 MB budget. The
  aggregates in `claim_events` are enough.
- **Don't publicise your thresholds.** Everything in this file stays internal.
  Publish only "we detect and reverse cheating."

---

## 7. Verification Suite (Phase 4 acceptance)

Write these as pgTAP tests or plain SQL fixtures. Each must reject:

```sql
-- shake attack
select validate_cell_claim('{"cell_id":"8928308280fffff","steps":2000,
  "distance_m":5,"dwell_s":600,"fix_count":50,"mean_accuracy_m":8,
  "max_speed_mps":0.2,"window_start":"...","window_end":"..."}'::jsonb);
-- expect: 'steps_without_distance'

-- drive-by
-- expect: 'implausible_speed'

-- replay of a 3-day-old walk
-- expect: 'stale_window'

-- dwell inflation (claims 2h dwell in a 5min window)
-- expect: 'dwell_exceeds_window'

-- teleport (Abbottabad -> Karachi in 60s)
-- expect: 'teleport_between_cells'
```

And one that must **accept**: a real 400-step, 310 m, 7-minute walk with 80 fixes
at 9 m accuracy. Capture a genuine track from your own phone during Phase 1 and
freeze it as the golden fixture — it's the regression test that stops you from
tightening rules until real users get rejected.
