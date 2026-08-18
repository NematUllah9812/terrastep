import 'dart:async';

import 'package:geolocator/geolocator.dart';
import 'package:terrastep_core/domain/models/geo.dart';

/// Motion state drives the GPS sampling rate. See `03_CLIENT_ARCHITECTURE.md
/// §4.1` — stationary detection is the single biggest battery win, because
/// people are stationary ~90% of the day.
enum MotionState { stationary, walking, running, vehicle }

/// Streams GPS fixes with adaptive sampling.
///
/// Battery strategy: rather than a fixed 1 Hz stream (~10-15%/hr and an
/// uninstall), the distance filter and accuracy are retuned based on observed
/// speed. Target is <4%/hr — threshold 0.3, the project's go/no-go gate.
///
/// | State      | Distance filter | Accuracy   |
/// |------------|-----------------|------------|
/// | stationary | 25 m            | balanced   |
/// | walking    | 8 m             | high       |
/// | running    | 12 m            | high       |
/// | vehicle    | 200 m           | low        |
///
/// A distance filter is used instead of a timer because Android and iOS both
/// implement it in the OS location stack, so the app isn't woken for fixes
/// that wouldn't change anything.
class LocationService {
  final _controller = StreamController<GeoFix>.broadcast();
  StreamSubscription<Position>? _sub;

  MotionState _state = MotionState.stationary;
  MotionState get state => _state;

  /// Emitted when the sampling profile changes, for the debug overlay.
  final _stateController = StreamController<MotionState>.broadcast();
  Stream<MotionState> get stateChanges => _stateController.stream;

  Stream<GeoFix> get fixes => _controller.stream;

  /// Rolling speed samples, for hysteresis on state transitions. Without this
  /// a single noisy speed reading flaps the profile and wastes battery.
  final List<double> _recentSpeeds = [];

  bool get isTracking => _sub != null;

  /// Request permissions in the right order.
  ///
  /// Android 11+ rejects a combined foreground+background request outright, so
  /// `whileInUse` must be granted and *then* escalated. We do the escalation
  /// after the user's first claim, not here — see `§9` of the client doc.
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
    _listenWith(_settingsFor(_state));
  }

  void _listenWith(LocationSettings settings) {
    _sub?.cancel();
    _sub = Geolocator.getPositionStream(locationSettings: settings)
        .listen(_onPosition, onError: (Object e) {
      // Swallow transient platform errors; the stream self-recovers.
    });
  }

  void _onPosition(Position p) {
    final fix = GeoFix(
      lat: p.latitude,
      lng: p.longitude,
      accuracy: p.accuracy,
      speed: p.speed,
      at: p.timestamp,
      isMocked: p.isMocked,
    );

    _retune(p.speed);
    _controller.add(fix);
  }

  /// Adjust the sampling profile, with hysteresis over the last 5 samples so
  /// one bad reading doesn't flap the state.
  void _retune(double speed) {
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
      _listenWith(_settingsFor(next));
    }
  }

  LocationSettings _settingsFor(MotionState s) => switch (s) {
        MotionState.stationary => const LocationSettings(
            accuracy: LocationAccuracy.medium, distanceFilter: 25),
        MotionState.walking => const LocationSettings(
            accuracy: LocationAccuracy.high, distanceFilter: 8),
        MotionState.running => const LocationSettings(
            accuracy: LocationAccuracy.high, distanceFilter: 12),
        MotionState.vehicle => const LocationSettings(
            accuracy: LocationAccuracy.low, distanceFilter: 200),
      };

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
  }

  Future<void> dispose() async {
    await stop();
    await _controller.close();
    await _stateController.close();
  }
}
