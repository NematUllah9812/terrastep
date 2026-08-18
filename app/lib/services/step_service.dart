import 'dart:async';

import 'package:pedometer/pedometer.dart';

/// Step deltas from the device pedometer.
///
/// Android's `Sensor.TYPE_STEP_COUNTER` reports steps **since last reboot**,
/// not since app start, so we track a baseline and emit deltas. It is a
/// hardware counter maintained by the sensor hub, which means it keeps counting
/// while the app is asleep and costs essentially no battery — the app just
/// reads an already-maintained value.
///
/// Health Connect is the richer source (historical buckets, cross-device) and
/// arrives at threshold 1.5. The raw pedometer is enough for Phase 1 and has
/// far simpler permissions, which matters for getting a testable APK out.
class StepService {
  StreamSubscription<StepCount>? _sub;
  final _deltas = StreamController<({int steps, DateTime at})>.broadcast();

  int? _baseline;
  int _sessionTotal = 0;

  /// Steps counted since [start].
  int get sessionTotal => _sessionTotal;

  /// Emits (steps, timestamp) for each increment. The timestamp is what lets
  /// [SessionAccumulator] attribute steps to the right cell.
  Stream<({int steps, DateTime at})> get deltas => _deltas.stream;

  /// True once the sensor has produced at least one reading. If this stays
  /// false the device likely has no step counter — surfaced in the debug
  /// overlay so a failed hardware test isn't mistaken for a logic bug.
  bool get isAvailable => _baseline != null;

  Future<void> start() async {
    _sub ??= Pedometer.stepCountStream.listen(
      _onCount,
      onError: (Object _) {},
      cancelOnError: false,
    );
  }

  void _onCount(StepCount event) {
    final total = event.steps;

    if (_baseline == null) {
      _baseline = total;
      return;
    }

    // Reboot resets the hardware counter; re-baseline rather than emitting a
    // huge negative delta.
    if (total < _baseline!) {
      _baseline = total;
      return;
    }

    final delta = total - _baseline! - _sessionTotal;
    if (delta <= 0) return;

    _sessionTotal += delta;
    _deltas.add((steps: delta, at: event.timeStamp));
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
  }

  Future<void> dispose() async {
    await stop();
    await _deltas.close();
  }
}
