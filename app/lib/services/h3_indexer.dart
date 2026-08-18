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
  String cellFor(double lat, double lng) => _h3
      .geoToCell(GeoCoord(lat: lat, lon: lng), resolution)
      .toRadixString(16);

  @override
  String parentRes5(String cellId) => _h3
      .cellToParent(BigInt.parse(cellId, radix: 16), parentResolution)
      .toRadixString(16);

  /// Vertices of a cell, for drawing the hexagon.
  List<GeoCoord> boundary(String cellId) =>
      _h3.cellToBoundary(BigInt.parse(cellId, radix: 16));

  /// Centre point of a cell.
  GeoCoord center(String cellId) =>
      _h3.cellToGeo(BigInt.parse(cellId, radix: 16));

  /// All cells within [ringSize] rings of [cellId], including itself.
  /// Used to draw the grid around the player without querying the whole map.
  List<String> disk(String cellId, int ringSize) => _h3
      .gridDisk(BigInt.parse(cellId, radix: 16), ringSize)
      .map((c) => c.toRadixString(16))
      .toList();

  /// Hex-grid distance between two cells. Used by the server's path-continuity
  /// check; mirrored here so the client can pre-filter.
  int gridDistance(String a, String b) => _h3.gridDistance(
        BigInt.parse(a, radix: 16),
        BigInt.parse(b, radix: 16),
      );
}
