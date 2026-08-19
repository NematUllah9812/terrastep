import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:terrastep_core/domain/models/geo.dart';

/// Motion state is **display only** on this build.
///
/// Walks 1–3 taught us that a distanceFilter from t=0 silences the first
/// lock (#28). Walk 6 is a pocket/prayer test — mostly standing — so
/// retuning to a 25 m filter would look exactly like “tracking died”.
/// Keep 1 Hz, `distanceFilter: 0` until threshold 1.8 is measured.
enum MotionState { stationary, walking, running, vehicle }

/// Streams GPS fixes at 1 Hz and holds an Android foreground service so
/// the Dart isolate (GPS + pedometer) survives screen-off.
///
/// FGS is geolocator’s own `ForegroundNotificationConfig` — no extra
/// plugin. `flutter_foreground_task` 10 needs Flutter ≥3.38 (#22).
class LocationService {
  final _controller = StreamController<GeoFix>.broadcast();
  StreamSubscription<Position>? _sub;
  Timer? _watchdog;
  DateTime? _startedAt;

  MotionState _state = MotionState.stationary;
  MotionState get state => _state;

  final _stateController = StreamController<MotionState>.broadcast();
  Stream<MotionState> get stateChanges => _stateController.stream;

  Stream<GeoFix> get fixes => _controller.stream;

  final List<double> _recentSpeeds = [];

  int rawFixes = 0;
  String? lastError;
  bool usingLocationManager = false;
  bool get foregroundServiceOn =>
      defaultTargetPlatform == TargetPlatform.android && _sub != null;
  double? lastAccuracy;

  bool get isTracking => _sub != null;

  static const _notification = ForegroundNotificationConfig(
    notificationTitle: 'Terrastep is tracking',
    notificationText: 'GPS and steps stay on with the screen off.',
    notificationChannelName: 'Terrastep tracking',
    enableWakeLock: true,
    setOngoing: true,
    color: Color(0xFF3B82F6),
  );

  static Future<LocationPermission> requestForeground() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return LocationPermission.denied;
    }
    var p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied) {
      p = await Geolocator.requestPermission();
    }
    return p;
  }

  static Future<bool> hasPermission() async {
    final p = await Geolocator.checkPermission();
    return p == LocationPermission.always ||
        p == LocationPermission.whileInUse;
  }

  Future<void> start() async {
    if (_sub != null) return;
    _startedAt = DateTime.now();
    lastError = null;
    await _seed();
    _listen(forceLm: false);
    _armWatchdog();
  }

  Future<void> _seed() async {
    try {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null) _onPosition(last);
    } catch (e) {
      lastError = e.toString();
    }
    try {
      final cur = await Geolocator.getCurrentPosition(
        locationSettings: AndroidSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          timeLimit: const Duration(seconds: 8),
        ),
      );
      _onPosition(cur);
    } catch (e) {
      lastError = e.toString();
    }
  }

  void _listen({required bool forceLm}) {
    _sub?.cancel();
    usingLocationManager = forceLm;
    _sub = Geolocator.getPositionStream(locationSettings: _settings(forceLm))
        .listen(_onPosition, onError: (Object e) {
      lastError = e.toString();
    });
  }

  LocationSettings _settings(bool forceLm) {
    if (defaultTargetPlatform == TargetPlatform.android) {
      return AndroidSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
        intervalDuration: const Duration(seconds: 1),
        forceLocationManager: forceLm,
        foregroundNotificationConfig: _notification,
      );
    }
    return const LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 0,
    );
  }

  void _armWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer.periodic(const Duration(seconds: 2), (_) {
      final start = _startedAt;
      if (start == null || usingLocationManager) {
        _watchdog?.cancel();
        return;
      }
      final elapsed = DateTime.now().difference(start);

      if (rawFixes == 0 && elapsed >= const Duration(seconds: 8)) {
        lastError = 'fused silent 8s — switching to GPS chip';
        _listen(forceLm: true);
        return;
      }

      if (lastAccuracy != null &&
          lastAccuracy! > 50 &&
          elapsed >= const Duration(seconds: 12)) {
        lastError =
            'acc ${lastAccuracy!.toStringAsFixed(0)}m for 12s — switching to GPS chip';
        _listen(forceLm: true);
        return;
      }

      if (lastAccuracy != null && lastAccuracy! <= 50 && rawFixes >= 5) {
        _watchdog?.cancel();
      }
    });
  }

  void _onPosition(Position p) {
    rawFixes++;
    lastAccuracy = p.accuracy;
    lastError = null;

    final fix = GeoFix(
      lat: p.latitude,
      lng: p.longitude,
      accuracy: p.accuracy,
      speed: p.speed,
      at: p.timestamp,
      isMocked: p.isMocked,
    );

    _noteMotion(p.speed);
    if (!_controller.isClosed) _controller.add(fix);
  }

  void _noteMotion(double speed) {
    _recentSpeeds.add(speed < 0 ? 0 : speed);
    if (_recentSpeeds.length > 5) _recentSpeeds.removeAt(0);
    if (_recentSpeeds.length < 3) return;

    final avg = _recentSpeeds.reduce((a, b) => a + b) / _recentSpeeds.length;
    final next = switch (avg) {
      >= 8.0 => MotionState.vehicle,
      >= 2.5 => MotionState.running,
      >= 0.4 => MotionState.walking,
      _ => MotionState.stationary,
    };
    if (next != _state) {
      _state = next;
      _stateController.add(next);
    }
  }

  Future<void> stop() async {
    _watchdog?.cancel();
    _watchdog = null;
    await _sub?.cancel();
    _sub = null;
  }

  Future<void> dispose() async {
    await stop();
    await _controller.close();
    await _stateController.close();
  }
}
