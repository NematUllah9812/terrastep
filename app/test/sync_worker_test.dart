import 'package:test/test.dart';
import 'package:terrastep/core/game_config.dart';
import 'package:terrastep/data/local/outbox.dart';
import 'package:terrastep/data/remote/claim_api.dart';
import 'package:terrastep/data/sync_worker.dart';
import 'package:terrastep/domain/models/cell_visit.dart';
import 'package:terrastep/domain/session_accumulator.dart';

import 'session_accumulator_test.dart' show FakeIndexer, straightWalk;

/// Scriptable ClaimApi. Records every call so we can assert idempotency —
/// specifically that a retry reuses the same batch_uuid.
class FakeClaimApi implements ClaimApi {
  final List<Map<String, dynamic>> calls = [];

  /// Queue of behaviours, consumed in order. Falls back to [defaultResponse].
  final List<Object> script = [];

  ClaimResult Function(Map<String, dynamic>)? defaultResponse;

  @override
  Future<ClaimResult> claimCells(Map<String, dynamic> params) async {
    calls.add(params);
    if (script.isNotEmpty) {
      final next = script.removeAt(0);
      if (next is Exception) throw next;
      if (next is ClaimResult) return next;
    }
    if (defaultResponse != null) return defaultResponse!(params);
    return _okFor(params);
  }

  static ClaimResult _okFor(Map<String, dynamic> params) {
    final cells = (params['p_cells'] as List).cast<Map<String, dynamic>>();
    return ClaimResult(
      ok: true,
      newlyOwned: cells.length,
      results: cells
          .map((c) => CellOutcome(
              cellId: c['cell_id'] as String,
              outcome: 'claimed',
              myInfluence: 529.5,
              effort: 529.5))
          .toList(),
    );
  }

  Set<String> get batchUuids =>
      calls.map((c) => c['p_batch_uuid'] as String).toSet();
}

/// Controllable clock.
class TestClock {
  DateTime now;
  TestClock(this.now);
  DateTime call() => now;
  void advance(Duration d) => now = now.add(d);
}

CellVisit _visit(String id, {int steps = 400}) {
  final v = CellVisit(
    cellId: id,
    parentRes5: '8528308bfffffff',
    lat: 34.1688,
    lng: 73.2215,
    windowStart: DateTime.utc(2026, 8, 18, 9, 0, 0),
    windowEnd: DateTime.utc(2026, 8, 18, 9, 7, 0),
  );
  v.steps = steps;
  v.distanceM = 310;
  v.dwellS = 400;
  v.fixCount = 78;
  v.addAccuracy(8.2 * 78);
  v.maxSpeed = 1.6;
  return v;
}

