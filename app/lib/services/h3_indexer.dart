import 'package:h3_flutter/h3_flutter.dart';
import 'package:terrastep_core/domain/session_accumulator.dart';

/// Real H3 implementation of [CellIndexer].
///
/// This is the seam that keeps `terrastep_core` pure: the accumulator depends
/// on the interface, so all the claim logic is testable under `dart test`
/// while the native FFI binding stays here in the Flutter package.
///
/// Cell ids are lowercase hex strings (e.g. `8928308280fffff`) to match the
/// `TEXT` column in `01_DATA_MODEL.sql` and what `h3-js` produces.
class H3Indexer implements CellIndexer {
  final H3 _h3;
  final int resolution;
  final int parentResolution;

  H3Indexer({this.resolution = 9, this.parentResolution = 5})
      : _h3 = const H3Factory().load();

  @override
  String cellFor(double lat, double lng) =>
      _hex(_h3.geoToCell(GeoCoord(lat: lat, lon: lng), resolution));

  @override
  String parentRes5(String cellId) =>
      _hex(_h3.cellToParent(_parse(cellId), parentResolution));

  /// Vertices of a cell, for drawing the hexagon.
  List<GeoCoord> boundary(String cellId) =>
      _h3.cellToBoundary(_parse(cellId));

  /// Centre point of a cell.
  GeoCoord center(String cellId) => _h3.cellToGeo(_parse(cellId));

  /// All cells within [ringSize] rings of [cellId], including itself.
  /// Used to draw the grid around the player without querying the whole map.
  List<String> disk(String cellId, int ringSize) =>
      _h3.gridDisk(_parse(cellId), ringSize).map(_hex).toList();

  /// Hex-grid distance between two cells. Used by the server's path-continuity
  /// check; mirrored here so the client can pre-filter.
  int gridDistance(String a, String b) =>
      _h3.gridDistance(_parse(a), _parse(b));

  /// h3-js emits 15-char lowercase hex. `BigInt.toRadixString` drops leading
  /// zeros, which would desync client cell ids from the server (O9).
  static String _hex(BigInt c) => c.toRadixString(16).padLeft(15, '0');

  static BigInt _parse(String cellId) => BigInt.parse(cellId, radix: 16);
}
