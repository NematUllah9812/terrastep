import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:terrastep_core/core/game_config.dart';
import 'package:terrastep_core/domain/models/cell_visit.dart';
import 'package:terrastep_core/domain/models/geo.dart';
import 'package:terrastep_core/domain/session_accumulator.dart';

/// Deterministic stand-in for H3.
///
/// Real H3 is a native FFI plugin and can't run under `dart test`. This fake
/// buckets lat/lng onto a fixed grid whose cells are ~174 m across — the same
/// scale as H3 res 9 — so boundary-crossing behaviour is exercised realistically.
class FakeIndexer implements CellIndexer {
  static const double cellDeg = 0.0015625; // ~174 m of latitude

  @override
  String cellFor(double lat, double lng) {
    final r = (lat / cellDeg).floor();
    final c = (lng / cellDeg).floor();
    return '89${r.toString().padLeft(6, '0')}${c.toString().padLeft(6, '0')}';
  }

  @override
  String parentRes5(String cellId) => '85${cellId.substring(2, 6)}fffff';
}

/// Builds a synthetic walk: [n] fixes at [intervalS], moving [speedMps]
/// due north from the start point.
List<GeoFix> straightWalk({
  required double startLat,
  required double startLng,
  required int n,
  int intervalS = 5,
  double speedMps = 1.4,
  double accuracy = 8.0,
  DateTime? t0,
}) {
  final start = t0 ?? DateTime.utc(2026, 8, 18, 9, 0, 0);
  const mPerDegLat = 111320.0;
  final fixes = <GeoFix>[];
  for (var i = 0; i < n; i++) {
    final metres = speedMps * intervalS * i;
    fixes.add(GeoFix(
      lat: startLat + metres / mPerDegLat,
      lng: startLng,
      accuracy: accuracy,
      speed: speedMps,
      at: start.add(Duration(seconds: intervalS * i)),
    ));
  }
  return fixes;
}

