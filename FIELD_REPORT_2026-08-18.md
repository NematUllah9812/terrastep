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

---

## Walk 3 — cellular only (same day, ~15:05–15:12)

**Network:** cellular only, no Wi‑Fi. Tester said the pin looked somewhat accurate.  
**Build string:** still `v0.1.0+1` → **this is the old 35 m gate.** v0.1.2 (80 m gate) was never installed.  
**Cell the whole time:** `89209a0aa73ffff`  
**Battery:** 64 % → 63 % over ~7 min (screen on).

| # | Time | Elapsed | Steps | Dist | Dwell | Fixes | Acc | Accepted | Poor | Motion |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 15:05 | 01:17 | 20 | 0.0 | 0 | 1/5 | **32.1 m** | 1 | 0 | stationary |
| 2 | 15:06 | 02:02 | 64 | 0.0 | **109** | 2/5 | **25.0 m** | 2 | 0 | stationary |
| 3 | 15:06 | 02:31 | 115 | 0.0 | 109 | 2/5 | 52.4 m | 2 | 1 | walking |
| 4 | 15:08 | 03:35 | 222 | 0.0 | 109 | 2/5 | 41.0 m | 2 | 7 | running |
| — | shot | 03:57 | 250 | 0.0 | 109 | 2/5 | 87.6 m | 2 | 9 | running |
| — | shot | 04:54 | 350 | 0.0 | 109 | 2/5 | 60.0 m | 2 | 13 | running |
| 5 | 15:09 | 04:44 | 327 | 0.0 | 109 | 2/5 | 43.9 m | 2 | 12 | running |
| — | shot | 05:45 | 431 | 0.0 | 109 | 3/5 | **22.5 m** | 3 | 13 | running |
| 6 | 15:10 | 06:04 | 462 | 0.0 | 109 | 3/5 | 36.5 m | 3 | 14 | running |
| — | shot | 06:24 | 490 | 0.0 | 109 | 3/5 | 36.5 m | 3 | 14 | running |
| 7 | 15:11 | 07:23 | 566 | 0.0 | 109 | 4/5 | **23.9 m** | 4 | 15 + too fast 1 | running |
| — | shot | 07:40 | 578 | 0.0 | 109 | 4/5 | **23.9 m** | 4 | 15 + too fast 1 | running |

Raw dumps 1–7 as sent (verbatim) are in the chat log; the table is the same numbers.

### Verdict

**Distance stayed 0 because this APK still uses the 35 m gate, and most of the walk sat at 36–87 m.**

Proof it is the old build, not “cellular is broken”:

