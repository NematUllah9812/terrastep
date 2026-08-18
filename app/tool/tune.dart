import 'dart:math' as math;
import 'package:terrastep/domain/models/geo.dart';

/// Anchor filter: only credit distance once we've displaced far enough from a
/// held anchor point. Random walk never escapes the anchor; real walking does.
double anchorSum(List<List<double>> pts, double acc, double k, double minAnchor) {
  double total = 0;
  double alat = pts[0][0], alng = pts[0][1];
  final thresh = math.max(minAnchor, acc * k);
  for (final p in pts.skip(1)) {
    final d = haversineM(alat, alng, p[0], p[1]);
    if (d >= thresh) { total += d; alat = p[0]; alng = p[1]; }
  }
  return total;
}

void main() {
  const mPerDegLat = 111320.0;
  // WALK 1.35 m/s, 5s, 96 hops, acc 8
  final walk = <List<double>>[];
  for (var i = 0; i < 97; i++) walk.add([34.1688 + (1.35*5*i)/mPerDegLat, 73.2215]);
  // JITTER stationary acc 28, +/-30m, 60 fixes
  final rnd = math.Random(42);
  const j = 30 / mPerDegLat;
  final jit = <List<double>>[];
  for (var i = 0; i < 60; i++) {
    jit.add([34.1688 + (rnd.nextDouble()-0.5)*2*j, 73.2215 + (rnd.nextDouble()-0.5)*2*j]);
  }
  print('  k     minA   walk    jitter');
  for (final k in [0.8, 1.0, 1.25, 1.5, 2.0]) {
    for (final minA in [8.0, 10.0, 15.0]) {
      final w = anchorSum(walk, 8, k, minA);
      final ji = anchorSum(jit, 28, k, minA);
      print('  ${k.toStringAsFixed(2)}  ${minA.toStringAsFixed(0)}    ${w.toStringAsFixed(0)}m   ${ji.toStringAsFixed(0)}m');
    }
  }
}
