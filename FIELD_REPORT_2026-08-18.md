# Field report — first real walk (Abbottabad)

**Date:** 2026-08-18  
**Tester:** Nemat Ullah  
**Build:** `v0.1.0+1` (dump header). Screenshots match that overlay (no `raw gps` row).  
**Phone:** Android, 5000 mAh. Location near Murree Road / S-5 / Irrigation Canal.  
**Walk:** ~500 m, ~8–12 minutes, screen on, app in foreground.  
**Cell the whole time:** `89209a0aa73ffff` (H3 res 9 — never left the hex *as the phone reported it*).

This is the first hardware data for thresholds 0.1 / 0.2 / 1.1–1.5 / 1.7 / 4.2.
It is **not** a golden track yet — the GPS never left the Wi‑Fi lock.

---

## What the tester saw

1. Map sat 100–200 m from the real position for most of the walk.
2. First two screenshots looked “somewhat accurate” **because they were still in home Wi‑Fi range**.
3. After leaving Wi‑Fi (cellular only), the blue dot froze. Accuracy inflated 42 m → 200–300 m; lat/lng did not move.
4. **When back on Wi‑Fi, the dot jumped to the real location.** Confirms network/Wi‑Fi positioning, not a satellite lock.
5. Steps counted. Distance stayed **0.0 m**. No hex claimed.
6. Battery: **~2 % in 12 min** screen-on (68–69 %). Pedometer hardware worked.

How stats were recorded: overlay **copy** icon → paste. That is the right method. Keep doing that.

---

## Timeline (from screenshots + dump)

| Elapsed | Motion | Steps (HUD / pedo) | Dist | Dwell | Fixes | GPS acc | Accepted | Poor acc | Notes |
|---|---|---|---|---|---|---|---|---|---|
| 02:00 | running | 29 / 75 | 0.0 | 0 s | 1/5 | **42.4 m** | 1 | 3 | Near Wi‑Fi. Hex drawn. Closest to truth. |
| 03:52 | running | 251 / 297 | 0.0 | 23 s | 2/5 | **47.3 m** | 2 | 4 | Still same cell. Second accepted fix. |
| 07:00 | stationary | 600 / 646 | 0.0 | 23 s | 2/5 | **300.0 m** | 2 | 9 | Away from Wi‑Fi. Acc exploded, no new accepts. |
| 08:40 | running | 764 / 810 | 0.0 | 23 s | 2/5 | **200.0 m** | 2 | 14 | Dump below. Still same cell, same 23 s dwell. |

Final dump:

```
Terrastep debug  v0.1.0+1
elapsed 08:40   battery 68%
cell 89209a0aa73ffff
steps 764 / 120
distance 0.0 m / 80
dwell 23 s / 90
fixes 2 / 5
m/step 0.00
gps acc 200.0 m
accepted 2
pedometer ok (810)
motion running
territory 0 hexes
rejected:
  poor acc 14
```

---

## Diagnosis

### A. The 35 m accuracy gate is too tight for this phone *(why distance is 0)*

`GameConfig.maxAccuracyM = 35`. Every fix worse than 35 m is discarded (`poor acc`).

Best lock on this walk was **42–47 m** — already over the gate. Only **2 of 16** fixes were accepted, and those two were ~23 s apart in the same Wi‑Fi lock (dwell stuck at 23 s). The displacement-anchor then needs `2 × accuracy ≈ 94 m` of *reported* movement. Two nearby Wi‑Fi fixes never provide that, so **distance stays 0** even after 810 real steps.

`m/step = 0.00` follows automatically. The server would reject this visit as `steps_without_distance`.

This is exactly the question CURRENT_PROGRESS asked: *“if gps acc is routinely >35 m, the gate is too strict.”* It is.

### B. The phone was using Wi‑Fi / network location, not GPS satellites *(why the map froze)*

Classic Android behaviour:

- On home Wi‑Fi: fused location returns a Wi‑Fi scan result, ~40 m, roughly right.
- Leave Wi‑Fi: the **same lat/lng is re-emitted** with a decaying accuracy (47 → 200 → 300). The OS has no new measurement.
- Re-enter Wi‑Fi: a new scan → the dot **snaps** to the real position.

