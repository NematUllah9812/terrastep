# Field report — 2026-08-19 (Phase 2 login)

**Build:** v0.1.6+7 (auth line proves it; v0.1.4+5 had no `auth`)  
**Phone:** same Abbottabad device. Home hex `89209a0aa73ffff`.  
**Screenshot:** 20:14 local.

## Overlay (not a copy-dump; HUD + screenshot)

```
cell        89209a0aa73ffff
steps       195 / 120
distance    121.4 m / 80
dwell       68 s / 90          ← 22 s short of a new claim
fixes       116 / 5
m/step      0.62
gps acc     3.7 m
raw gps     273
accepted    272
last fix    now
pedometer   ok (405)
fgs         on
gps src     fused
territory   1 hexes            ← local SharedPreferences
auth        khannmat12@gmail.com
battery     37%
elapsed     04:39
error       none
rejected    poor acc 1
```

## Verdicts

| Check | Result |
|---|---|
| Magic link | ✅ Signed in as `khannmat12@gmail.com` |
| Auth users | ✅ **One** row for that email — not minting duplicates |
| Restart | ✅ Still logged in (session persist) |
| Sign out | ❌ No button on v0.1.6+7 — not missing, not built |
| Uninstall → same email | ✅ Same Auth user |
| Uninstall → hexes gone | **Expected.** Claims were phone-only. Server `territories` empty. 2.6/2.8 not live yet. |
| Tracking | ✅ FGS on, 1 Hz, 3.7 m, fused |

Same UID does **not** restore hexes until we upload `claim_cells` and draw `get_cells_in_view`. That is the next APK (v0.1.7+8): Sign out + first upload/hydrate.
