import 'dart:math' as math;

import '../core/game_config.dart';
import '../domain/models/cell_visit.dart';
import '../domain/session_accumulator.dart';
import 'local/outbox.dart';
import 'remote/claim_api.dart';

/// Result of one flush, for the debug overlay and telemetry.
class SyncReport {
  final int batchesSent;
  final int cellsAccepted;
  final int cellsRejected;
  final int newlyOwned;
  final bool rateLimited;
  final List<String> errors;

  const SyncReport({
    this.batchesSent = 0,
    this.cellsAccepted = 0,
    this.cellsRejected = 0,
    this.newlyOwned = 0,
    this.rateLimited = false,
    this.errors = const [],
  });

  bool get didWork => batchesSent > 0;
}

/// Moves accumulated visits from the device to the server.
///
/// Responsibilities, in order:
/// 1. Drain [SessionAccumulator.readyToSubmit] into the durable [Outbox].
/// 2. Deliver due batches, oldest first.
/// 3. Retry with exponential backoff, reusing the same `batch_uuid` so the
///    server's `sync_receipts` table makes replays idempotent.
///
/// Deliberately has no timer of its own — the caller decides when to
/// [flush] (a periodic timer, connectivity regained, app resumed). That keeps
/// it testable with a synthetic clock.
class SyncWorker {
  final Outbox outbox;
  final ClaimApi api;
  final GameConfig cfg;
  final String clientVersion;

  /// Injectable clock so tests can control backoff without waiting.
  final DateTime Function() clock;

  /// Injectable uuid generator so tests get deterministic batch ids.
  final String Function() uuidGen;

  /// Max cells per RPC call. Keeps the payload small (egress is the binding
  /// free-tier constraint) and bounds how much one failure can hold up.
  static const int maxCellsPerBatch = 25;

  /// Backoff schedule. Capped at 15 minutes so a device that comes back online
  /// after a long outage syncs promptly rather than sitting in a long sleep.
  static const Duration baseBackoff = Duration(seconds: 30);
  static const Duration maxBackoff = Duration(minutes: 15);

  /// After this many failures the batch is considered poisoned and dropped, so
  /// one malformed payload can't block the queue forever.
  static const int maxAttempts = 8;

  SyncWorker({
    required this.outbox,
    required this.api,
    required this.clientVersion,
    this.cfg = const GameConfig(),
    DateTime Function()? clock,
    String Function()? uuidGen,
  })  : clock = clock ?? DateTime.now,
        uuidGen = uuidGen ?? _defaultUuid;

  /// Move claim-ready visits out of [acc] and into the outbox.
  ///
  /// Called before every flush. Splitting into batches of [maxCellsPerBatch]
  /// bounds payload size; each batch gets its own uuid so a partial failure
  /// only retries the affected batch.
  Future<int> enqueueFrom(SessionAccumulator acc) async {
    final ready = acc.readyToSubmit();
    if (ready.isEmpty) return 0;

    var queued = 0;
    for (var i = 0; i < ready.length; i += maxCellsPerBatch) {
      final chunk = ready.sublist(
          i, math.min(i + maxCellsPerBatch, ready.length));
      await outbox.add(OutboxEntry(
        batchUuid: uuidGen(),
        visits: List<CellVisit>.from(chunk),
        queuedAt: clock(),
      ));
      queued += chunk.length;
    }

    // Remove from the accumulator only after the outbox has them, so a crash
    // between the two loses nothing.
    acc.markSubmitted(ready);
    return queued;
  }

  /// Attempt delivery of all due batches.
  ///
  /// Safe to call when offline: transport failures leave batches queued with a
  /// later [OutboxEntry.notBefore].
  Future<SyncReport> flush() async {
    final now = clock();
    final due = await outbox.due(now: now, limit: 5);
    if (due.isEmpty) return const SyncReport();

    var sent = 0, accepted = 0, rejected = 0, owned = 0;
    var rateLimited = false;
    final errors = <String>[];

    for (final entry in due) {
      try {
        final res = await api.claimCells(entry.toRpcParams(clientVersion));

        if (!res.ok && res.error == 'rate_limited') {
          // Account-wide, not this batch's fault. Delay the ENTIRE queue:
          // retrying with the next batch would burn more quota and raise our
          // own suspicion score server-side.
          rateLimited = true;
          final wait = Duration(seconds: res.retryAfterS ?? 3600);
          await outbox.backoffAll('rate_limited', clock().add(wait));
          errors.add('rate_limited');
          break;
        }

        if (!res.ok) {
          await _backoff(entry, res.error ?? 'server_error');
          errors.add(res.error ?? 'server_error');
          continue;
        }

        // Success (including the shadow-banned case, which reports ok).
        sent++;
        owned += res.newlyOwned;
        for (final r in res.results) {
          if (r.isRejected) {
            rejected++;
            errors.add('${r.cellId}: ${r.reason}');
          } else {
            accepted++;
          }
        }
        await outbox.remove(entry.batchUuid);
      } on AuthException catch (e) {
        // The session is invalid for every batch, not just this one. Hold the
        // whole queue and don't count attempts — the data is fine, the token
        // isn't.
        await outbox.backoffAll(
            e.message, clock().add(const Duration(minutes: 5)));
        errors.add('auth: ${e.message}');
        break;
      } on TransportException catch (e) {
        // Offline: this batch backs off (it did fail), but the rest of the
        // queue is held too, since further attempts would also fail.
        await _backoff(entry, e.message);
        await outbox.backoffAll(
            e.message, clock().add(backoffFor(entry.attempts + 1)));
        errors.add(e.message);
        break;
      } catch (e) {
        await _backoff(entry, e.toString());
        errors.add(e.toString());
      }
    }

    return SyncReport(
      batchesSent: sent,
      cellsAccepted: accepted,
      cellsRejected: rejected,
      newlyOwned: owned,
      rateLimited: rateLimited,
      errors: errors,
    );
  }

  Future<void> _backoff(OutboxEntry entry, String error) async {
    if (entry.attempts + 1 >= maxAttempts) {
      // Poisoned batch. Drop it rather than block the queue forever.
      await outbox.remove(entry.batchUuid);
      return;
    }
    final delay = backoffFor(entry.attempts + 1);
    await outbox.recordFailure(entry.batchUuid, error, clock().add(delay));
  }

  /// Exponential backoff with a cap: 30 s, 1 m, 2 m, 4 m, 8 m, 15 m, 15 m...
  static Duration backoffFor(int attempts) {
    final seconds = baseBackoff.inSeconds * math.pow(2, attempts - 1);
    final capped = math.min(seconds.toDouble(), maxBackoff.inSeconds.toDouble());
    return Duration(seconds: capped.round());
  }

  static String _defaultUuid() {
    // RFC-4122 v4, good enough for an idempotency key. Production may prefer
    // package:uuid, but avoiding the dependency keeps this layer pure.
    final rnd = math.Random.secure();
    String hex(int n) => List.generate(
        n, (_) => rnd.nextInt(16).toRadixString(16)).join();
    return '${hex(8)}-${hex(4)}-4${hex(3)}-'
        '${(8 + rnd.nextInt(4)).toRadixString(16)}${hex(3)}-${hex(12)}';
  }
}