That matches the tester’s addendum exactly. Cellular data being “slow” was not the map-tile problem — the **coordinate itself was stale**. Tiles can load over mobile data; the blue dot cannot invent a GNSS fix.

A 500 m walk should cross ~2–3 res-9 hexes. Staying on `89209a0aa73ffff` the whole time is the frozen lock, not a small loop.

### C. Pedometer is fine

810 hardware steps for a claimed ~500 m walk ≈ 0.62 m/step, inside the server’s 0.30–1.60 band. Steps are not the bug.

### D. Battery (screen on, worst case)

2 % / 12 min ⇒ **~10 %/hour** screen-on, 5000 mAh.

That is expected with the map + GPS + screen lit. Threshold 0.3 / 1.8 is **screen off, pocket, <4 %/hr**. We cannot score that until the foreground service (O11) exists. Not a red flag yet.

---

## What we will change (v0.1.2)

| Change | Why |
|---|---|
| Client accuracy gate **35 m → 80 m** (app only; server SQL stays 35 until we decide) | 42–47 m is a *good* lock on this hardware |
| `LocationAccuracy.bestForNavigation` + retry via LocationManager if acc stays >50 m | Push the OS toward the GPS chip, not Wi‑Fi |
| Overlay banner when acc > 50 m | “Wi‑Fi / network lock — enable Location → High accuracy (GPS)” |
| Keep copy-to-clipboard as the official record method | Already worked |

---

## How to record the next walk

1. Uninstall the old APK, install the new one.
2. Before walking: **Settings → Location → High accuracy / GPS + Wi‑Fi + mobile** (wording varies by OEM).
3. Start outside, wait until `gps acc` is a number and ideally < 80 m.
4. Walk. After, tap the **copy** icon on the overlay and paste (same as this report).
5. Note: were you on Wi‑Fi, cellular, or both?

A hex still needs **120 steps AND 80 m AND 90 s AND 5 accepted fixes**. Numbers should move long before a claim.

---

## Walk 2 — same day, later

**Build string in dump:** still `v0.1.0+1` (that label was hardcoded until v0.1.2).  
**Elapsed:** 04:27 · **Battery:** 65 % (~1 % drop this session)

```
Terrastep debug  v0.1.0+1
elapsed 04:27   battery 65%
cell 89209a0aa73ffff
steps 412 / 120
distance 64.1 m / 80
dwell 224 s / 90
fixes 5 / 5
m/step 0.16
gps acc 24.5 m
accepted 5
pedometer ok (412)
motion running
territory 0 hexes
rejected:
  poor acc 6
```

| Floor | Need | Got | |
|---|---|---|---|
| Steps | 120 | **412** | ✅ |
| Distance | 80 m | **64.1 m** | ❌ 16 m short |
| Dwell | 90 s | **224 s** | ✅ |
| Fixes | 5 | **5** | ✅ |
| GPS acc | ≤35 m to accept | **24.5 m** | ✅ real satellite lock |
| Hex claimed | — | 0 | ❌ because distance < 80 |

### Verdict

**The sensors work. A hex did not fill, by 16 metres.**

This is a different walk from the first one:

- Accuracy **24.5 m** (was 42–300 m). That is a GNSS lock, not a Wi‑Fi guess.
- Distance **moved** (was stuck at 0.0).
- Pedometer still matches the HUD (412 = 412).
- Same home cell `89209a0aa73ffff` — either a loop near home, or the phone is still sticky to that hex.
- `m/step = 0.16` is below the server’s 0.30–1.60 band. 412 steps for 64 m credited means the displacement-anchor is only counting *net* movement. A back-and-forth or small loop is supposed to look like this. A straight block would push distance over 80 and lift m/step.
- Battery ~1 % / 4.5 min screen-on ≈ 13 %/hr. Same order as walk 1. Still not the pocket test.

**Success for:** 0.1 / 0.2 / 1.2 / 1.5 (sensors + hex drawn + steps).  
**Not yet:** 1.7 (claim + persist) — need `distance ≥ 80`.

Next walk: one straight block from the house, screen on, until the metres counter crosses 80. Then copy again. If the hex fills, force-quit and reopen — that is 1.7.
