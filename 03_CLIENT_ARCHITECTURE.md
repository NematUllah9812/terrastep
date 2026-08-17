# TERRASTEP — Client Architecture (Flutter)

## 1. Why Flutter over React Native here

Both work. Flutter wins for this specific app because:
- `h3_flutter` / `h3_dart` bind the native C library — H3 ops on a 60-cell viewport
  are sub-millisecond. The JS `h3-js` in RN goes through the bridge/WASM.
- MapLibre GL rendering a 500-polygon fill layer at 60 fps is smoother via
  `maplibre_gl` platform views than RN's map bridges.
- Isolates let you run the accumulator off the UI thread cleanly.

If your team already knows RN, use RN — the architecture below is portable. The
background-location problem is equally painful on both.

---

## 2. Package Set (all free)

```yaml
# pubspec.yaml
dependencies:
  flutter: {sdk: flutter}

  # Map
  maplibre_gl: ^0.21.0            # or mapbox_maps_flutter if using Mapbox free tier
  # Basemap: free Protomaps PMTiles, or MapTiler free tier, or OSM raster

  # Geospatial
  h3_flutter: ^0.6.0              # H3 v4 bindings
  latlong2: ^0.9.1

  # Location — pick ONE strategy
  flutter_background_geolocation: ^4.16.0   # BEST, but paid for Android release
  # OR the free combo:
  geolocator: ^13.0.0
  flutter_foreground_task: ^8.10.0

  # Steps
  health: ^11.1.0                 # HealthKit + Health Connect
  pedometer: ^4.0.2               # raw step sensor fallback

  # Backend
  supabase_flutter: ^2.8.0

  # Local persistence / outbox
  drift: ^2.20.0
  sqlite3_flutter_libs: ^0.5.24
  path_provider: ^2.1.4

  # Plumbing
  riverpod: ^2.5.1
  flutter_riverpod: ^2.5.1
  uuid: ^4.5.1
  connectivity_plus: ^6.0.5
```

> **Licensing warning.** `flutter_background_geolocation` is the most reliable
> background tracker in the ecosystem, but its Android build requires a paid
> licence for release builds (~$300 one-off). It is free for debug/iOS. For a
> genuinely zero-budget v1, use `geolocator` + `flutter_foreground_task`
> (§4.2) and accept more manual work. Budget the licence once you have users —
> it will save you weeks.

---

## 3. Project Structure

```
lib/
├── main.dart
├── core/
│   ├── config.dart              # GameConfig, fetched from game_config table
│   ├── supabase.dart
│   └── result.dart
├── domain/
│   ├── models/
│   │   ├── cell_visit.dart      # accumulator record
│   │   ├── territory.dart
│   │   └── profile.dart
│   └── session_accumulator.dart # ★ PURE DART — the heart, 100% unit-tested
├── data/
│   ├── local/
│   │   ├── db.dart              # Drift: outbox + territory cache
│   │   └── outbox_dao.dart
│   ├── remote/
│   │   ├── claim_api.dart       # rpc('claim_cells')
│   │   └── territory_api.dart   # rpc('get_cells_in_view')
│   └── sync_worker.dart         # batching, backoff, idempotency
├── services/
│   ├── location_service.dart    # background GPS
│   ├── step_service.dart        # HealthKit / Health Connect / pedometer
│   └── tracking_coordinator.dart# glues location+steps into the accumulator
└── ui/
    ├── map/
    │   ├── map_screen.dart
    │   ├── hex_layer.dart       # H3 -> GeoJSON FeatureCollection
    │   └── cell_sheet.dart      # tile detail / rename / recolour
    ├── profile/
    └── leaderboard/
```

---

## 4. The Hard Part: Background Tracking

### 4.1 The battery budget

Target: **< 4% battery per hour** of active tracking. Continuous 1 Hz GPS costs
~10–15%/hr and will get you uninstalled. Strategy — **adaptive sampling**:

| State | Detection | GPS interval | Accuracy setting |
|---|---|---|---|
| Stationary | <10 m movement for 3 min | **off** (geofence exit only) | — |
| Walking | activity recognition = on_foot | 5 s | `high` (~10 m) |
| Running | speed > 2.5 m/s | 4 s | `high` |
| Vehicle | speed > 8 m/s sustained 30 s | 60 s | `low` — and **stop accumulating** |
| App foreground + map open | — | 2 s | `best` |

The single biggest win is **stationary detection**. People are stationary ~90% of
the day. Register a 100 m geofence around the stop point and let the OS wake you
when it's crossed — this costs near-zero battery and is the same mechanism
Google Maps uses.

