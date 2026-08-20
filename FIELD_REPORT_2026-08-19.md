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

---

## 2026-08-20 — 2.8 (v0.1.7+8)

Dump after a signed-in walk (SQL patch applied):

```
Terrastep debug  0.1.7+8
auth khannmat12@gmail.com · walker_cda70d49
elapsed 03:04   battery 71%
cell 89209a0aa73ffff
steps 24 / 120
distance 19.5 m / 80
dwell 7 s / 90
fixes 16 / 5
m/step 0.81
gps acc 3.3 m
raw gps 176
accepted 175
pedometer ok (252)
error none
fgs on
gps src fused
last fix now
motion walking
territory 1 hexes
sync ok claimed
rejected:
  poor acc 1
```

Server row: `89209a0aa73ffff` owner `cda70d49-…` / `walker_cda70d49`.

**Uninstall → reinstall → magic link → hex still there.** 2.8 ✅

`profiles.cells_owned` still 0 — trigger bug, not blocking the map.

---

## 2026-08-20 — 2.9 (v0.1.10+11)

On device: hex named **Home**, colour can be changed. Territory still on the account after reinstall. Save crash fixed on this build.

**Phase 2 player loop ✅** (claim, cloud, restore, name/colour).

### Server snapshot 2026-08-20 (REST)

| Hex | Name | Colour | Influence |
|---|---|---|---|
| `89209a0aa73ffff` | Home | `#06b6d4` cyan | 1587.50 |
| `89209a0aa0fffff` | T1 | `#ef4444` red | 214.90 |

Owner `walker_cda70d49`. `profiles.cells_owned` still 0.
