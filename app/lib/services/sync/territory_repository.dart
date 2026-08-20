import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// One owned cell as returned by `get_cells_in_view`. Neutral cells are not
/// stored server-side and therefore never appear here.
@immutable
class ServerCell {
  final String cellId;
  final String ownerId;
  final String? username;
  final String color;
  final String? name;
  final double influence;
  final bool isMine;

  const ServerCell({
    required this.cellId,
    required this.ownerId,
    required this.username,
    required this.color,
    required this.name,
    required this.influence,
    required this.isMine,
  });

  factory ServerCell.fromRow(Map<String, dynamic> r) => ServerCell(
        cellId: r['cell_id'] as String,
        ownerId: r['owner_id'] as String,
        username: r['username'] as String?,
        color: (r['color'] as String?) ?? '#3B82F6',
        name: r['name'] as String?,
        influence: (r['influence'] as num?)?.toDouble() ?? 0,
        isMine: r['is_mine'] == true,
      );
}

/// Fetches ownership for the cells the map is looking at.
///
/// The client computes the set of H3 cells covering the viewport and asks the
/// server only for those (`get_cells_in_view`, capped at 2000 ids). This keeps
/// egress bounded and makes the map authoritative: after login on a fresh
/// install, your previously-walked territory renders from the server, which is
/// the Phase 2 exit criterion (two phones agree).
class TerritoryRepository {
  final SupabaseClient client;
  TerritoryRepository(this.client);

  Future<List<ServerCell>> cellsInView(List<String> cellIds) async {
    if (cellIds.isEmpty) return const [];
    try {
      final res = await client.rpc('get_cells_in_view', params: {
        'p_cells': cellIds,
      });
      final rows = (res as List?) ?? const [];
      return rows
          .map((e) =>
              ServerCell.fromRow(Map<String, dynamic>.from(e as Map)))
          .toList();
    } on PostgrestException catch (e) {
      // View reads are non-fatal: if they fail the map still shows local hexes.
      debugPrint('get_cells_in_view failed: ${e.code} ${e.message}');
      return const [];
    } catch (e) {
      debugPrint('get_cells_in_view failed: $e');
      return const [];
    }
  }
}