- Acc 41.0, 43.9, 52.4, 60.0, 87.6 → all rejected as `poor acc`. On **v0.1.2 those would have been accepted** (gate is 80 m).
- The two early accepts (32.1 m and 25.0 m) were ~109 s apart in the same cell. Displacement-anchor needs ~50–64 m of *reported* movement between them. They were closer than that, so distance stayed 0 and dwell froze at 109 s.
- Later accepts (#3, #4) arrived **more than 120 s** after the previous accept, so the gap rule credits neither dwell nor distance. Dwell stuck at 109 s from dump 2 to the end.
- One `too fast` reset the track (`speed > 8 m/s`) — a GPS jump, not a vehicle. That wipes the anchor.
- Pin “somewhat accurate” on cellular is real progress vs walk 1 (frozen Wi‑Fi lock). The hex never changed because accepted fixes never left `89209a0aa73ffff`.

Battery: ~1 % / 7 min screen-on. Same story as walks 1–2.

**Next is not another walk on this APK.** Uninstall it. Install **v0.1.2+3** from `releases/terrastep-debug.apk`. Confirm the dump header says `v0.1.2+3` before walking. Then one straight block.

---

## Walk 4 — first claim (v0.1.2+3, brother walking)

**Build:** `v0.1.2+3` (dump header confirms the new APK).  
**Who:** tester’s brother.  
**Result:** **territory 1 hex.** Hex `89209a0aa73ffff` filled blue.

Dump (after the claim — counters are the *next* visit in the same hex):

```
Terrastep debug  v0.1.2+3
elapsed 09:16   battery 59%
cell 89209a0aa73ffff
steps 99 / 120
distance 39.4 m / 80
dwell 21 s / 90
fixes 41 / 5
m/step 0.40
gps acc 3.4 m
raw gps 512
accepted 512
pedometer ok (904)
error none
motion stationary
territory 1 hexes
```

Screenshot ~09:58: steps 110, dist 39.4, dwell 54, fixes 51, acc 24.5 m, raw/accepted 522, pedometer 915, **territory 1**, hex drawn blue. No rejected-fix section.

### What this proves

| Signal | Walk 3 (old APK) | Walk 4 (v0.1.2) |
|---|---|---|
| Dump version | v0.1.0+1 | **v0.1.2+3** |
| Acc gate | 35 m | **80 m** |
| raw / accepted | ~4 accepted, 15 rejects | **512 / 512** (every fix kept) |
| Best acc | 22–32 m, then 36–87 rejected | **3.4 m** (then 24.5 m) |
| Distance | 0.0 | **claimed, then 39.4 m into the next visit** |
| m/step | 0.00 | **0.36–0.40** (inside 0.30–1.60) |
| Hexes | 0 | **1** |

`markSubmitted` clears the visit that paid for the claim, so the HUD after a fill is a *fresh* visit. That is why steps show 99/110 after a successful claim while the pedometer is at 904/915 — the other ~800 steps were in the visit that filled the hex.

512 accepts in ~9 min ≈ 1 Hz. The 1 Hz unfiltered stream (#28) is doing what it should. Zero `poor acc` on this dump: the 80 m gate plus a real GNSS lock.

Battery 59 % at 09:16 (screenshot 58 % at 09:58). Screen-on, same order as before.

### Persist (same evening)

Tester force-quit and reopened **multiple times**. Hex stayed blue.
**Threshold 1.7 is done** (claim + persist). Storage is SharedPreferences,
not SQLite — good enough for Phase 1.

### Still open

- **1.8 / 0.3 pocket battery:** needs the foreground service (O11).
- Claim in a *second* hex (walk out of `89209a0aa73ffff`).

---

## Running score

| Walk | APK | Dist | Claim |
|---|---|---|---|
| 1 | 0.1.0 | 0 (Wi‑Fi lock) | no |
| 2 | 0.1.0 | 64.1 / 80 | no (16 m short) |
| 3 | 0.1.0 | 0 (35 m gate on cellular) | no |
| **4** | **0.1.2+3** | claimed, then 39.4 into next | **yes** |
| **5** | **0.1.2+3** | 3 hexes, screen mostly off | **yes + 2 more** |
| **6** | **0.1.3+4** | prayer / pocket 23 min | **tracking died** |

---

## Walk 6 — prayer, pocket, screen off (~18:51–19:14)

**Build:** fresh v0.1.3+4 install (territory 0 — uninstall wipes local claims).  
**What:** phone in pocket, went to pray, came back. ~23 minutes.

| Time | Elapsed | Steps | Dist | Dwell | Fixes | Acc | raw/acc | Pedo | Terr | Batt |
|---|---|---|---|---|---|---|---|---|---|---|
| 18:51 | 00:13 | 0 | 0.0 | 11 | 7/5 | 41.8 | 8/7 | 0 | 0 | 37% |
| 19:14 | **22:59** | **0** | **0.0** | **28** | 11/5 | 21.6 | **12/11** | **0** | 0 | 37% |

If 1 Hz tracking had stayed alive: ~1,380 raw fixes, hundreds of steps, dwell near 23 min.

What we got: **12 GPS samples in 23 minutes**, **0 pedometer steps**, dwell 28 s (gaps > 120 s credit nothing), battery unchanged at 37 %.

### Verdict

**Threshold 1.8 / 0.3 cannot pass on this APK.** Android froze the app in the pocket. Walk 5 sometimes survived because the process was still warm and the screen was peeked. A real leave-the-house / pray / come-back cycle kills sensors.

This is the evidence for O11, not a failed walk. **v0.1.4+5** ships the
foreground service. Repeat this exact test as **Walk 7**:

1. Uninstall v0.1.3. Install `releases/terrastep-debug.apk`.
2. Dump first line must say `v0.1.4+5`. Overlay `fgs` must say `on`.
3. Shade must show *Terrastep is tracking*.
4. Pocket, screen off, ~20–30 min. Unlock, copy overlay.
5. Pass: `raw gps` in the hundreds, pedometer &gt; 0 if you walked,
   `last fix` recent. Record battery start/end. Target &lt;4 %/hr.

---

## Walk 5 — pocket / screen-off, multi-hex (same evening)

**Build:** v0.1.2+3 (raw gps row present).  
**Screen:** mostly off, phone in pocket. Tester stood still in between.  
**Started** with territory 1 (persisted home hex). **Ended** with **3 hexes**.

| Time | Elapsed | Cell | Steps | Dist | Dwell | Fixes | Acc | raw/acc | Pedo | Terr | Notes |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 17:12 | 00:51 | `…aa73ffff` home | 19 | 0.0 | 44 | 14 | 23.2 | 14/14 | 19 | 1 | Standing. Dist 0. Map shows Dhamtour. |
| 17:23 | 11:40 | `…aa0fffff` **new** | 143 | **89.7** | 18 | 18 | 7.9 | 69/67 | 483 | 1 | Stadium Rd. m/step **0.63**. 1 poor + 1 teleport. Not claimed (dwell 18). |
| 17:27 | 16:10 | `…aa77ffff` **new** | 139 | **109.8** | 35 | 74 | 3.0 | 322/320 | 975 | **2** | Garipana Rd. m/step **0.79**. |
| 17:32 | 21:16 | `…aa73ffff` home | 61 | 48.4 | 17 | 32 | 3.6 | 454/451 | 1536 | **3** | Back at Murree Rd. |

Battery 47 % → 44 % over ~20 min mixed screen ≈ **9 %/hr**. Better than full screen-on (~10–13 %). Not an official 1.8 pocket test (screen was peeked for screenshots; no FGS).

### What worked

- Left the home hex. Two new cells (`aa0fffff`, `aa77ffff`). The grid is real.
- Distance and m/step look like walking (0.63–0.79), not the 0.00 of walks 1/3.
- 451/454 accepts, acc 3–8 m. GNSS lock held on a real walk.
- Standing still (17:12): dwell 44 s, distance **0.0**. Correct — standing should count toward the 90 s dwell floor, never toward metres.
- Informal screen-off tracking: hexes still filled. Android kept the app alive this time; that is **not** guaranteed without a foreground service.

### Bugs the tester caught (fixed in v0.1.3)

1. **Same hex claimed over and over.** After a claim, `markSubmitted` deletes the visit. The next 120 steps + 80 m in the same cell fire another “Territory claimed” snackbar. Phase 1 should reinforce silently if you already own it.
2. **Effort / steps from the last hex showing up on the next one.** After a claim, delayed pedometer batches stamped during the old visit have no window left, so they were dumped on the *current* cell. A new hex could open at 140 steps / 90 m with only 18 s of dwell. Orphan steps now drop unless they belong after the new visit started.

One `teleport` reject is expected if the first lock after a car/ride jumps several km (Dhamtour vs home).

---

## Walk 7 — prayer, pocket, FGS (~20:43–21:05)

**Build:** v0.1.4+5. Same trip as Walk 6.

| Time | Elapsed | raw/acc | Pedo | Terr | Batt | Notes |
|---|---|---|---|---|---|---|
| 20:43 | 00:32 | 28/28 | 0 | 0 | 24% | fgs on, acc 6.7 m |
| 21:05 | **21:47** | **1289/1284** | **765** | **1** | 21% | claimed home hex, m/step 0.66, teleport 5 |

**Tracking: PASS.** Walk 6 was 12 GPS / 0 steps. This is ~1 Hz, claim, last fix now.

**Battery ~8.5 %/hr** — over the 4 % target. **Deferred (O12).** v0.1.5 idle-sampling was tried then **rolled back 2026-08-19**. Current ship is v0.1.4+5.
