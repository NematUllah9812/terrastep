import 'package:h3_flutter/h3_flutter.dart';
import 'package:terrastep_core/domain/session_accumulator.dart';

/// Real H3 implementation of [CellIndexer].
///
/// Load is lazy and failures are swallowed into [loadError] so a missing
/// native lib cannot take down the GPS listener (the first APK would have
/// killed the stream on the first fix if `geoToCell` threw).
class H3Indexer implements CellIndexer {
  H3? _h3;
  final int resolution;
  final int parentResolution;
  String? loadError;

  H3Indexer({this.resolution = 9, this.parentResolution = 5});

  H3? _lib() {
    if (_h3 != null) return _h3;
    try {
      _h3 = const H3Factory().load();
      loadError = null;
    } catch (e) {
      loadError = e.toString();
    }
    return _h3;
  }

  @override
  String cellFor(double lat, double lng) {
    final h = _lib();
    if (h == null) return _fallbackCell(lat, lng);
    return _hex(h.geoToCell(GeoCoord(lat: lat, lon: lng), resolution));
  }

  @override
  String parentRes5(String cellId) {
    final h = _lib();
    if (h == null) return cellId;
    try {
      return _hex(h.cellToParent(_parse(cellId), parentResolution));
    } catch (_) {
      return cellId;
    }
  }

  List<GeoCoord> boundary(String cellId) {
    final h = _lib();
    if (h == null) return const [];
    try {
      return h.cellToBoundary(_parse(cellId));
    } catch (_) {
      return const [];
    }
  }

  GeoCoord? center(String cellId) {
    final h = _lib();
    if (h == null) return null;
    try {
      return h.cellToGeo(_parse(cellId));
    } catch (_) {
      return null;
    }
  }

  List<String> disk(String cellId, int ringSize) {
    final h = _lib();
    if (h == null) return [cellId];
    try {
      return h.gridDisk(_parse(cellId), ringSize).map(_hex).toList();
    } catch (_) {
      return [cellId];
    }
  }

  int gridDistance(String a, String b) {
    final h = _lib();
    if (h == null) return 0;
    try {
      return h.gridDistance(_parse(a), _parse(b));
    } catch (_) {
      return 0;
    }
  }

  static String _hex(BigInt c) => c.toRadixString(16).padLeft(15, '0');
  static BigInt _parse(String cellId) => BigInt.parse(cellId, radix: 16);

  /// Coarse grid so the HUD still has a "cell" if H3 failed to load.
  static String _fallbackCell(double lat, double lng) {
    final i = (lat * 200).floor();
    final j = (lng * 200).floor();
    return 'fb:$i:$j';
  }
}