void main() {
  late InMemoryOutbox outbox;
  late FakeClaimApi api;
  late TestClock clock;
  late SyncWorker worker;
  var uuidCounter = 0;

  setUp(() {
    outbox = InMemoryOutbox();
    api = FakeClaimApi();
    clock = TestClock(DateTime.utc(2026, 8, 18, 10, 0, 0));
    uuidCounter = 0;
    worker = SyncWorker(
      outbox: outbox,
      api: api,
      clientVersion: 'test-1.0',
      clock: clock.call,
      uuidGen: () => 'batch-${++uuidCounter}',
    );
  });

  // =========================================================================
  // Threshold 2.6 — the airplane-mode acceptance test
  // =========================================================================

  test('2.6 airplane mode: 3 cells walked offline sync exactly once', () async {
    // Offline: the first delivery attempt throws.
    api.script.add(const TransportException('offline'));

    await outbox.add(OutboxEntry(
      batchUuid: 'batch-offline',
      visits: [_visit('cell-a'), _visit('cell-b'), _visit('cell-c')],
      queuedAt: clock.now,
    ));

    // Attempt while offline.
    var report = await worker.flush();
    expect(report.batchesSent, equals(0));
    expect(await outbox.count(), equals(1), reason: 'data must be retained');

    // Backoff is in effect: an immediate retry does nothing.
    report = await worker.flush();
    expect(api.calls.length, equals(1), reason: 'must respect notBefore');

    // Connectivity returns after the backoff window.
    clock.advance(const Duration(minutes: 1));
    report = await worker.flush();

    expect(report.batchesSent, equals(1));
    expect(report.cellsAccepted, equals(3));
    expect(await outbox.count(), equals(0), reason: 'delivered, so dequeued');

    // The critical assertion: the SAME batch uuid throughout, so the server's
    // sync_receipts makes the replay idempotent.
    expect(api.batchUuids, equals({'batch-offline'}));
  });

  // =========================================================================
  // Idempotency
  // =========================================================================

  group('idempotency', () {
    test('retries reuse the original batch uuid', () async {
      api.script.addAll([
        const TransportException('timeout'),
        const TransportException('timeout'),
      ]);
      // (two failures, then the default success response)
      await outbox.add(OutboxEntry(
        batchUuid: 'stable-uuid',
        visits: [_visit('cell-x')],
        queuedAt: clock.now,
      ));

      await worker.flush();
      clock.advance(const Duration(minutes: 1));
      await worker.flush();
      clock.advance(const Duration(minutes: 5));
      await worker.flush();

      expect(api.calls.length, equals(3));
      expect(api.batchUuids, equals({'stable-uuid'}),
          reason: 'a new uuid per retry would double-count influence');
    });

    test('each enqueued batch gets a distinct uuid', () async {
      final acc = SessionAccumulator(
          cfg: const GameConfig(), indexer: FakeIndexer());
      // Walk far enough to fill several cells.
      for (final f in straightWalk(
          startLat: 34.1688, startLng: 73.2215, n: 400, intervalS: 5)) {
        acc.addFix(f);
        acc.addSteps(9, f.at);
      }

      await worker.enqueueFrom(acc);
      final entries = await outbox.all();
      final uuids = entries.map((e) => e.batchUuid).toSet();
      expect(uuids.length, equals(entries.length));
    });
  });

  // =========================================================================
  // Batching
  // =========================================================================

  group('batching', () {
    test('splits large submissions into bounded batches', () async {
      final acc = SessionAccumulator(
          cfg: const GameConfig(), indexer: FakeIndexer());
      for (final f in straightWalk(
          startLat: 34.1688, startLng: 73.2215, n: 900, intervalS: 5)) {
        acc.addFix(f);
        acc.addSteps(9, f.at);
      }

      final queued = await worker.enqueueFrom(acc);
      final entries = await outbox.all();

      expect(queued, greaterThan(SyncWorker.maxCellsPerBatch),
          reason: 'need enough cells to force a split');
      expect(entries.length, greaterThan(1));
      for (final e in entries) {
        expect(e.visits.length,
            lessThanOrEqualTo(SyncWorker.maxCellsPerBatch));
      }
    });

    test('accumulator is drained only after the outbox has the data', () async {
      final acc = SessionAccumulator(
          cfg: const GameConfig(), indexer: FakeIndexer());
      for (final f in straightWalk(
          startLat: 34.1688, startLng: 73.2215, n: 120, intervalS: 5)) {
        acc.addFix(f);
        acc.addSteps(9, f.at);
      }
      expect(acc.readyToSubmit(), isNotEmpty);

      await worker.enqueueFrom(acc);

      expect(acc.readyToSubmit(), isEmpty, reason: 'drained');
      expect(await outbox.count(), greaterThan(0), reason: 'persisted first');
    });

    test('enqueueing nothing is a no-op', () async {
      final acc = SessionAccumulator(
          cfg: const GameConfig(), indexer: FakeIndexer());
      expect(await worker.enqueueFrom(acc), equals(0));
      expect(await outbox.count(), equals(0));
    });
  });

  // =========================================================================
  // Backoff
  // =========================================================================

  group('backoff', () {
    test('is exponential and capped at 15 minutes', () {
      expect(SyncWorker.backoffFor(1), const Duration(seconds: 30));
      expect(SyncWorker.backoffFor(2), const Duration(minutes: 1));
      expect(SyncWorker.backoffFor(3), const Duration(minutes: 2));
      expect(SyncWorker.backoffFor(4), const Duration(minutes: 4));
      expect(SyncWorker.backoffFor(5), const Duration(minutes: 8));
      expect(SyncWorker.backoffFor(6), const Duration(minutes: 15));
      expect(SyncWorker.backoffFor(20), const Duration(minutes: 15),
          reason: 'must not grow unbounded');
    });

    test('a poisoned batch is dropped rather than blocking the queue',
        () async {
      for (var i = 0; i < SyncWorker.maxAttempts + 2; i++) {
        api.script.add(const TransportException('always fails'));
      }
      await outbox.add(OutboxEntry(
        batchUuid: 'poison',
        visits: [_visit('bad-cell')],
        queuedAt: clock.now,
      ));

      for (var i = 0; i < SyncWorker.maxAttempts + 1; i++) {
        await worker.flush();
        clock.advance(const Duration(minutes: 20));
      }

      expect(await outbox.count(), equals(0),
          reason: 'must give up eventually');
    });
  });

  // =========================================================================
  // Server responses
  // =========================================================================

  group('server responses', () {
    test('rate limiting backs off the whole queue', () async {
      api.script.add(const ClaimResult(
          ok: false, error: 'rate_limited', retryAfterS: 3600));

      await outbox.add(OutboxEntry(
          batchUuid: 'b1', visits: [_visit('c1')], queuedAt: clock.now));
      await outbox.add(OutboxEntry(
          batchUuid: 'b2', visits: [_visit('c2')], queuedAt: clock.now));

      final report = await worker.flush();

      expect(report.rateLimited, isTrue);
      expect(api.calls.length, equals(1),
          reason: 'stop after the first rate-limit, do not hammer');
      expect(await outbox.count(), equals(2), reason: 'nothing lost');

      // Still backed off well before the hour is up.
      clock.advance(const Duration(minutes: 30));
      await worker.flush();
      expect(api.calls.length, equals(1));

      // ...and resumes afterwards.
      clock.advance(const Duration(minutes: 31));
      await worker.flush();
      expect(api.calls.length, greaterThan(1));
    });

    test('rate limiting holds ALL batches, not just the one that hit it',
        () async {
      // Regression guard (ISSUES_LOG #19): the worker originally backed off
      // only the current batch, so the very next flush hammered the server
      // with the next batch while still rate-limited — burning quota and
      // raising our own suspicion score.
      api.script.add(const ClaimResult(
          ok: false, error: 'rate_limited', retryAfterS: 600));

      for (var i = 1; i <= 4; i++) {
        await outbox.add(OutboxEntry(
            batchUuid: 'b$i', visits: [_visit('c$i')], queuedAt: clock.now));
      }

      await worker.flush();
      expect(api.calls.length, equals(1));

      // Every remaining batch must be held, not just 'b1'.
      final held = await outbox.all();
      expect(held.length, equals(4));
      for (final e in held) {
        expect(e.notBefore.isAfter(clock.now), isTrue,
            reason: '${e.batchUuid} must be delayed by the account-wide limit');
      }

      // A flush during the window must not touch the network at all.
      clock.advance(const Duration(minutes: 5));
      await worker.flush();
      expect(api.calls.length, equals(1));
    });

    test('rate limiting does not count against the poison threshold', () async {
      api.script.add(const ClaimResult(
          ok: false, error: 'rate_limited', retryAfterS: 60));
      await outbox.add(OutboxEntry(
          batchUuid: 'rl', visits: [_visit('c')], queuedAt: clock.now));

      await worker.flush();

      final entry = (await outbox.all()).single;
      expect(entry.attempts, equals(0),
          reason: 'server throttling is not the batch being bad');
    });

    test('per-cell rejections are counted but do not fail the batch', () async {
      api.script.add(const ClaimResult(ok: true, newlyOwned: 1, results: [
        CellOutcome(cellId: 'good', outcome: 'claimed'),
        CellOutcome(
            cellId: 'bad',
            outcome: 'rejected',
            reason: 'steps_without_distance'),
      ]));
      await outbox.add(OutboxEntry(
        batchUuid: 'mixed',
        visits: [_visit('good'), _visit('bad')],
        queuedAt: clock.now,
      ));

      final report = await worker.flush();

      expect(report.cellsAccepted, equals(1));
      expect(report.cellsRejected, equals(1));
      expect(report.errors.any((e) => e.contains('steps_without_distance')),
          isTrue);
      expect(await outbox.count(), equals(0),
          reason: 'batch was delivered; rejections are final, not retryable');
    });

    test('shadow ban looks like success to the client', () async {
      api.script.add(const ClaimResult(ok: true, shadow: true));
      await outbox.add(OutboxEntry(
          batchUuid: 'sb', visits: [_visit('c')], queuedAt: clock.now));

      final report = await worker.flush();

      expect(report.batchesSent, equals(1));
      expect(await outbox.count(), equals(0),
          reason: 'client must not detect the ban by observing retries');
    });

    test('auth failure retains data and stops the round', () async {
      api.script.add(const AuthException('JWT expired'));
      await outbox.add(OutboxEntry(
          batchUuid: 'a1', visits: [_visit('c1')], queuedAt: clock.now));
      await outbox.add(OutboxEntry(
          batchUuid: 'a2', visits: [_visit('c2')], queuedAt: clock.now));

      final report = await worker.flush();

      expect(report.batchesSent, equals(0));
      expect(await outbox.count(), equals(2), reason: 'never lose walked data');
      expect(api.calls.length, equals(1), reason: 'stop, do not spam');
      expect(report.errors.first, contains('auth'));
    });
  });

  // =========================================================================
  // Ordering
  // =========================================================================

  test('oldest batches are delivered first', () async {
    await outbox.add(OutboxEntry(
        batchUuid: 'old',
        visits: [_visit('c1')],
        queuedAt: clock.now.subtract(const Duration(hours: 2))));
    await outbox.add(OutboxEntry(
        batchUuid: 'new', visits: [_visit('c2')], queuedAt: clock.now));

    await worker.flush();

    expect(api.calls.first['p_batch_uuid'], equals('old'));
  });

  test('client version is sent for server-side forensics', () async {
    await outbox.add(OutboxEntry(
        batchUuid: 'v', visits: [_visit('c')], queuedAt: clock.now));
    await worker.flush();
    expect(api.calls.first['p_client_version'], equals('test-1.0'));
  });
}
