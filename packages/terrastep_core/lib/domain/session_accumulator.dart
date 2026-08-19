import 'dart:math' as math;

import '../core/game_config.dart';
import 'models/cell_visit.dart';
import 'models/geo.dart';

/// Resolves a lat/lng to an H3 cell id, and that cell to its res-5 parent.
///
/// Abstracted so the accumulator has NO dependency on `h3_flutter` (which is
/// a native FFI plugin and cannot run in a plain `dart test`). Production wires
/// in the real H3 binding; tests use a deterministic fake.
abstract class CellIndexer {
  String cellFor(double lat, double lng);
  String parentRes5(String cellId);
}

/// Why a fix was discarded. Surfaced for telemetry and the debug overlay.
enum FixRejection { mocked, poorAccuracy, vehicleSpeed, impossibleJump, clockSkew }

/// Accumulates GPS fixes and step deltas into per-cell effort totals.
///
/// **Pure Dart. No Flutter, no plugins, no I/O.** This is deliberate: it is the
/// most bug-prone part of the client and must be testable with synthetic GPS
/// tracks. See `06_MILESTONE_CHECKLIST.md` threshold 1.6.
///
/// Design notes:
/// - Dwell is only credited for plausible gaps (<= 120 s). Without this, an app
///   suspended for 3 hours would credit 3 hours of dwell to one cell.
/// - Distance is rejected when it implies impossible speed, which filters GPS
///   jitter while stationary.
/// - Boundary crossings split dwell between the two cells rather than giving
///   the full gap to either.
class SessionAccumulator {
  final GameConfig cfg;
  final CellIndexer indexer;

  /// Called whenever a fix is discarded, for telemetry / anti-cheat signals.
  final void Function(FixRejection reason)? onRejected;

  final Map<String, CellVisit> _visits = {};

  String? _currentCell;
  GeoFix? _lastFix;

  /// Held reference point for displacement-based distance. See [_creditFrom].
  GeoFix? _anchor;

  SessionAccumulator({
    required this.cfg,
    required this.indexer,
    this.onRejected,
  });

  Map<String, CellVisit> get visits => Map.unmodifiable(_visits);
  String? get currentCell => _currentCell;
  CellVisit? get currentVisit =>
      _currentCell == null ? null : _visits[_currentCell];

  /// Feed a GPS fix. Returns the cell id it was attributed to, or null if the
  /// fix was rejected by the quality gate.
  String? addFix(GeoFix fix) {
    // --- quality gate (client-side; the server re-checks everything) --------
    if (fix.isMocked) {
      onRejected?.call(FixRejection.mocked);
      return null;
    }
    if (fix.accuracy > cfg.maxAccuracyM) {
      onRejected?.call(FixRejection.poorAccuracy);
      return null;
    }
    if (fix.speed > cfg.maxSpeedMps) {
      // In a vehicle: stop accumulating, and break the track so the next
      // stretch of walking doesn't inherit a huge distance jump.
      onRejected?.call(FixRejection.vehicleSpeed);
      _lastFix = null;
      _anchor = null;
      return null;
    }

    final last = _lastFix;
    if (last != null) {
      final gapS = fix.at.difference(last.at).inSeconds;
      if (gapS < 0) {
        // Clock went backwards (NTP correction or tampering).
        onRejected?.call(FixRejection.clockSkew);
        return null;
      }
      if (gapS > 0) {
        final d = haversineM(last.lat, last.lng, fix.lat, fix.lng);
        if (d / gapS > 12.0) {
          onRejected?.call(FixRejection.impossibleJump);
          _lastFix = fix; // resync, but credit nothing
          return null;
        }
      }
    }

    // --- attribute to a cell ------------------------------------------------
    final cell = indexer.cellFor(fix.lat, fix.lng);
    final visit = _visits.putIfAbsent(
      cell,
      () => CellVisit(
        cellId: cell,
        parentRes5: indexer.parentRes5(cell),
        lat: fix.lat,
        lng: fix.lng,
        windowStart: fix.at,
        windowEnd: fix.at,
      ),
    );

    visit.fixCount++;
    visit.addAccuracy(fix.accuracy);
    if (fix.at.isAfter(visit.windowEnd)) visit.windowEnd = fix.at;
    if (fix.speed > visit.maxSpeed) visit.maxSpeed = fix.speed;

    // --- dwell + distance ---------------------------------------------------
    if (last != null) {
      final gapS = fix.at.difference(last.at).inSeconds;

      // Only credit plausible gaps. A long gap means the app was suspended;
      // we cannot know the user stayed put, so we credit nothing.
      if (gapS > 0 && gapS <= 120) {
        if (_currentCell == cell) {
          visit.dwellS += gapS;
        } else {
          // Crossed a boundary: split the interval between both cells.
          final half = gapS ~/ 2;
          _visits[_currentCell]?.dwellS += half;
          visit.dwellS += gapS - half;
        }

        visit.distanceM += _creditFrom(fix, visit);
      }
    }

    _currentCell = cell;
    _lastFix = fix;
    return cell;
  }

