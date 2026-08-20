import 'dart:math';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:terrastep_core/data/remote/claim_api.dart';
import 'package:terrastep_core/domain/models/cell_visit.dart';

import '../app_version.dart';
import '../config/supabase_env.dart';
import 'tracking_coordinator.dart';

/// Thin Supabase adapter. Login / claim upload / hydrate. Failures must
/// never break local walking.
class CloudSync {
  CloudSync._();

  static bool get signedIn {
    if (!SupabaseEnv.configured) return false;
    try {
      return Supabase.instance.client.auth.currentUser != null;
    } catch (_) {
      return false;
    }
  }

  static User? get user {
    if (!SupabaseEnv.configured) return null;
    try {
      return Supabase.instance.client.auth.currentUser;
    } catch (_) {
      return null;
    }
  }

  /// Overlay / dump line. `email · walker_xxxxxxxx` matches the SQL
  /// `handle_new_user` username so we can tell if the uid changed.
  static String authLabel() {
    if (!SupabaseEnv.configured) return 'no-key';
    final u = user;
    if (u == null) return 'offline';
    final walker = 'walker_${u.id.replaceAll('-', '').substring(0, 8)}';
    final email = u.email;
    if (email == null || email.isEmpty) return walker;
    return '$email · $walker';
  }

  static Future<void> signOut() async {
    if (!SupabaseEnv.configured) return;
    await Supabase.instance.client.auth.signOut();
  }

  static Future<ClaimResult?> upload(List<CellVisit> visits) async {
    if (!signedIn || visits.isEmpty) return null;
    final res = await Supabase.instance.client.rpc(
      'claim_cells',
      params: {
        'p_batch_uuid': _uuid(),
        'p_cells': visits.map((v) => v.toJson()).toList(),
        'p_client_version': kAppVersion,
      },
    );
    if (res is Map) {
      return ClaimResult.fromJson(Map<String, dynamic>.from(res));
    }
    return ClaimResult.fromJson({'ok': true, 'results': res});
  }

  /// Server hexes you own among [cellIds]. Empty if offline or none yet.
  static Future<List<ClaimedCell>> myCells(List<String> cellIds) async {
    if (!signedIn || cellIds.isEmpty) return const [];
    final res = await Supabase.instance.client.rpc(
      'get_cells_in_view',
      params: {'p_cells': cellIds},
    );
    final rows = (res as List?) ?? const [];
    final mine = <ClaimedCell>[];
    for (final r in rows) {
      final m = Map<String, dynamic>.from(r as Map);
      if (m['is_mine'] != true || m['cell_id'] is! String) continue;
      mine.add(ClaimedCell(
        cellId: m['cell_id'] as String,
        claimedAt: DateTime.now(),
        effort: (m['influence'] as num?)?.toDouble() ?? 0,
        name: m['name'] as String?,
        color: m['color'] as String?,
      ));
    }
    return mine;
  }

  static Future<String?> updateTerritory({
    required String cellId,
    String? name,
    String? color,
  }) async {
    if (!signedIn) return 'not signed in';
    final res = await Supabase.instance.client.rpc(
      'update_territory',
      params: {
        'p_cell_id': cellId,
        'p_name': name,
        'p_color': color?.toLowerCase(),
      },
    );
    if (res is Map) {
      final ok = res['ok'] == true;
      if (ok) return null;
      return (res['error'] as String?) ?? 'fail';
    }
    return null;
  }

  static String _uuid() {
    final rnd = Random.secure();
    String hex(int n) =>
        List.generate(n, (_) => rnd.nextInt(16).toRadixString(16)).join();
    return '${hex(8)}-${hex(4)}-4${hex(3)}-'
        '${(8 + rnd.nextInt(4)).toRadixString(16)}${hex(3)}-${hex(12)}';
  }
}
