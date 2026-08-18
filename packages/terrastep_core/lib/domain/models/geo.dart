import 'dart:math' as math;

/// A single GPS fix, decoupled from any plugin's Position class so the
/// accumulator stays pure and testable.
class GeoFix {
  final double lat;
  final double lng;

  /// Horizontal accuracy in metres. Larger = worse.
  final double accuracy;

  /// Instantaneous speed in m/s. -1 when unknown.
  final double speed;

  /// Device timestamp for this fix.
  final DateTime at;

  /// Android: Location.isFromMockProvider. Always false on iOS.
  final bool isMocked;

  const GeoFix({
    required this.lat,
    required this.lng,
    required this.at,
    this.accuracy = 10.0,
    this.speed = -1,
    this.isMocked = false,
  });

  @override
  String toString() =>
      'GeoFix($lat, $lng, acc=$accuracy, spd=$speed, ${at.toIso8601String()})';
}

/// Great-circle distance in metres.
///
/// Mirrors `haversine_m()` in `02_CLAIM_ENGINE.sql` so client and server agree
/// on distance. Any divergence here shows up as server-side rejections.
double haversineM(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371000.0;
  final dLat = _rad(lat2 - lat1);
  final dLng = _rad(lng2 - lng1);
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(_rad(lat1)) *
          math.cos(_rad(lat2)) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  return r * 2 * math.asin(math.min(1.0, math.sqrt(a)));
}

double _rad(double deg) => deg * math.pi / 180.0;
