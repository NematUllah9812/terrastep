# Terrastep — Client

Flutter app. **`lib/core` and `lib/domain` are pure Dart** with no Flutter or
plugin dependencies, so the game logic runs under `dart test` in CI with no
emulator, no device and no Flutter SDK.

That split is deliberate: the accumulator is the most bug-prone part of the
client, and it is where a GPS-drift exploit was already caught (`ISSUES_LOG #17`).

---

## Run the tests (no Flutter needed)

```bash
cd app
dart pub get
dart test        # 27 tests
dart analyze     # must be clean
```

---

## What exists

```
lib/
├── core/
│   └── game_config.dart          Balance constants + effort/decay maths.
│                                 Mirrors the game_config table.
└── domain/
    ├── models/
    │   ├── geo.dart              GeoFix + haversine (mirrors haversine_m())
    │   └── cell_visit.dart       Per-cell accumulator record + RPC payload
    └── session_accumulator.dart  ★ The heart. GPS + steps -> claimable visits.

test/
├── session_accumulator_test.dart  The 6 tests threshold 1.6 mandates,
│                                  plus quality-gate and golden-path tests
└── game_config_test.dart          Parity with the verified SQL suite

tool/
├── tune.dart      Measures anti-drift filter parameters
└── verify.dart    Prints real-world scenario outcomes
```

### Verified behaviour

`dart run tool/verify.dart`:

| Scenario | Credited distance | Claimable |
|---|---|---|
| Genuine 10-min walk (810 m actual) | 789 m (97%) | 4 cells ✅ |
| Standing still, 28 m GPS accuracy | 0.0 m | 0 ✅ |
| Shaking the phone, 3025 fake steps | 0.0 m | 0 ✅ |

---

## Two invariants — don't break these

**1. `lib/core` and `lib/domain` must stay Flutter-free.** No `package:flutter`
imports, no plugins. If they creep in, `dart test` stops working and the logic
becomes untestable without a device. Plugin-dependent code belongs in
`lib/services` and `lib/ui`.

**2. Client constants must match the SQL.** `game_config.dart` mirrors the
`game_config` table, and `computeEffort` / `currentInfluence` mirror
`compute_effort()` / `current_influence()`. `test/game_config_test.dart` asserts
the exact values from the SQL suite (529.50, the 395 takeover bar, the 7-day
half-life). **Changing a constant means changing both, in the same commit** —
otherwise players see claims silently rejected by the server.

---

## Finishing the scaffold (threshold 1.1, needs Flutter)

The pure-Dart core is done and tested. To turn it into a running app:

```bash
# 1. Generate the platform shells around the existing lib/
flutter create --org io.terrastep --project-name terrastep \
       --platforms android,ios .

# 2. Uncomment the Flutter dependency block in pubspec.yaml
flutter pub get
```

Then work through `06_MILESTONE_CHECKLIST.md` in order. The pieces to write:

| File | Threshold | Notes |
|---|---|---|
| `lib/services/h3_indexer.dart` | 1.3 | Implement `CellIndexer` with `h3_flutter`. The interface already exists — swap the fake for the real binding. |
| `lib/ui/map/map_screen.dart` | 1.1, 1.4 | MapLibre + the GeoJSON hex layer from `03_CLIENT_ARCHITECTURE.md §6` |
| `lib/services/location_service.dart` | 1.2, 1.8 | Adaptive sampling — see `§4.1`. **The battery boss fight.** |
| `lib/services/step_service.dart` | 1.5 | HealthKit / Health Connect via `health` |
| `lib/data/local/db.dart` | 1.7, 2.6 | Drift outbox |
| `lib/data/remote/claim_api.dart` | 2.5 | `rpc('claim_cells')` — payload contract already tested |

**`CellIndexer` is the seam that matters.** `SessionAccumulator` depends on the
interface, not on H3, which is why the logic is testable today. Keep it that way:
the real implementation is roughly

```dart
class H3Indexer implements CellIndexer {
  final h3 = const H3Factory().load();
  @override
  String cellFor(double lat, double lng) =>
      h3.geoToCell(GeoCoord(lat: lat, lon: lng), 9).toRadixString(16);
  @override
  String parentRes5(String cellId) =>
      h3.cellToParent(BigInt.parse(cellId, radix: 16), 5).toRadixString(16);
}
```

Verify against `h3-js` for a couple of known coordinates before trusting it
(threshold 1.3's acceptance test).