  /// Credit distance using a **displacement anchor** rather than summing
  /// consecutive hops.
  ///
  /// **Why not just sum the hops?** A stationary phone with mediocre GPS
  /// produces a random walk: each fix lands tens of metres from the last, and
  /// naively summing them accumulates kilometres of phantom distance. Measured
  /// on synthetic 30 m jitter, hop-summing scored **1144 m over five minutes of
  /// standing still** — enough to claim a cell from an armchair.
  ///
  /// Subtracting a noise floor from each hop doesn't fix it either: at 28 m
  /// accuracy the individual hops are genuinely large, so any deadband big
  /// enough to suppress them also erases real walking. (Measured: at the point
  /// jitter fell to 138 m, a real walk scored 0 m.)
  ///
  /// **The insight:** jitter *oscillates* — it has no net displacement — while
  /// walking *displaces*. So we hold an anchor point and only credit distance
  /// once the current fix is [_anchorFactor]x the GPS uncertainty away from it,
  /// then move the anchor there. A stationary phone never escapes its anchor
  /// and scores exactly zero; a walker escapes it continuously and is credited
  /// in full.
  ///
  /// Measured with this filter: real walk **647 m**, stationary jitter **0 m**.
  ///
  /// The trade-off is granularity — distance accrues in ~2x-accuracy steps
  /// rather than continuously, so it lags slightly behind on a good-GPS walk.
  /// That is the correct direction to err: under-counting costs a real walker
  /// a few extra paces, over-counting hands out free territory.
  double _creditFrom(GeoFix fix, CellVisit visit) {
    final anchor = _anchor;
    if (anchor == null) {
      _anchor = fix;
      return 0;
    }

    final d = haversineM(anchor.lat, anchor.lng, fix.lat, fix.lng);
    final gapS = fix.at.difference(anchor.at).inSeconds;

    // Implausible speed since the anchor -> reject and resync.
    if (gapS > 0 && d / gapS > cfg.maxSpeedMps) {
      _anchor = fix;
      return 0;
    }

    // Must escape the uncertainty envelope of BOTH fixes to count as movement.
    final threshold = math.max(
      _minAnchorM,
      math.max(anchor.accuracy, fix.accuracy) * _anchorFactor,
    );
    if (d < threshold) return 0;

    _anchor = fix;
    return d;
  }

  /// Never require less than this to register movement, even with a
  /// (suspiciously) perfect accuracy report.
  static const double _minAnchorM = 8.0;

  /// Multiple of GPS uncertainty a fix must exceed before it counts as real
  /// displacement. 2.0 was chosen by measurement (`tool/tune.dart`): it is the
  /// smallest value that reduces stationary jitter to exactly zero while
  /// leaving a genuine walk fully credited.
  static const double _anchorFactor = 2.0;

  /// Add a step delta, attributed to the cell whose window contains [at].
  ///
  /// Steps arrive asynchronously from HealthKit / Health Connect / the
  /// pedometer, often batched and slightly delayed, so we match on timestamp
  /// rather than assuming they belong to the current cell.
  void addSteps(int steps, DateTime at) {
    if (steps <= 0) return;

    for (final v in _visits.values) {
      final afterStart = !at.isBefore(v.windowStart);
      final beforeEnd = !at.isAfter(v.windowEnd.add(const Duration(seconds: 30)));
      if (afterStart && beforeEnd) {
        v.steps += steps;
        return;
      }
    }
    // No window matched. After markSubmitted deletes a claimed visit, delayed
    // pedometer batches from that visit used to dump onto the *current* cell
    // and inflate the next hex (#30). Only attach if the timestamp belongs
    // to the current visit.
    final cur = _currentCell == null ? null : _visits[_currentCell];
    if (cur != null && !at.isBefore(cur.windowStart)) {
      cur.steps += steps;
    }
  }

  /// True when a visit meets every claim floor the server enforces.
  ///
  /// Mirrors rules R2/R3 of `validate_cell_claim()`. Checking client-side means
  /// we only submit claims the server will almost certainly accept, which is
  /// what makes optimistic map rendering safe.
  bool meetsFloors(CellVisit v) =>
      v.steps >= cfg.claimMinSteps &&
      v.distanceM >= cfg.claimMinDistanceM &&
      v.dwellS >= cfg.claimMinDwellS &&
      v.fixCount >= cfg.claimMinFixes &&
      v.meanAccuracy <= cfg.maxAccuracyM;

  /// Visits ready to submit, that haven't been submitted yet.
  List<CellVisit> readyToSubmit() =>
      _visits.values.where((v) => !v.submitted && meetsFloors(v)).toList()
        ..sort((a, b) => a.windowStart.compareTo(b.windowStart));

  /// Mark visits as submitted and reset their counters, keeping the cell so
  /// continued walking accumulates a fresh visit.
  void markSubmitted(Iterable<CellVisit> submittedVisits) {
    for (final v in submittedVisits) {
      _visits.remove(v.cellId);
    }
  }

  /// Progress toward a claim, 0..1. For the HUD ring.
  double progressFor(CellVisit v) {
    double frac(num a, num b) => b == 0 ? 1 : (a / b).clamp(0, 1).toDouble();
    return (frac(v.steps, cfg.claimMinSteps) +
            frac(v.distanceM, cfg.claimMinDistanceM) +
            frac(v.dwellS, cfg.claimMinDwellS)) /
        3.0;
  }

  void clear() {
    _visits.clear();
    _currentCell = null;
    _lastFix = null;
    _anchor = null;
  }
}
