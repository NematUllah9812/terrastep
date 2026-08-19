import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:terrastep_core/domain/models/geo.dart';

enum MotionState { stationary, walking, running, vehicle }

enum GpsMode { warmup, idle, active }

class LocationService {
  final _controller = StreamController<GeoFix>.broadcast();
  StreamSubscription<Position>? _sub;
  Timer? _watchdog;
  DateTime? _startedAt;
  DateTime? _stationarySince;
  DateTime? _movingSince;

  MotionState _state = MotionState.stationary;
  MotionState get state => _state;

  GpsMode _mode = GpsMode.warmup;
  GpsMode get mode => _mode;

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

  static const _minFixesBeforeRetune = 5;
  static const _idleAfter = Duration(seconds: 20);
  static const _activeAfter = Duration(seconds: 4);

  ForegroundNotificationConfig _notification() => ForegroundNotificationConfig(
        notificationTitle: 'Terrastep is tracking',
        notificationText: switch (_mode) {
          GpsMode.warmup => 'Getting a GPS lock…',
          GpsMode.idle => 'Idle — GPS every 20 s until you walk.',
          GpsMode.active => 'Walking — GPS on.',
        },
        notificationChannelName: 'Terrastep tracking',
        enableWakeLock: false,
        setOngoing: true,
        color: const Color(0xFF3B82F6),
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

  Future<void> start() async {
    if (_sub != null) return;
    _startedAt = DateTime.now();
    lastError = null;
    _mode = GpsMode.warmup;
    await _seed();
    _listen(forceLm: false);
    _armWatchdog();
  }

  void noteSteps() {
    if (_mode == GpsMode.idle) {
      _stationarySince = null;
      _movingSince = DateTime.now();
      _applyMode(GpsMode.active);
    }
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
    if (defaultTargetPlatform != TargetPlatform.android) {
      return const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
      );
    }
    final (accuracy, filter, interval) = switch (_mode) {
      GpsMode.warmup => (
          LocationAccuracy.bestForNavigation,
          0,
          const Duration(seconds: 1)
        ),
      GpsMode.active => (
          LocationAccuracy.bestForNavigation,
          0,
          const Duration(seconds: 2)
        ),
      GpsMode.idle => (
          LocationAccuracy.medium,
          15,
          const Duration(seconds: 20)
        ),
    };
    return AndroidSettings(
      accuracy: accuracy,
      distanceFilter: filter,
      intervalDuration: interval,
      forceLocationManager: forceLm,
      foregroundNotificationConfig: _notification(),
    );
  }

  void _armWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer.periodic(const Duration(seconds: 2), (_) {
      final start = _startedAt;
      if (start == null || usingLocationManager) {
        if (usingLocationManager) _watchdog?.cancel();
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
    final now = DateTime.now();
    if (next == MotionState.stationary) {
      _movingSince = null;
      _stationarySince ??= now;
    } else {
      _stationarySince = null;
      _movingSince ??= now;
    }
    if (next != _state) {
      _state = next;
      _stateController.add(next);
    }
    if (rawFixes < _minFixesBeforeRetune) return;
    if (_mode == GpsMode.warmup) {
      _applyMode(next == MotionState.stationary ? GpsMode.idle : GpsMode.active);
      return;
    }
    if (_mode != GpsMode.idle &&
        next == MotionState.stationary &&
        _stationarySince != null &&
        now.difference(_stationarySince!) >= _idleAfter) {
      _applyMode(GpsMode.idle);
    } else if (_mode != GpsMode.active &&
        next != MotionState.stationary &&
        _movingSince != null &&
        now.difference(_movingSince!) >= _activeAfter) {
      _applyMode(GpsMode.active);
    }
  }

  void _applyMode(GpsMode next) {
    if (next == _mode) return;
    _mode = next;
    _listen(forceLm: usingLocationManager);
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