void main() {
  const cfg = GameConfig();
  late SessionAccumulator acc;
  late List<FixRejection> rejections;

  setUp(() {
    rejections = [];
    acc = SessionAccumulator(
      cfg: cfg,
      indexer: FakeIndexer(),
      onRejected: rejections.add,
    );
  });

  // =========================================================================
  // The six tests mandated by threshold 1.6
  // =========================================================================

  group('threshold 1.6 required tests', () {
    test('T1 straight 500 m walk through multiple cells sums correctly', () {
      // 1.4 m/s * 5 s * 72 = 497 m
      final fixes = straightWalk(
          startLat: 34.1688, startLng: 73.2215, n: 73, intervalS: 5);
      for (final f in fixes) {
        acc.addFix(f);
      }

      final total =
          acc.visits.values.fold<double>(0, (s, v) => s + v.distanceM);
      expect(total, closeTo(504, 25), reason: 'distance within 5%');
      expect(acc.visits.length, greaterThanOrEqualTo(2),
          reason: 'a 500 m walk must cross at least one boundary');

      // Dwell must not exceed the real elapsed time.
      final totalDwell = acc.visits.values.fold<int>(0, (s, v) => s + v.dwellS);
      expect(totalDwell, lessThanOrEqualTo(72 * 5));
    });

    test('T2 shaking in place produces no claimable visit', () {
      // Stationary, but 2000 steps arrive from the pedometer.
      final start = DateTime.utc(2026, 8, 18, 9, 0, 0);
      for (var i = 0; i < 120; i++) {
        acc.addFix(GeoFix(
          lat: 34.1688,
          lng: 73.2215,
          accuracy: 6,
          speed: 0.05,
          at: start.add(Duration(seconds: 5 * i)),
        ));
      }
      acc.addSteps(2000, start.add(const Duration(minutes: 3)));

      expect(acc.readyToSubmit(), isEmpty,
          reason: 'no distance means no claim, regardless of steps');
      final v = acc.visits.values.first;
      expect(v.distanceM, lessThan(cfg.claimMinDistanceM));
    });

    test('T3 driving at 20 m/s claims nothing', () {
      final fixes = straightWalk(
          startLat: 34.1688,
          startLng: 73.2215,
          n: 60,
          intervalS: 2,
          speedMps: 20.0);
      for (final f in fixes) {
        acc.addFix(f);
      }

      expect(acc.readyToSubmit(), isEmpty);
      expect(rejections.where((r) => r == FixRejection.vehicleSpeed).length,
          greaterThan(50));
    });

    test('T4 3-hour suspension does not inflate dwell', () {
      final start = DateTime.utc(2026, 8, 18, 9, 0, 0);
      acc.addFix(GeoFix(lat: 34.1688, lng: 73.2215, accuracy: 8, speed: 1.2, at: start));
      // App suspended; next fix is 3 hours later at the same place.
      acc.addFix(GeoFix(
        lat: 34.1688,
        lng: 73.2215,
        accuracy: 8,
        speed: 1.2,
        at: start.add(const Duration(hours: 3)),
      ));

      final v = acc.visits.values.first;
      expect(v.dwellS, equals(0),
          reason: 'gaps over 120 s must credit no dwell at all');
    });

    test('T5 GPS jitter while stationary accrues almost no distance', () {
      final rnd = math.Random(42);
      final start = DateTime.utc(2026, 8, 18, 9, 0, 0);
      const jitterDeg = 30 / 111320.0; // +/- 30 m

      for (var i = 0; i < 60; i++) {
        acc.addFix(GeoFix(
          lat: 34.1688 + (rnd.nextDouble() - 0.5) * 2 * jitterDeg,
          lng: 73.2215 + (rnd.nextDouble() - 0.5) * 2 * jitterDeg,
          accuracy: 28,
          speed: 0.1,
          at: start.add(Duration(seconds: 5 * i)),
        ));
      }

      final total = acc.visits.values.fold<double>(0, (s, v) => s + v.distanceM);
      // Threshold 4.2 spec: "stand still indoors 10 min -> accumulated
      // distance < 20 m (not 400 m of drift)".
      //
      // Regression guard: the naive `d > 1.0` filter scored 1144 m here, which
      // would have let a user claim a cell without leaving the room.
      expect(total, lessThan(20),
          reason: 'stationary jitter must not accumulate distance');
      expect(acc.readyToSubmit(), isEmpty,
          reason: 'standing still is never claimable');
    });

    test('T6 boundary oscillation splits dwell, inflates neither cell', () {
      final start = DateTime.utc(2026, 8, 18, 9, 0, 0);
      // Sit exactly on a boundary, alternating between two cells.
      const boundary = FakeIndexer.cellDeg * 21870; // an exact cell edge
      for (var i = 0; i < 40; i++) {
        final onLeft = i.isEven;
        acc.addFix(GeoFix(
          lat: boundary + (onLeft ? -0.0000200 : 0.0000200),
          lng: 73.2215,
          accuracy: 9,
          speed: 0.3,
          at: start.add(Duration(seconds: 10 * i)),
        ));
      }

      expect(acc.visits.length, equals(2));
      final totalDwell = acc.visits.values.fold<int>(0, (s, v) => s + v.dwellS);
      expect(totalDwell, lessThanOrEqualTo(40 * 10),
          reason: 'total dwell can never exceed wall-clock time');
      for (final v in acc.visits.values) {
        expect(v.dwellS, lessThan(40 * 10),
            reason: 'neither cell may claim the entire window');
      }
    });
  });

  // =========================================================================
  // Quality gate
  // =========================================================================

  group('fix quality gate', () {
    test('mocked locations are rejected', () {
      final r = acc.addFix(GeoFix(
        lat: 34.1688, lng: 73.2215, at: DateTime.utc(2026, 8, 18, 9),
        isMocked: true,
      ));
      expect(r, isNull);
      expect(rejections, contains(FixRejection.mocked));
    });

    test('poor accuracy is rejected', () {
      final r = acc.addFix(GeoFix(
        lat: 34.1688, lng: 73.2215, accuracy: 80,
        at: DateTime.utc(2026, 8, 18, 9),
      ));
      expect(r, isNull);
      expect(rejections, contains(FixRejection.poorAccuracy));
    });

    test('backwards clock is rejected', () {
      final t = DateTime.utc(2026, 8, 18, 9);
      acc.addFix(GeoFix(lat: 34.1688, lng: 73.2215, accuracy: 8, at: t));
      final r = acc.addFix(GeoFix(
        lat: 34.1689, lng: 73.2215, accuracy: 8,
        at: t.subtract(const Duration(minutes: 5)),
      ));
      expect(r, isNull);
      expect(rejections, contains(FixRejection.clockSkew));
    });

    test('teleport between consecutive fixes credits no distance', () {
      final t = DateTime.utc(2026, 8, 18, 9);
      acc.addFix(GeoFix(lat: 34.1688, lng: 73.2215, accuracy: 8, at: t));
      // Karachi, 10 seconds later.
      acc.addFix(GeoFix(
        lat: 24.8607, lng: 67.0011, accuracy: 8,
        at: t.add(const Duration(seconds: 10)),
      ));
      expect(rejections, contains(FixRejection.impossibleJump));
      final total = acc.visits.values.fold<double>(0, (s, v) => s + v.distanceM);
      expect(total, equals(0));
    });
  });

  // =========================================================================
  // Step attribution
  // =========================================================================

  group('step attribution', () {
    test('steps land in the cell whose window contains their timestamp', () {
      final start = DateTime.utc(2026, 8, 18, 9, 0, 0);
      final fixes =
          straightWalk(startLat: 34.1688, startLng: 73.2215, n: 60, t0: start);
      for (final f in fixes) {
        acc.addFix(f);
      }

      final firstCell = acc.visits.values.first;
      acc.addSteps(100, firstCell.windowStart.add(const Duration(seconds: 1)));
      expect(firstCell.steps, equals(100));
    });

    test('orphan steps from a claimed visit do not inflate the next hex', () {
      final start = DateTime.utc(2026, 8, 18, 9, 0, 0);
      acc.addFix(GeoFix(
          lat: 34.1688, lng: 73.2215, accuracy: 8, at: start));
      acc.addSteps(200, start.add(const Duration(seconds: 1)));
      expect(acc.visits.values.first.steps, equals(200));

      // Claim wipes the visit (markSubmitted). Walk into a new cell.
      acc.markSubmitted(acc.visits.values.toList());
      acc.addFix(GeoFix(
        lat: 34.1800,
        lng: 73.2215,
        accuracy: 8,
        at: start.add(const Duration(minutes: 2)),
      ));

      // Delayed pedometer batch stamped during the *old* visit.
      acc.addSteps(200, start.add(const Duration(seconds: 2)));
      expect(acc.currentVisit!.steps, equals(0),
          reason: 'late steps from the previous hex must not land on the new one');
    });

    test('zero or negative step deltas are ignored', () {
      acc.addFix(GeoFix(
          lat: 34.1688, lng: 73.2215, accuracy: 8, at: DateTime.utc(2026, 8, 18, 9)));
      acc.addSteps(0, DateTime.utc(2026, 8, 18, 9));
      acc.addSteps(-50, DateTime.utc(2026, 8, 18, 9));
      expect(acc.visits.values.first.steps, equals(0));
    });
  });

  // =========================================================================
  // A genuine walk must actually be claimable (the golden path)
  // =========================================================================

  test('golden path: a real 8-minute walk produces a valid claim', () {
    final start = DateTime.utc(2026, 8, 18, 9, 0, 0);
    // 1.35 m/s for 8 minutes, sampled every 5 s = ~648 m
    final fixes = straightWalk(
      startLat: 34.1688,
      startLng: 73.2215,
      n: 97,
      intervalS: 5,
      speedMps: 1.35,
      t0: start,
    );
    for (final f in fixes) {
      acc.addFix(f);
      // ~0.75 m stride
      acc.addSteps(9, f.at);
    }

    final ready = acc.readyToSubmit();
    expect(ready, isNotEmpty, reason: 'a real walk MUST be claimable');

    final v = ready.first;
    expect(v.steps, greaterThanOrEqualTo(cfg.claimMinSteps));
    expect(v.distanceM, greaterThanOrEqualTo(cfg.claimMinDistanceM));
    expect(v.dwellS, greaterThanOrEqualTo(cfg.claimMinDwellS));
    expect(v.fixCount, greaterThanOrEqualTo(cfg.claimMinFixes));

    // Must also survive the server's ratio rule (R6): 0.30 <= m/step <= 1.60
    expect(v.metresPerStep, greaterThan(0.30));
    expect(v.metresPerStep, lessThan(1.60));

    // And rule R5: dwell must not exceed the wall-clock window.
    expect(v.dwellS, lessThanOrEqualTo((v.windowSeconds * 1.05).round()));
  });

  // =========================================================================
  // Payload contract with the server
  // =========================================================================

  test('toJson matches the claim_cells RPC contract', () {
    final v = CellVisit(
      cellId: '8928308280fffff',
      parentRes5: '8528308bfffffff',
      lat: 34.1688,
      lng: 73.2215,
      windowStart: DateTime.utc(2026, 8, 18, 9, 0, 0),
      windowEnd: DateTime.utc(2026, 8, 18, 9, 7, 0),
    );
    v.steps = 400;
    v.distanceM = 310.4;
    v.dwellS = 420;
    v.fixCount = 78;
    v.addAccuracy(8.2 * 78);
    v.maxSpeed = 1.7;

    final j = v.toJson();
    expect(j.keys.toSet(), {
      'cell_id', 'parent_res5', 'lat', 'lng', 'steps', 'distance_m',
      'dwell_s', 'fix_count', 'mean_accuracy_m', 'max_speed_mps',
      'window_start', 'window_end',
    });
    expect(j['distance_m'], equals(310), reason: 'server expects an int');
    expect(j['window_start'], endsWith('Z'), reason: 'must be UTC ISO-8601');
  });
}
