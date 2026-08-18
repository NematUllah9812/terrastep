import 'dart:math' as math;

/// Game balance constants.
///
/// Mirrors the `game_config` table in `01_DATA_MODEL.sql`. These defaults are
/// the fallback used before the server config has been fetched (and offline).
/// The server is always authoritative — see [GameConfig.fromMap].
///
/// Keep every value here in sync with the SQL. The engine tests in
/// `tests/01_engine_tests.sql` assert the server side; `test/` asserts this one.
class GameConfig {
  final int h3Resolution;
  final int claimMinSteps;
  final int claimMinDistanceM;
  final int claimMinDwellS;
  final int claimMinFixes;
  final double effortStepWeight;
  final double effortDistWeight;
  final double effortDwellWeight;
  final double maxEffortPerVisit;
  final double decayHalfLifeDays;
  final double neutralFloor;
  final double takeoverMultiplier;
  final double takeoverFlatMargin;
  final double maxSpeedMps;
  final double maxAccuracyM;
  final int maxCellsPerHour;
  final int maxCellsPerDay;
  final int syncIntervalS;
  final int realtimeParentRes;

  const GameConfig({
    this.h3Resolution = 9,
    this.claimMinSteps = 120,
    this.claimMinDistanceM = 80,
    this.claimMinDwellS = 90,
    this.claimMinFixes = 5,
    this.effortStepWeight = 1.00,
    this.effortDistWeight = 0.35,
    this.effortDwellWeight = 0.05,
    this.maxEffortPerVisit = 600,
    this.decayHalfLifeDays = 7,
    this.neutralFloor = 100,
    this.takeoverMultiplier = 1.15,
    this.takeoverFlatMargin = 50,
    this.maxSpeedMps = 8.0,
    this.maxAccuracyM = 35,
    this.maxCellsPerHour = 50,
    this.maxCellsPerDay = 200,
    this.syncIntervalS = 90,
    this.realtimeParentRes = 5,
  });

  /// Build from the `game_config` table: `[{key, value}, ...]`.
  factory GameConfig.fromRows(List<Map<String, dynamic>> rows) {
    final m = <String, num>{};
    for (final r in rows) {
      final k = r['key'];
      final v = r['value'];
      if (k is String && v != null) m[k] = num.parse(v.toString());
    }
    const d = GameConfig();
    return GameConfig(
      h3Resolution: m['h3_resolution']?.toInt() ?? d.h3Resolution,
      claimMinSteps: m['claim_min_steps']?.toInt() ?? d.claimMinSteps,
      claimMinDistanceM: m['claim_min_distance_m']?.toInt() ?? d.claimMinDistanceM,
      claimMinDwellS: m['claim_min_dwell_s']?.toInt() ?? d.claimMinDwellS,
      claimMinFixes: m['claim_min_fixes']?.toInt() ?? d.claimMinFixes,
      effortStepWeight: m['effort_step_weight']?.toDouble() ?? d.effortStepWeight,
      effortDistWeight: m['effort_dist_weight']?.toDouble() ?? d.effortDistWeight,
      effortDwellWeight: m['effort_dwell_weight']?.toDouble() ?? d.effortDwellWeight,
      maxEffortPerVisit: m['max_effort_per_visit']?.toDouble() ?? d.maxEffortPerVisit,
      decayHalfLifeDays: m['decay_half_life_days']?.toDouble() ?? d.decayHalfLifeDays,
      neutralFloor: m['neutral_floor']?.toDouble() ?? d.neutralFloor,
      takeoverMultiplier: m['takeover_multiplier']?.toDouble() ?? d.takeoverMultiplier,
      takeoverFlatMargin: m['takeover_flat_margin']?.toDouble() ?? d.takeoverFlatMargin,
      maxSpeedMps: m['max_speed_mps']?.toDouble() ?? d.maxSpeedMps,
      maxAccuracyM: m['max_accuracy_m']?.toDouble() ?? d.maxAccuracyM,
      maxCellsPerHour: m['max_cells_per_hour']?.toInt() ?? d.maxCellsPerHour,
      maxCellsPerDay: m['max_cells_per_day']?.toInt() ?? d.maxCellsPerDay,
      realtimeParentRes: m['realtime_parent_res']?.toInt() ?? d.realtimeParentRes,
    );
  }

  /// Effort score. MUST match `compute_effort()` in `02_CLAIM_ENGINE.sql`.
  double computeEffort(int steps, double distanceM, int dwellS) {
    final raw = steps * effortStepWeight +
        distanceM * effortDistWeight +
        dwellS * effortDwellWeight;
    return raw < maxEffortPerVisit ? raw : maxEffortPerVisit;
  }

  /// Lazy decay. MUST match `current_influence()` in `01_DATA_MODEL.sql`.
  double currentInfluence(double influence, DateTime at, {DateTime? now}) {
    final elapsed = (now ?? DateTime.now()).difference(at).inMilliseconds;
    final days = elapsed / 86400000.0;
    return influence * _pow2(-days / decayHalfLifeDays);
  }

  /// Effort a challenger needs to take a cell from its current owner.
  double effortToCapture(double ownerInfluence, double myInfluence) {
    final bar = ownerInfluence * takeoverMultiplier + takeoverFlatMargin;
    final need = bar - myInfluence;
    return need > 0 ? need : 0;
  }

  static double _pow2(double x) => math.pow(2, x).toDouble();
}
