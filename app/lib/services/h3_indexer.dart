import 'package:h3_flutter/h3_flutter.dart';
import 'package:terrastep_core/domain/session_accumulator.dart';

/// Real H3 implementation of [CellIndexer].
///
/// Loaded lazily so a missing `libh3.so` cannot kill the GPS listener
/// before the first fix (#28).
class H3Indexer implements CellIndexer {
  H3? _h3;
  final int resolution;
  final int parentResolution;

  H3Indexer({this.resolution = 9, this.parentResolution = 5});

  H3 get _engine => _h3 ??= const H3Factory().load();

  @override
  String cellFor(double lat, double lng) =>
      _hex(_engine.geoToCell(GeoCoord(lat: lat, lon: lng), resolution));

  @override
  String parentRes5(String cellId) =>
      _hex(_engine.cellToParent(_parse(cellId), parentResolution));

  List<GeoCoord> boundary(String cellId) =>
      _engine.cellToBoundary(_parse(cellId));

  GeoCoord center(String cellId) => _engine.cellToGeo(_parse(cellId));

  List<String> disk(String cellId, int ringSize) =>
      _engine.gridDisk(_parse(cellId), ringSize).map(_hex).toList();

  int gridDistance(String a, String b) =>
      _engine.gridDistance(_parse(a), _parse(b));

  static String _hex(BigInt c) => c.toRadixString(16).padLeft(15, '0');

  static BigInt _parse(String cellId) => BigInt.parse(cellId, radix: 16);
}
