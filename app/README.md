# Terrastep — Android App

Flutter app. **The game logic is not here** — it lives in
[`../packages/terrastep_core`](../packages/terrastep_core), which is pure Dart
with no Flutter dependency so it can be tested in CI without an emulator.

This package is the shell: sensors, map, UI.

---

## Getting the APK on your phone

**You do not need Flutter installed.** Every push builds an APK on GitHub's
runners.

1. Open the repo → **Actions** tab (works in the GitHub mobile app)
2. Newest **Build Android APK** run
3. Scroll to **Artifacts** → tap **terrastep-debug-apk** → downloads a `.zip`
4. Unzip, tap the `.apk`, allow *install from unknown sources*

You can also trigger a build by hand: Actions → Build Android APK → **Run
workflow**.

> Debug build, so it is unsigned and larger than a release build. Fine for
> testing; not for the Play Store.

---

## What this first build does

Phase 1 is **offline by design** — no account, no server, no Supabase. The point
is to answer the two questions that only real hardware can:

1. **Does a hex fill when you walk your block?**
2. **What does it cost in battery?**

Features:
- OpenStreetMap tiles + your live position
- Real H3 res-9 hexagons drawn around you (2 rings)
- Walk to claim: 120 steps **and** 80 m **and** 90 s **and** 5 GPS fixes
- Claimed hexes persist across app restarts
- **Debug overlay** — the most important part. Live steps, distance, dwell,
  GPS accuracy, motion state, and a count of every rejected fix by reason.

### What to report back

Screenshot the debug overlay during a walk, and note:

| Question | Why it matters |
|---|---|
| Did a hex fill after ~120 steps? | Confirms the core loop on real GPS |
| `m/step` value while walking | Server rejects outside 0.30–1.60 (rule R6) |
| `gps acc` typical value | If routinely >35 m, the accuracy gate is too strict |
| Rejected-fix counts | Non-zero `poor acc` or `teleport` means filter tuning |
| `pedometer` says ok or NO SENSOR | Some devices lack a step counter |
| **Battery % over 30 min, screen off** | **Threshold 0.3 go/no-go. Target <4%/hr** |

---

## Structure

```
lib/
├── main.dart                     permission flow -> MapScreen
├── services/
│   ├── h3_indexer.dart           real H3 (implements core's CellIndexer)
│   ├── location_service.dart     adaptive GPS sampling
│   ├── step_service.dart         pedometer deltas
│   └── tracking_coordinator.dart wires sensors -> accumulator -> UI
└── ui/
    ├── map/map_screen.dart       map, hex layer, position
    └── widgets/
        ├── debug_overlay.dart    live sensor readout
        └── progress_card.dart    claim progress
```

### `android/` is not committed

`flutter create --platforms=android` regenerates it during the build, and
`scripts/patch_android_manifest.sh` injects the permissions afterwards. The
generated folder is large, mostly boilerplate, and churns noisily across Flutter
versions — so it is rebuilt rather than stored. **Permission changes go in the
patch script, not in a manifest file.**

---

## Building locally (optional)

```bash
cd app
flutter create --platforms=android --org io.terrastep --project-name terrastep .
bash ../scripts/patch_android_manifest.sh
flutter pub get
flutter build apk --debug
# -> build/app/outputs/flutter-apk/app-debug.apk
```

---

## The one rule

**Never import `package:flutter` into `packages/terrastep_core`.** That package
holds the claim, contest and decay logic, and it stays testable under
`dart test` — no emulator, no device — precisely because it has no Flutter
dependency. That is what let the GPS-drift exploit (`ISSUES_LOG #17`) be caught
in a unit test rather than in the field.

Plugin-dependent code belongs here in `app/lib/services`. The `CellIndexer`
interface is the pattern: the accumulator depends on the abstraction, and
`H3Indexer` supplies the native implementation.
