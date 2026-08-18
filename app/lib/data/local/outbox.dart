import '../../domain/models/cell_visit.dart';

/// One queued batch of cell visits awaiting delivery to `claim_cells()`.
///
/// The [batchUuid] is generated **once** when the entry is created and reused
/// on every retry. That is what makes retries free: the server's
/// `sync_receipts` table returns the cached result for a repeated uuid instead
/// of double-counting the influence.
class OutboxEntry {
  final String batchUuid;
  final List<CellVisit> visits;
  final DateTime queuedAt;

  /// Delivery attempts so far. Drives the backoff schedule.
  int attempts;

  /// Earliest time this entry may be retried.
  DateTime notBefore;

  /// Last transport/server error, for diagnostics.
  String? lastError;

  OutboxEntry({
    required this.batchUuid,
    required this.visits,
    required this.queuedAt,
    this.attempts = 0,
    DateTime? notBefore,
    this.lastError,
  }) : notBefore = notBefore ?? queuedAt;

  Map<String, dynamic> toRpcParams(String clientVersion) => {
        'p_batch_uuid': batchUuid,
        'p_cells': visits.map((v) => v.toJson()).toList(),
        'p_client_version': clientVersion,
      };
}

/// Durable queue of pending claims.
///
/// **The outbox is the source of truth; the network is best-effort.** Visits
/// are written here *before* any RPC is attempted, so a crash, a force-quit or
/// a dead connection can never lose a claim the user earned by walking.
///
/// Production backs this with Drift/SQLite. [InMemoryOutbox] is used in tests
/// and lets the sync logic be verified with no I/O.
abstract class Outbox {
  Future<void> add(OutboxEntry entry);

  /// Entries eligible for delivery now (respecting [OutboxEntry.notBefore]),
  /// oldest first, at most [limit].
  Future<List<OutboxEntry>> due({required DateTime now, int limit = 5});

  /// Remove a successfully delivered entry.
  Future<void> remove(String batchUuid);

  /// Persist a failed attempt: bump attempts, set the next retry time.
  Future<void> recordFailure(
      String batchUuid, String error, DateTime notBefore);

  /// Delay **every** queued entry until [notBefore].
  ///
  /// Used for account-wide conditions — rate limiting, expired auth — where
  /// the problem is not with a particular batch. Without this, a rate-limited
  /// client would immediately retry with the *next* batch, burn more quota and
  /// raise its own server-side suspicion score.
  Future<void> backoffAll(String error, DateTime notBefore);

  Future<int> count();

  /// Everything queued, for the debug screen.
  Future<List<OutboxEntry>> all();
}

class InMemoryOutbox implements Outbox {
  final Map<String, OutboxEntry> _entries = {};

  @override
  Future<void> add(OutboxEntry entry) async {
    _entries[entry.batchUuid] = entry;
  }

  @override
  Future<List<OutboxEntry>> due({required DateTime now, int limit = 5}) async {
    final ready = _entries.values
        .where((e) => !e.notBefore.isAfter(now))
        .toList()
      ..sort((a, b) => a.queuedAt.compareTo(b.queuedAt));
    return ready.take(limit).toList();
  }

  @override
  Future<void> remove(String batchUuid) async => _entries.remove(batchUuid);

  @override
  Future<void> recordFailure(
      String batchUuid, String error, DateTime notBefore) async {
    final e = _entries[batchUuid];
    if (e == null) return;
    e.attempts++;
    e.lastError = error;
    e.notBefore = notBefore;
  }

  @override
  Future<void> backoffAll(String error, DateTime notBefore) async {
    for (final e in _entries.values) {
      // Do not bump `attempts`: this isn't the batch's fault, and counting it
      // would push healthy batches toward the poison threshold.
      e.lastError = error;
      if (e.notBefore.isBefore(notBefore)) e.notBefore = notBefore;
    }
  }

  @override
  Future<int> count() async => _entries.length;

  @override
  Future<List<OutboxEntry>> all() async => _entries.values.toList();
}
