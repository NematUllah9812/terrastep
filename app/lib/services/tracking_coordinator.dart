import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:terrastep_core/core/game_config.dart';
import 'package:terrastep_core/domain/models/cell_visit.dart';
import 'package:terrastep_core/domain/session_accumulator.dart';

import 'h3_indexer.dart';
import 'location_service.dart';
import 'step_service.dart';

/// A cell this device has claimed. Phase 1 is offline, so ownership is purely
/// local; Phase 2 replaces this with server state.
class ClaimedCell {
  final String cellId;
  final DateTime claimedAt;
  final double effort;

  const ClaimedCell(
      {required this.cellId, required this.claimedAt, required this.effort});

  Map<String, dynamic> toJson() => {
        'cell': cellId,
        'at': claimedAt.toIso8601String(),
        'effort': effort,
      };

  factory ClaimedCell.fromJson(Map<String, dynamic> j) => ClaimedCell(
        cellId: j['cell'] as String,
        claimedAt: DateTime.parse(j['at'] as String),
        effort: (j['effort'] as num).toDouble(),
      );
}

/// Glues location + steps into the [SessionAccumulator] and surfaces state
/// to the UI.
///
/// Phase 1 scope: everything is local. When a visit meets the claim floors the
/// cell is marked owned and persisted to SharedPreferences, so a force-quit
/// doesn't lose territory (threshold 1.7). Phase 2 swaps the local claim for
/// the `claim_cells` RPC via the already-built SyncWorker.
class TrackingCoordinator extends ChangeNotifier {
  final GameConfig cfg;
  final H3Indexer indexer;
  final LocationService location;
  final StepService steps;

  late final SessionAccumulator accumulator;

  static const _prefsKey = 'terrastep.claimed.v1';

  final Map<String, ClaimedCell> _claimed = {};
  Map<String, ClaimedCell> get claimed => Map.unmodifiable(_claimed);

  GeoPoint? _position;
  GeoPoint? get position => _position;

  String? get currentCell => accumulator.currentCell;
  CellVisit? get currentVisit => accumulator.currentVisit;

  // --- debug counters, shown in the overlay -------------------------------
  int fixesAccepted = 0;
  int rawFixes = 0;
  final Map<FixRejection, int> rejections = {};
  DateTime? lastFixAt;
  double? lastAccuracy;
  MotionState motion = MotionState.acquiring;
  String? lastError;

  StreamSubscription<void>? _locSub;
  StreamSubscription<void>? _stepSub;
  StreamSubscription<void>? _motionSub;

  DateTime? sessionStartedAt;

  /// True when we are synthesizing steps from distance because the hardware
  /// pedometer never produced a reading. Surfaced in the debug overlay so a
  /// tester can tell estimated steps from real ones.
  bool get estimatingSteps =>
      !steps.isAvailable &&
      sessionStartedAt != null &&
      DateTime.now().difference(sessionStartedAt!) >
          const Duration(seconds: 8);

  TrackingCoordinator({
    required this.indexer,
    required this.location,
    required this.steps,
    // 80 m: Abbottabad walk 2026-08-18 showed a *good* lock at 42–47 m
    // and the 35 m server default rejected almost every fix (#29).
    this.cfg = const GameConfig(maxAccuracyM: 80),
  }) {
    accumulator = SessionAccumulator(
      cfg: cfg,
      indexer: indexer,
      onRejected: (r) {
        rejections[r] = (rejections[r] ?? 0) + 1;
        notifyListeners();
      },
    );
  }

  Future<void> init() async {
    await _loadClaimed();
    sessionStartedAt = DateTime.now();

    _locSub = location.fixes.listen((fix) {
      rawFixes = location.rawFixes;
      lastError = location.lastError;
      _position = GeoPoint(fix.lat, fix.lng);
      lastFixAt = fix.at;
      lastAccuracy = fix.accuracy;
      try {
        final cell = accumulator.addFix(fix);
        if (cell != null) {
          fixesAccepted++;
          _maybeEstimateSteps();
          _checkClaims();
        }
      } catch (e) {
        lastError = 'fix: $e';
      }
      notifyListeners();
    }, onError: (Object e) {
      lastError = 'gps: $e';
      notifyListeners();
    });

    _stepSub = steps.deltas.listen((d) {
      accumulator.addSteps(d.steps, d.at);
      _checkClaims();
      notifyListeners();
    });

    _motionSub = location.stateChanges.listen((s) {
      motion = s;
      lastError = location.lastError;
      rawFixes = location.rawFixes;
      notifyListeners();
    });

    await location.start();
    await steps.start();
    rawFixes = location.rawFixes;
    lastError = location.lastError;
    notifyListeners();
  }

  /// Devices without a step counter (or where ACTIVITY_RECOGNITION was
  /// denied) would otherwise be unable to claim anything — `meetsFloors`
  /// requires 120 steps. After 8 s with no pedometer reading, synthesize
  /// steps from credited distance at a 0.78 m stride so the claim loop is
  /// still testable. m/step stays inside the server's 0.30–1.60 band.
  void _maybeEstimateSteps() {
    if (!estimatingSteps) return;
    final v = accumulator.currentVisit;
    if (v == null) return;
    final expected = (v.distanceM / 0.78).floor();
    final missing = expected - v.steps;
    if (missing > 0) accumulator.addSteps(missing, DateTime.now());
  }

  /// Claim any visit that now meets every floor.
  void _checkClaims() {
    final ready = accumulator.readyToSubmit();
    if (ready.isEmpty) return;

    for (final v in ready) {
      _claimed[v.cellId] = ClaimedCell(
        cellId: v.cellId,
        claimedAt: DateTime.now(),
        effort: cfg.computeEffort(v.steps, v.distanceM, v.dwellS),
      );
      onCellClaimed?.call(v.cellId);
    }
    // Phase 2: enqueue to the outbox here instead of dropping.
    accumulator.markSubmitted(ready);
    _saveClaimed();
  }

  /// Fired on a new claim, for the celebration animation + haptic.
  void Function(String cellId)? onCellClaimed;

  double get currentProgress {
    final v = currentVisit;
    return v == null ? 0 : accumulator.progressFor(v);
  }

  Future<void> _loadClaimed() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return;
    try {
      final list = jsonDecode(raw) as List;
      for (final e in list) {
        final c = ClaimedCell.fromJson(Map<String, dynamic>.from(e as Map));
        _claimed[c.cellId] = c;
      }
    } catch (_) {
      // Corrupt state is not worth crashing over; start fresh.
    }
    notifyListeners();
  }

  Future<void> _saveClaimed() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _prefsKey, jsonEncode(_claimed.values.map((c) => c.toJson()).toList()));
  }

  Future<void> resetTerritory() async {
    _claimed.clear();
    accumulator.clear();
    await _saveClaimed();
    notifyListeners();
  }

  @override
  void dispose() {
    _locSub?.cancel();
    _stepSub?.cancel();
    _motionSub?.cancel();
    location.dispose();
    steps.dispose();
    super.dispose();
  }
}

/// Minimal lat/lng holder, avoids leaking a plugin type into the UI layer.
class GeoPoint {
  final double lat;
  final double lng;
  const GeoPoint(this.lat, this.lng);
}