### 4.2 Android

```xml
<!-- android/app/src/main/AndroidManifest.xml -->
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>
<uses-permission android:name="android.permission.ACCESS_BACKGROUND_LOCATION"/>
<uses-permission android:name="android.permission.ACTIVITY_RECOGNITION"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_LOCATION"/>
<uses-permission android:name="android.permission.WAKE_LOCK"/>
<uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS"/>

<!-- Health Connect -->
<uses-permission android:name="android.permission.health.READ_STEPS"/>
<uses-permission android:name="android.permission.health.READ_DISTANCE"/>

<service
    android:name="com.pravera.flutter_foreground_task.service.ForegroundService"
    android:foregroundServiceType="location|health"
    android:exported="false"/>
```

Critical Android rules:
1. **`ACCESS_BACKGROUND_LOCATION` must be requested separately**, after
   foreground permission is already granted, with a rationale screen. Requesting
   both at once = automatic denial on Android 11+.
2. You **must** show a persistent notification. Make it useful:
   `"Terrastep · 340 steps in Hilltop Ridge · 2 hexes today"`.
3. Ask for battery-optimisation exemption or OEM skins (Xiaomi, Oppo, Huawei —
   very common in Pakistan/South Asia) will kill your service within minutes.
   Use `disable_battery_optimization` package and link to
   [dontkillmyapp.com](https://dontkillmyapp.com) instructions per-OEM.
4. Google Play requires a **video demo + written justification** for background
   location. Budget 1–2 weeks for review. Record the demo before you submit.

### 4.3 iOS

```xml
<!-- ios/Runner/Info.plist -->
<key>UIBackgroundModes</key>
<array>
  <string>location</string>
  <string>fetch</string>
  <string>processing</string>
</array>
<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
<string>Terrastep needs your location in the background to award you territory
for the ground you cover, even when the app is closed.</string>
<key>NSLocationWhenInUseUsageDescription</key>
<string>Terrastep shows your position on the territory map.</string>
<key>NSMotionUsageDescription</key>
<string>Used to count your steps inside each territory.</string>
<key>NSHealthShareUsageDescription</key>
<string>Terrastep reads your step and walking-distance data to calculate
territory claims.</string>
```

iOS reality:
- `allowsBackgroundLocationUpdates = true` + `pausesLocationUpdatesAutomatically
  = false` gets you continuous updates, but the OS **will** suspend you under
  memory pressure. Always pair with **significant-location-change** monitoring,
  which relaunches your app after termination.
- The blue "location in use" pill will show. Users tolerate it for a fitness app,
  but expect ~15% to disable "Always".
- **HealthKit is your safety net.** Even if your app was suspended for 3 hours,
  `HKStatisticsCollectionQuery` returns hourly step buckets the OS recorded for
  free. On resume, backfill: attribute those steps to your coarse
  significant-location track. Code sketch in §6.

### 4.4 Sampling loop (pseudocode)

```dart
class TrackingCoordinator {
  final SessionAccumulator _acc;
  MotionState _state = MotionState.stationary;

  void onLocation(Position p) {
    // 1. quality gate
    if (p.accuracy > 35) return;
    if (p.isMocked) { _flagMock(); return; }

    // 2. speed gate — do not accumulate while in a vehicle
    if (p.speed > 8.0) { _state = MotionState.vehicle; _acc.pause(); return; }

    // 3. resolve cell (this is a pure function, no I/O)
    final cell = h3.latLngToCell(GeoCoord(lat: p.latitude, lon: p.longitude), 9);

    // 4. feed the accumulator
    _acc.addFix(cell: cell, position: p, at: DateTime.now());

    // 5. adapt sampling
    _retune(p.speed);
  }

  void onStepDelta(int steps, DateTime at) {
    // steps are attributed to whichever cell we were in at `at`
    _acc.addSteps(steps, at);
  }
}
```

---

## 5. `SessionAccumulator` — the pure core

Keep this free of Flutter, plugins, and I/O. It is the piece you will debug most,
and it must be testable with synthetic GPS tracks.

```dart
class CellVisit {
  final String cellId;
  int steps = 0;
  double distanceM = 0;
  int dwellS = 0;
  int fixCount = 0;
  double _accSum = 0;
  double maxSpeed = 0;
  DateTime windowStart;
  DateTime windowEnd;
  double lat, lng;          // representative point (first fix)
  bool submitted = false;

  double get meanAccuracy => fixCount == 0 ? 999 : _accSum / fixCount;
}

class SessionAccumulator {
  final int resolution;
  final GameConfig cfg;
  final Map<String, CellVisit> _visits = {};

  String? _currentCell;
  Position? _lastFix;
  DateTime? _lastFixAt;

  void addFix({required String cell, required Position p, required DateTime at}) {
    final v = _visits.putIfAbsent(cell, () => CellVisit(
        cellId: cell, lat: p.latitude, lng: p.longitude,
        windowStart: at, windowEnd: at));

    v.fixCount++;
    v._accSum += p.accuracy;
    v.windowEnd = at;
    v.maxSpeed = math.max(v.maxSpeed, p.speed);

    if (_lastFix != null && _lastFixAt != null) {
      final gapS = at.difference(_lastFixAt!).inSeconds;

      // Only credit dwell if the gap is plausible (guards against a 3-hour
      // suspension being credited as 3 hours of dwell in one cell).
      if (gapS > 0 && gapS <= 120) {
        // dwell goes to the cell we WERE in
        if (_currentCell == cell) {
          v.dwellS += gapS;
        } else {
          _visits[_currentCell]?.dwellS += gapS ~/ 2;
          v.dwellS += gapS ~/ 2;              // split across the boundary
        }

        final d = haversine(_lastFix!, p);
        // reject teleports and GPS jitter
        if (d > 1.0 && d / gapS <= 8.0) {
          v.distanceM += d;
        }
      }
    }

    _currentCell = cell;
    _lastFix = p;
    _lastFixAt = at;
  }

  /// Steps arrive asynchronously from HealthKit/pedometer with a timestamp.
  /// Attribute them to the cell whose window contains that timestamp.
  void addSteps(int steps, DateTime at) {
    final target = _visits.values.firstWhereOrNull(
      (v) => !at.isBefore(v.windowStart) && !at.isAfter(v.windowEnd.add(
              const Duration(seconds: 30))));
    (target ?? _visits[_currentCell])?.steps += steps;
  }

  /// Visits that now meet ALL claim floors and haven't been sent yet.
  List<CellVisit> readyToSubmit() => _visits.values.where((v) =>
      !v.submitted &&
      v.steps      >= cfg.claimMinSteps &&
      v.distanceM  >= cfg.claimMinDistanceM &&
      v.dwellS     >= cfg.claimMinDwellS &&
      v.fixCount   >= cfg.claimMinFixes &&
      v.meanAccuracy <= cfg.maxAccuracyM
  ).toList();
}
```

### Unit tests you must write (Phase 1, threshold 1.6)

| Test | Assert |
|---|---|
| Straight 500 m walk through 3 cells | 3 visits, distances sum ≈ 500 ± 5% |
| Shaking in place (steps, no distance) | 0 visits ready |
| Driving at 20 m/s through 10 cells | 0 visits ready (speed gate) |
| App suspended 3 h mid-walk | dwell does NOT jump by 3 h |
| GPS jitter ±40 m while stationary | distance stays < 20 m |
| Boundary oscillation A→B→A→B | dwell split, neither cell inflated |

---

## 6. Rendering H3 on MapLibre

Never store polygons server-side. Generate them on-device from the cell ID.

```dart
Map<String, dynamic> buildHexGeoJson(
    Iterable<String> cells, Map<String, Territory> owned, String? myId) {
  final features = <Map<String, dynamic>>[];

  for (final cell in cells) {
    final boundary = h3.cellToBoundary(cell);           // List<GeoCoord>
    final ring = [
      ...boundary.map((c) => [c.lon, c.lat]),
      [boundary.first.lon, boundary.first.lat],         // close the ring
    ];

    final t = owned[cell];
    features.add({
      'type': 'Feature',
      'id': cell.hashCode,
      'geometry': {'type': 'Polygon', 'coordinates': [ring]},
      'properties': {
        'cell': cell,
        'state': t == null ? 'neutral'
               : t.ownerId == myId ? 'mine'
               : t.contested ? 'contested' : 'enemy',
        'color': t?.color ?? '#94A3B8',
        'name': t?.name ?? '',
      }
    });
  }
  return {'type': 'FeatureCollection', 'features': features};
}
```

Layer styling:

```dart
await controller.addGeoJsonSource('hexes', geojson);

await controller.addFillLayer('hexes', 'hex-fill', FillLayerProperties(
  fillColor: ['get', 'color'],
  fillOpacity: ['match', ['get','state'],
      'mine', 0.55, 'enemy', 0.40, 'contested', 0.50, 0.06],
));

await controller.addLineLayer('hexes', 'hex-outline', LineLayerProperties(
  lineColor: ['match', ['get','state'], 'neutral', '#CBD5E1', ['get','color']],
  lineWidth: ['match', ['get','state'], 'mine', 2.0, 1.0],
));
```

**Performance rules:**
1. Only render cells in the viewport: `h3.polygonToCells(mapBounds, 9)`.
2. Above zoom-out threshold (z < 13), switch to res-7 aggregate cells coloured by
   dominant owner — 500 hexes is the practical ceiling for smooth fills.
3. Debounce the camera-idle handler by 300 ms.
4. Use `setGeoJsonSource` to update in place; never remove/re-add the layer.

### HealthKit backfill (iOS gap recovery)

```dart
Future<void> backfillSteps(DateTime from, DateTime to) async {
  final buckets = await health.getHealthIntervalDataFromTypes(
    startDate: from, endDate: to,
    types: [HealthDataType.STEPS],
    interval: 300,                     // 5-minute buckets
  );
  for (final b in buckets) {
    // Match each bucket to the cell our coarse track says we were in
    final cell = _coarseTrack.cellAt(b.dateFrom);
    if (cell != null) _acc.addStepsToCell(cell, (b.value as num).toInt());
  }
}
```

---

## 7. Sync Worker (outbox pattern)

```dart
class SyncWorker {
  Timer? _timer;

  void start() {
    _timer = Timer.periodic(const Duration(seconds: 90), (_) => flush());
  }

  Future<void> flush() async {
    if (!await _online()) return;

    final pending = await outbox.take(limit: 30);       // cap payload size
    if (pending.isEmpty) return;

    // Idempotency key persisted WITH the batch, so retries reuse it.
    final batchId = pending.first.batchUuid;

    try {
      final res = await supabase.rpc('claim_cells', params: {
        'p_batch_uuid': batchId,
        'p_cells': pending.map((v) => v.toJson()).toList(),
        'p_client_version': appVersion,
      });

      if (res['ok'] == true) {
        await outbox.markSent(pending);
        await _applyResults(res['results']);            // update local map cache
      } else if (res['error'] == 'rate_limited') {
        _backoff = Duration(seconds: res['retry_after_s']);
      }
    } on SocketException {
      // keep in outbox, exponential backoff, retry later
      _backoff = Duration(seconds: math.min(_backoff.inSeconds * 2, 900));
    }
  }
}
```

**Rules:**
- Write to the outbox *before* attempting the network call. The outbox is the
  source of truth; the network is best-effort.
- Generate `batch_uuid` once, store it, reuse on every retry. The server's
  `sync_receipts` table makes replays free.
- Show claims **optimistically** on the map, with a "syncing" shimmer, and
  reconcile on the server response. Reverting a hex the server rejected is a
  worse UX than a 90 s delay — so only show optimistic claims once the local
  accumulator has *passed all client-side floors*, which means the server will
  almost always agree.

---

## 8. Realtime Subscription

```dart
RealtimeChannel? _channel;
String? _region;

void watchRegion(String currentCell) {
  final region = h3.cellToParent(currentCell, 5);
  if (region == _region) return;              // still in the same metro area

  _channel?.unsubscribe();
  _region = region;

  _channel = supabase
    .channel('region:$region')
    .onBroadcast(event: 'cells_changed', callback: (payload) {
        for (final c in payload['cells']) {
          _mapCache.invalidate(c['cell_id']);
        }
        _refreshVisibleHexes();
      })
    .subscribe();
}
```

Only subscribe while the map screen is in the foreground. Unsubscribe in
`dispose()` and on `AppLifecycleState.paused`. This keeps you inside the
200-concurrent-connection free-tier ceiling for far longer.

---

## 9. Permission Onboarding Flow (do not skip)

Conversion on "Always Allow" is the #1 determinant of whether this app works.

```
Screen 1  "Terrastep turns your walks into territory."      [Continue]
Screen 2  "We need location while you walk."                [Allow Location]
             → request WHEN_IN_USE
Screen 3  (after first successful claim, NOT before)
          "Nice — you claimed your first hex! To keep earning
           territory when your phone's in your pocket, switch
           location to Always."                             [Enable]
             → request ALWAYS
Screen 4  "Count your steps"  → HealthKit / Health Connect
Screen 5  (Android only) "Stop Android from pausing Terrastep"
             → battery-optimisation exemption
```

Requesting "Always" **after** the user has felt the reward converts roughly 2–3×
better than asking upfront. Delay it.
