import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:terrastep_core/domain/models/geo.dart';

enum MotionState { acquiring, stationary, walking, running, vehicle }

/// Streams GPS fixes. The first test APK used a 25 m distance filter from
/// the first second (ISSUES_LOG #28). On many Android phones
/// `getPositionStream(distanceFilter: 25)` never emits an *initial* fix, so
/// the overlay sat at zeros except battery and elapsed time.
///
/// This build:
/// - asks for the runtime permission via permission_handler (OEM dialogs)
/// - opens location-settings if GPS is off
/// - seeds with last-known + getCurrentPosition
/// - streams at 1 Hz with distanceFilter 0 until we have a lock
/// - falls back to the platform LocationManager if Fused Location is silent
class LocationService {
  final _controller = StreamController<GeoFix>.broadcast();
  StreamSubscription<Position>? _sub;
  Timer? _fallbackTimer;

  MotionState _state = MotionState.acquiring;
  MotionState get state => _state;

  final _stateController = StreamController<MotionState>.broadcast();
  Stream<MotionState> get stateChanges => _stateController.stream;

  Stream<GeoFix> get fixes => _controller.stream;

  final List<double> _recentSpeeds = [];

  int rawFixes = 0;
  String? lastError;
  bool usingLocationManager = false;
  bool get isTracking => _sub != null;

  static Future<bool> isGpsOn() => Geolocator.isLocationServiceEnabled();

  /// Ask for while-in-use location. Returns a short machine code:
  /// `ok`, `gps_off`, `denied`, `permanent`.
  static Future<String> requestForeground() async {
    if (!await Geolocator.isLocationServiceEnabled()) return 'gps_off';

    // permission_handler is more reliable on Xiaomi / Infinix / Oppo / Vivo
    // than geolocator's own request, which is what the first APK used.
    var status = await Permission.locationWhenInUse.status;
    if (!status.isGranted) {
      status = await Permission.locationWhenInUse.request();
    }
    if (!status.isGranted) {
      // Some OEMs only honour the combined `location` permission.
      final alt = await Permission.location.request();
      if (!alt.isGranted) {
        return (status.isPermanentlyDenied || alt.isPermanentlyDenied)
            ? 'permanent'
            : 'denied';
      }
    }

    // Keep geolocator in sync so getPositionStream doesn't 403.
    final g = await Geolocator.checkPermission();
    if (g == LocationPermission.denied) {
      await Geolocator.requestPermission();
    }
    return 'ok';
  }

  static Future<void> openGpsSettings() => Geolocator.openLocationSettings();
  static Future<void> openAppSettingsPage() => openAppSettings();

  Future<void> start() async {
    lastError = null;
    await _seed();
    _listenWith(forceLocationManager: false);

    // If Fused Location produces nothing for 8 s, retry via LocationManager.
    _fallbackTimer?.cancel();
    _fallbackTimer = Timer(const Duration(seconds: 8), () {
      if (rawFixes == 0) {
        usingLocationManager = true;
        lastError = 'no fused fix in 8s — trying LocationManager';
        _listenWith(forceLocationManager: true);
        _seed();
      }
    });
  }

  /// Last-known + a blocking current-position. Either one unsticks a stream
  /// that is waiting for 25 m of movement that will never come.
  Future<void> _seed() async {
    try {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null) _onPosition(last);
    } catch (e) {
      lastError = 'lastKnown: $e';
    }
    try {
      final now = await Geolocator.getCurrentPosition(
        locationSettings: _androidSettings(
          forceLocationManager: usingLocationManager,
          filter: 0,
        ),
      ).timeout(const Duration(seconds: 20));
      _onPosition(now);
    } catch (e) {
      lastError = 'current: $e';
    }
  }

  void _listenWith({required bool forceLocationManager}) {
    _sub?.cancel();
    usingLocationManager = forceLocationManager;
    _sub = Geolocator.getPositionStream(
      locationSettings: _androidSettings(
        forceLocationManager: forceLocationManager,
        filter: 0,
      ),
    ).listen(_onPosition, onError: (Object e) {
      lastError = 'stream: $e';
      _stateController.add(_state);
    });
  }

  LocationSettings _androidSettings({
    required bool forceLocationManager,
    required int filter,
  }) {
    if (defaultTargetPlatform == TargetPlatform.android) {
      return AndroidSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: filter,
        intervalDuration: const Duration(seconds: 1),
        forceLocationManager: forceLocationManager,
      );
    }
    return const LocationSettings(
      accuracy: LocationAccuracy.best,
      distanceFilter: 0,
    );
  }

  void _onPosition(Position p) {
    rawFixes++;
    lastError = null;
    final ts = p.timestamp;
    // Some Android builds report the epoch or a future clock; clamp to now
    // so a bad timestamp cannot clock-skew-reject every fix.
    final at = (ts.year < 2020 || ts.isAfter(DateTime.now().add(const Duration(minutes: 5))))
        ? DateTime.now()
        : ts;

    final fix = GeoFix(
      lat: p.latitude,
      lng: p.longitude,
      accuracy: p.accuracy,
      speed: p.speed,
      at: at,
      isMocked: p.isMocked,
    );

    _retune(p.speed);
    if (!_controller.isClosed) _controller.add(fix);
  }

  void _retune(double speed) {
    _recentSpeeds.add(speed < 0 ? 0 : speed);
    if (_recentSpeeds.length > 5) _recentSpeeds.removeAt(0);

    // Stay in `acquiring` until we have a handful of raw fixes so we never
    // slap a 25 m filter on before the first lock.
    if (rawFixes < 5) {
      _setState(MotionState.acquiring);
      return;
    }
    if (_recentSpeeds.length < 3) return;

    final avg = _recentSpeeds.reduce((a, b) => a + b) / _recentSpeeds.length;
    final next = switch (avg) {
      >= 8.0 => MotionState.vehicle,
      >= 2.5 => MotionState.running,
      >= 0.4 => MotionState.walking,
      _ => MotionState.stationary,
    };
    _setState(next);
  }

  void _setState(MotionState next) {
    if (next == _state) return;
    _state = next;
    _stateController.add(next);
    // Do NOT restart the stream with a distance filter. That was #28.
    // Battery-aware retuning comes back with the foreground service (O11).
  }

  Future<void> stop() async {
    _fallbackTimer?.cancel();
    _fallbackTimer = null;
    await _sub?.cancel();
    _sub = null;
  }

  Future<void> dispose() async {
    await stop();
    await _controller.close();
    await _stateController.close();
  }
}
