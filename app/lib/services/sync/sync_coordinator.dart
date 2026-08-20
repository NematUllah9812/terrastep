import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:terrastep_core/core/game_config.dart';
import 'package:terrastep_core/data/sync_worker.dart';
import 'package:terrastep_core/domain/models/cell_visit.dart';

import 'prefs_outbox.dart';
import 'supabase_claim_api.dart';

/// Owns the [SyncWorker] for the app's lifetime: builds the durable outbox and
/// the real RPC transport, flushes on a timer, and exposes [flushNow] so the
/// host can drain on app resume or after a claim.
///
/// The worker itself has no timer (by design, for testability); this is the
/// thin production shell that decides *when* to flush.
class SyncCoordinator {
  final SupabaseClient client;
  final GameConfig cfg;
  final String clientVersion;
  final void Function(SyncReport report)? onReport;

  late final SyncWorker worker;
  late final PrefsOutbox _outbox;
  Timer? _timer;
  bool _flushing = false;
  DateTime? _lastFlushAt;
  SyncReport? _lastReport;

  SyncCoordinator({
    required this.client,
    required this.clientVersion,
    this.cfg = const GameConfig(),
    this.onReport,
  }) {
    _outbox = PrefsOutbox();
    worker = SyncWorker(
      outbox: _outbox,
      api: SupabaseClaimApi(client),
      clientVersion: clientVersion,
      cfg: cfg,
    );
  }

  PrefsOutbox get outbox => _outbox;
  SyncReport? get lastReport => _lastReport;
  DateTime? get lastFlushAt => _lastFlushAt;

  /// Move ready visits into the durable outbox. Wired into the coordinator's
  /// claim callback so claims persist before the next flush.
  Future<void> enqueue(List<CellVisit> visits) =>
      worker.enqueueVisits(visits);

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(
      Duration(seconds: cfg.syncIntervalS),
      (_) => flushNow(),
    );
    // Try immediately in case a previous session left claims queued.
    unawaited(flushNow());
  }

  /// Drain due batches. Safe to call frequently and concurrently; overlapping
  /// calls are coalesced into the in-flight flush.
  Future<void> flushNow() async {
    if (_flushing) return;
    _flushing = true;
    try {
      final report = await worker.flush();
      _lastFlushAt = DateTime.now();
      if (report.didWork || report.rateLimited || report.errors.isNotEmpty) {
        _lastReport = report;
        onReport?.call(report);
      }
    } catch (e) {
      // The worker maps every expected failure to a SyncReport; a throw here
      // is unexpected and must not kill the timer.
      _lastReport = SyncReport(errors: [e.toString()]);
    } finally {
      _flushing = false;
    }
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}
