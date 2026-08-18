/// Accumulated effort for one cell during one visit.
///
/// This is the unit the client submits to `claim_cells()`. One row per cell,
/// never raw GPS tracks — see `00_MASTER_PLAN.md §2.1` for why (32x egress
/// reduction, and it avoids storing a movement history server-side).
class CellVisit {
  final String cellId;

  /// Res-5 parent, used as the realtime broadcast topic and local-leaderboard
  /// key. Computed client-side from [cellId].
  String parentRes5;

  int steps = 0;
  double distanceM = 0;
  int dwellS = 0;
  int fixCount = 0;
  double maxSpeed = 0;

  double _accuracySum = 0;

  /// Representative point (first fix in the cell). The server uses this for
  /// the path-continuity check and the optional centroid column.
  double lat;
  double lng;

  DateTime windowStart;
  DateTime windowEnd;

  /// True once handed to the outbox, so we don't submit the same visit twice.
  bool submitted = false;

  CellVisit({
    required this.cellId,
    required this.parentRes5,
    required this.lat,
    required this.lng,
    required this.windowStart,
    required this.windowEnd,
  });

  double get meanAccuracy => fixCount == 0 ? 999 : _accuracySum / fixCount;

  void addAccuracy(double a) => _accuracySum += a;

  /// Metres per step. The server's strongest anti-cheat signal (rule R6):
  /// a human stride is 0.4-1.2 m. Shaking collapses this toward 0; a vehicle
  /// pushes it above 1.6.
  double get metresPerStep => steps == 0 ? 0 : distanceM / steps;

  /// Wall-clock seconds spanned. Claimed [dwellS] must not exceed this
  /// (server rule R5).
  int get windowSeconds => windowEnd.difference(windowStart).inSeconds;

  /// Payload for the `claim_cells` RPC. Key names must match the SQL exactly.
  Map<String, dynamic> toJson() => {
        'cell_id': cellId,
        'parent_res5': parentRes5,
        'lat': lat,
        'lng': lng,
        'steps': steps,
        'distance_m': distanceM.round(),
        'dwell_s': dwellS,
        'fix_count': fixCount,
        'mean_accuracy_m': double.parse(meanAccuracy.toStringAsFixed(2)),
        'max_speed_mps': double.parse(maxSpeed.toStringAsFixed(2)),
        'window_start': windowStart.toUtc().toIso8601String(),
        'window_end': windowEnd.toUtc().toIso8601String(),
      };

  @override
  String toString() => 'CellVisit($cellId, steps=$steps, '
      'dist=${distanceM.toStringAsFixed(1)}m, dwell=${dwellS}s, fixes=$fixCount)';
}
