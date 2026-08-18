/// Outcome for a single cell, as returned by `claim_cells()`.
class CellOutcome {
  final String cellId;

  /// One of: claimed, reinforced, captured, contested, rejected.
  final String outcome;

  /// Server-side reason when [outcome] is `rejected` (e.g.
  /// `steps_without_distance`, `implausible_speed`).
  final String? reason;

  final double? myInfluence;
  final double? effort;

  const CellOutcome({
    required this.cellId,
    required this.outcome,
    this.reason,
    this.myInfluence,
    this.effort,
  });

  bool get isOwned => outcome == 'claimed' || outcome == 'captured';
  bool get isRejected => outcome == 'rejected';

  factory CellOutcome.fromJson(Map<String, dynamic> j) => CellOutcome(
        cellId: j['cell_id'] as String,
        outcome: j['outcome'] as String,
        reason: j['reason'] as String?,
        myInfluence: (j['my_influence'] as num?)?.toDouble(),
        effort: (j['effort'] as num?)?.toDouble(),
      );
}

/// Parsed response from `claim_cells()`.
class ClaimResult {
  final bool ok;
  final List<CellOutcome> results;
  final int newlyOwned;

  /// Server error code, e.g. `rate_limited`.
  final String? error;
  final int? retryAfterS;

  /// True when the account is shadow-banned: the server reports success but
  /// writes nothing. The client must behave exactly as if it succeeded.
  final bool shadow;

  const ClaimResult({
    required this.ok,
    this.results = const [],
    this.newlyOwned = 0,
    this.error,
    this.retryAfterS,
    this.shadow = false,
  });

  factory ClaimResult.fromJson(Map<String, dynamic> j) => ClaimResult(
        ok: j['ok'] == true,
        shadow: j['shadow'] == true,
        error: j['error'] as String?,
        retryAfterS: (j['retry_after_s'] as num?)?.toInt(),
        newlyOwned: (j['newly_owned'] as num?)?.toInt() ?? 0,
        results: ((j['results'] as List?) ?? const [])
            .map((e) => CellOutcome.fromJson(
                Map<String, dynamic>.from(e as Map)))
            .toList(),
      );
}

/// Raised for transport-level failures (offline, timeout, 5xx). These are
/// retryable; the batch stays in the outbox.
class TransportException implements Exception {
  final String message;
  const TransportException(this.message);
  @override
  String toString() => 'TransportException: $message';
}

/// Raised when the session is invalid (401/403). Not retryable by backoff —
/// the user must re-authenticate.
class AuthException implements Exception {
  final String message;
  const AuthException(this.message);
  @override
  String toString() => 'AuthException: $message';
}

/// Transport for the claim RPC.
///
/// An interface rather than a concrete Supabase call, so [SyncWorker] is
/// testable without a network or a Supabase project. The production
/// implementation is a thin wrapper:
///
/// ```dart
/// final res = await supabase.rpc('claim_cells', params: params);
/// return ClaimResult.fromJson(Map<String, dynamic>.from(res as Map));
/// ```
abstract class ClaimApi {
  Future<ClaimResult> claimCells(Map<String, dynamic> params);
}
