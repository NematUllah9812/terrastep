import 'dart:math' as math;
import 'package:terrastep/core/game_config.dart';
import 'package:terrastep/domain/models/geo.dart';
import 'package:terrastep/domain/session_accumulator.dart';

class FI implements CellIndexer {
  static const d = 0.0015625;
  @override String cellFor(double lat, double lng) =>
    '89${(lat/d).floor().toString().padLeft(6,'0')}${(lng/d).floor().toString().padLeft(6,'0')}';
  @override String parentRes5(String c) => '85${c.substring(2,6)}fffff';
}

void main() {
  const cfg = GameConfig();
  const mLat = 111320.0;

  // Scenario A: genuine 10-minute walk
  var acc = SessionAccumulator(cfg: cfg, indexer: FI());
  var t = DateTime.utc(2026,8,18,9);
  for (var i=0;i<121;i++){
    acc.addFix(GeoFix(lat:34.1688+(1.35*5*i)/mLat, lng:73.2215,
      accuracy:8, speed:1.35, at:t.add(Duration(seconds:5*i))));
    acc.addSteps(9, t.add(Duration(seconds:5*i)));
  }
  var dist = acc.visits.values.fold<double>(0,(s,v)=>s+v.distanceM);
  print('A. 10-min walk (810 m actual)');
  print('   credited: ${dist.toStringAsFixed(0)} m  (${(dist/810*100).toStringAsFixed(0)}% of truth)');
  print('   cells: ${acc.visits.length}  claimable: ${acc.readyToSubmit().length}');

  // Scenario B: standing still, poor GPS, 10 min
  acc = SessionAccumulator(cfg: cfg, indexer: FI());
  final rnd = math.Random(7);
  const j = 30/mLat;
  for (var i=0;i<121;i++){
    acc.addFix(GeoFix(lat:34.1688+(rnd.nextDouble()-0.5)*2*j,
      lng:73.2215+(rnd.nextDouble()-0.5)*2*j,
      accuracy:28, speed:0.1, at:t.add(Duration(seconds:5*i))));
    acc.addSteps(2, t.add(Duration(seconds:5*i)));
  }
  dist = acc.visits.values.fold<double>(0,(s,v)=>s+v.distanceM);
  print('\nB. standing still 10 min, 28 m GPS accuracy');
  print('   credited: ${dist.toStringAsFixed(1)} m   (spec: < 20 m)');
  print('   claimable: ${acc.readyToSubmit().length}  (must be 0)');

  // Scenario C: shaking the phone while stationary
  acc = SessionAccumulator(cfg: cfg, indexer: FI());
  for (var i=0;i<121;i++){
    acc.addFix(GeoFix(lat:34.1688, lng:73.2215, accuracy:6, speed:0.05,
      at:t.add(Duration(seconds:5*i))));
    acc.addSteps(25, t.add(Duration(seconds:5*i)));  // 3000 fake steps
  }
  final v = acc.visits.values.first;
  print('\nC. shaking phone: ${v.steps} steps, ${v.distanceM.toStringAsFixed(1)} m');
  print('   claimable: ${acc.readyToSubmit().length}  (must be 0)');
  print('   m/step = ${v.metresPerStep.toStringAsFixed(3)} -> server R6 would reject');
}
