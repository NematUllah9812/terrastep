import 'package:supabase_flutter/supabase_flutter.dart'
    hide AuthException, TransportException;
import 'package:terrastep_core/data/remote/claim_api.dart';

/// Production [ClaimApi]: calls the `claim_cells` Postgres RPC.
///
/// The core package defines only the interface (and the result/exception
/// types) so its sync logic is unit-testable without a network. This is the
/// thin Supabase binding that actually moves walked effort to the server.
///
/// Error mapping matters:
/// - A thrown transport/5xx becomes [TransportException] (retryable; the
///   batch stays queued with backoff).
/// - A 401/403 becomes [AuthException] (the session is bad; hold the queue
///   until the user re-authenticates — never drop walked data).
/// - A normal business rejection (rate_limited, per-cell reject) is returned
///   inside a [ClaimResult] with `ok: false`, not thrown, because the batch
///   was delivered.
class SupabaseClaimApi implements ClaimApi {
  final SupabaseClient client;
  SupabaseClaimApi(this.client);

  @override
  Future<ClaimResult> claimCells(Map<String, dynamic> params) async {
    try {
      final res = await client.rpc('claim_cells', params: params);
      // Postgres returns a jsonb object. supabase-flutter decodes it to a
      // Map on most platforms; guard the cast.
      final data = Map<String, dynamic>.from(res as Map);
      return ClaimResult.fromJson(data);
    } on PostgrestException catch (e) {
      // SQLSTATE 28000 = invalid_authorization_specification, raised by the
      // function when auth.uid() is null. 42501 = insufficient_privilege.
      // PGRST301 = PostgREST "JWTClaimValidationFailed/ApiaError" (bad JWT).
      if (e.code == '28000' ||
          e.code == '42501' ||
          e.code == 'PGRST301' ||
          e.code == 'PGRST302') {
        throw AuthException(e.message);
      }
      throw TransportException('${e.code ?? 'rpc'}: ${e.message}');
    } catch (e) {
      // SocketException, timeout, client not initialised, decoding errors,
      // and any auth-layer exception. A bad/expired session surfaces in the
      // message; treat anything that looks like an auth failure as such so
      // the worker holds walked data instead of retrying blindly.
      final msg = e.toString();
      final low = msg.toLowerCase();
      if (msg.contains('401') ||
          msg.contains('403') ||
          low.contains('jwt') ||
          low.contains('not authenticated') ||
          low.contains('invalid token') ||
          low.contains('session missing')) {
        throw AuthException(msg);
      }
      throw TransportException(msg);
    }
  }
}
