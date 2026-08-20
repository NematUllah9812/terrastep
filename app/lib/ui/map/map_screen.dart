import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:terrastep_core/domain/models/cell_visit.dart';

import '../../services/cloud_sync.dart';
import '../../services/tracking_coordinator.dart';
import '../widgets/debug_overlay.dart';
import '../widgets/progress_card.dart';

/// The main screen: live position, the H3 grid around you, and your territory.
class MapScreen extends StatefulWidget {
  final TrackingCoordinator tracker;
  const MapScreen({super.key, required this.tracker});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> with WidgetsBindingObserver {
  final _map = MapController();
  bool _followMe = true;
  bool _showDebug = true;
  bool _mapReady = false;
  bool _hydrated = false;

  /// How many rings of hexes to draw around the current cell. 2 rings = 19
  /// hexes, which is plenty on screen and cheap to rebuild every fix.
  static const _ringSize = 2;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.tracker.addListener(_onTracker);
    widget.tracker.onCellClaimed = _celebrate;
    widget.tracker.onClaimedVisits = _uploadClaims;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.tracker.removeListener(_onTracker);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) setState(() {});
  }

  Future<void> _accountSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF0B1220),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Account',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(CloudSync.authLabel(),
                  style: const TextStyle(color: Color(0xFF8FA3C4))),
              const SizedBox(height: 8),
              const Text(
                'Hexes live on this phone until a claim uploads. '
                'Uninstall wipes local hexes. Same account, empty map = '
                'nothing was on the server yet.',
                style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () async {
                  Navigator.pop(ctx);
                  await CloudSync.signOut();
                },
                child: const Text('Sign out'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _uploadClaims(List<CellVisit> visits) async {
    if (!CloudSync.signedIn) {
      widget.tracker.setSync('offline');
      return;
    }
    try {
      final res = await CloudSync.upload(visits);
      if (!mounted) return;
      final msg = res == null
          ? 'skipped'
          : res.ok
              ? 'ok ${res.results.map((r) => r.outcome).join(',')}'
              : (res.error ?? 'fail');
      widget.tracker.setSync(msg);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Cloud: $msg'),
          backgroundColor: (res != null && res.ok)
              ? const Color(0xFF16A34A)
              : const Color(0xFFB91C1C),
          duration: const Duration(seconds: 4),
        ),
      );
    } catch (e) {
      widget.tracker.setSync(e.toString());
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Cloud failed: $e'),
          backgroundColor: const Color(0xFFB91C1C),
          duration: const Duration(seconds: 6),
        ),
      );
    }
  }

  Future<void> _hydrate() async {
    if (_hydrated || !CloudSync.signedIn) return;
    final cell = widget.tracker.currentCell;
    if (cell == null) return;
    try {
      final ids = {
        ...widget.tracker.indexer.disk(cell, 4),
        ...widget.tracker.claimed.keys,
      }.toList();
      final mine = await CloudSync.myCells(ids);
      if (!mounted) return;
      _hydrated = true;
      widget.tracker.mergeServerClaims(mine);
      widget.tracker.setSync(
          mine.isEmpty ? 'cloud 0 hexes' : 'cloud ${mine.length} hexes');
    } catch (e) {
      widget.tracker.setSync('hydrate: $e');
    }
  }

  void _onTracker() {
    if (!mounted) return;
    _hydrate();
    final p = widget.tracker.position;
    // MapController throws if used before FlutterMap has attached.
    if (_mapReady && _followMe && p != null) {
      try {
        _map.move(LatLng(p.lat, p.lng), _map.camera.zoom);
      } catch (_) {}
    }
    setState(() {});
  }

  void _celebrate(String cellId) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Territory claimed  ·  ${cellId.substring(0, 8)}…'),
        backgroundColor: const Color(0xFF16A34A),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  static Color? _hexColor(String? hex) {
    if (hex == null || !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(hex)) return null;
    return Color(int.parse('FF${hex.substring(1)}', radix: 16));
  }

  List<Marker> _nameMarkers() {
    final t = widget.tracker;
    final out = <Marker>[];
    for (final c in t.claimed.values) {
      final n = c.name;
      if (n == null || n.isEmpty) continue;
      try {
        final g = t.indexer.center(c.cellId);
        out.add(Marker(
          point: LatLng(g.lat, g.lon),
          width: 120,
          height: 22,
          child: Center(
            child: Text(
              n,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.bold,
                shadows: [Shadow(blurRadius: 6, color: Colors.black)],
              ),
            ),
          ),
        ));
      } catch (_) {}
    }
    return out;
  }

  Future<void> _onHexLongPress(LatLng latlng) async {
    final t = widget.tracker;
    String cellId;
    try {
      cellId = t.indexer.cellFor(latlng.latitude, latlng.longitude);
    } catch (_) {
      return;
    }
    final mine = t.claimed[cellId];
    if (mine == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Not yours — walk to claim, then long-press to name it.'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    if (!CloudSync.signedIn) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sign in to rename a hex on the server.')),
      );
      return;
    }
    await _editSheet(mine);
  }

  static const _palette = <String>[
    '#3B82F6',
    '#22C55E',
    '#F59E0B',
    '#EF4444',
    '#A855F7',
    '#06B6D4',
  ];

  Future<void> _editSheet(ClaimedCell cell) async {
    final nameCtl = TextEditingController(text: cell.name ?? '');
    var color = cell.color ?? '#3B82F6';
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0B1220),
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            left: 24,
            right: 24,
            top: 16,
            bottom: 24 + MediaQuery.of(ctx).viewInsets.bottom,
          ),
          child: StatefulBuilder(
            builder: (ctx, setLocal) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Name this hex',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text(cell.cellId,
                    style: const TextStyle(
                        fontSize: 11, color: Color(0xFF64748B))),
                const SizedBox(height: 12),
                TextField(
                  controller: nameCtl,
                  maxLength: 32,
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    hintText: 'Hilltop',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final hex in _palette)
                      GestureDetector(
                        onTap: () => setLocal(() => color = hex),
                        child: Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: _hexColor(hex),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: color == hex
                                  ? Colors.white
                                  : Colors.white24,
                              width: color == hex ? 3 : 1,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () async {
                    final name = nameCtl.text.trim();
                    if (name.isEmpty) return;
                    Navigator.pop(ctx);
                    final err = await CloudSync.updateTerritory(
                      cellId: cell.cellId,
                      name: name,
                      color: color,
                    );
                    if (!mounted) return;
                    if (err != null) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Rename failed: $err')),
                      );
                      return;
                    }
                    widget.tracker.setHexStyle(cell.cellId,
                        name: name, color: color);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Saved “$name”')),
                    );
                  },
                  child: const Text('Save'),
                ),
              ],
            ),
          ),
        );
      },
    );
    nameCtl.dispose();
  }

  /// Build the hex polygons: the ring around the player, coloured by state.
  List<Polygon> _hexes() {
    final t = widget.tracker;
    final cell = t.currentCell;
    if (cell == null) return const [];

    final ids = <String>{
      ...t.indexer.disk(cell, _ringSize),
      ...t.claimed.keys,
    };

    final polys = <Polygon>[];
    for (final id in ids) {
      List<LatLng> pts;
      try {
        pts = t.indexer
            .boundary(id)
            .map((c) => LatLng(c.lat, c.lon))
            .toList(growable: false);
      } catch (_) {
        continue;
      }
      if (pts.length < 3) continue;

      final mine = t.claimed[id];
      final isMine = mine != null;
      final isCurrent = id == cell;
      final fill = _hexColor(mine?.color) ?? const Color(0xFF3B82F6);

      polys.add(Polygon(
        points: pts,
        color: isMine
            ? fill.withValues(alpha: 0.45)
            : isCurrent
                ? const Color(0xFFF59E0B).withValues(alpha: 0.18)
                : Colors.white.withValues(alpha: 0.04),
        borderColor: isMine
            ? fill
            : isCurrent
                ? const Color(0xFFF59E0B)
                : Colors.white24,
        borderStrokeWidth: isCurrent ? 3 : 1.5,
      ));
    }
    return polys;
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.tracker;
    final p = t.position;

    return Scaffold(
      backgroundColor: const Color(0xFF0B1220),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: p == null
                  ? const LatLng(34.1688, 73.2215) // Abbottabad
                  : LatLng(p.lat, p.lng),
              initialZoom: 16,
              minZoom: 3,
              maxZoom: 19,
              onMapReady: () => setState(() => _mapReady = true),
              onLongPress: (_, latlng) => _onHexLongPress(latlng),
              onPositionChanged: (_, hasGesture) {
                if (hasGesture && _followMe) setState(() => _followMe = false);
              },
            ),
            children: [
              TileLayer(
                urlTemplate:
                    'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'io.terrastep.app',
                maxZoom: 19,
              ),
              PolygonLayer(polygons: _hexes()),
              MarkerLayer(markers: [
                ..._nameMarkers(),
                if (p != null)
                  Marker(
                    point: LatLng(p.lat, p.lng),
                    width: 22,
                    height: 22,
                    child: const _PositionDot(),
                  ),
              ]),
            ],
          ),

          // OSM attribution is required by their tile usage policy.
          const Positioned(
            right: 4,
            bottom: 2,
            child: Text(
              '© OpenStreetMap contributors',
              style: TextStyle(fontSize: 9, color: Colors.white54),
            ),
          ),

          SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_showDebug) DebugOverlay(tracker: t),
                const Spacer(),
                ProgressCard(tracker: t),
              ],
            ),
          ),
        ],
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (CloudSync.signedIn) ...[
            FloatingActionButton.small(
              heroTag: 'account',
              backgroundColor: const Color(0xFF1D2B4A),
              onPressed: _accountSheet,
              child: const Icon(Icons.person, color: Colors.white),
            ),
            const SizedBox(height: 8),
          ],
          FloatingActionButton.small(
            heroTag: 'debug',
            backgroundColor: const Color(0xFF1D2B4A),
            onPressed: () => setState(() => _showDebug = !_showDebug),
            child: Icon(_showDebug ? Icons.bug_report : Icons.bug_report_outlined,
                color: Colors.white),
          ),
          const SizedBox(height: 8),
          FloatingActionButton(
            heroTag: 'follow',
            backgroundColor:
                _followMe ? const Color(0xFF3B82F6) : const Color(0xFF1D2B4A),
            onPressed: () {
              setState(() => _followMe = true);
              final pp = widget.tracker.position;
              if (pp != null) _map.move(LatLng(pp.lat, pp.lng), 17);
            },
            child: const Icon(Icons.my_location, color: Colors.white),
          ),
        ],
      ),
    );
  }
}

class _HexEditSheet extends StatefulWidget {
  final ClaimedCell cell;
  const _HexEditSheet({required this.cell});

  @override
  State<_HexEditSheet> createState() => _HexEditSheetState();
}

class _HexEditSheetState extends State<_HexEditSheet> {
  late final TextEditingController _name;
  late String _color;
  bool _busy = false;
  String? _err;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.cell.name ?? '');
    _color = (widget.cell.color ?? '#3B82F6').toUpperCase();
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _err = null;
    });
    final color = _color.toLowerCase();
    final err = await CloudSync.updateTerritory(
      cellId: widget.cell.cellId,
      name: name,
      color: color,
    );
    if (!mounted) return;
    if (err != null) {
      setState(() {
        _busy = false;
        _err = err;
      });
      return;
    }
    Navigator.pop(context, (name: name, color: color));
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 16,
        bottom: 24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Name this hex',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(widget.cell.cellId,
              style: const TextStyle(fontSize: 11, color: Color(0xFF64748B))),
          const SizedBox(height: 12),
          TextField(
            controller: _name,
            maxLength: 32,
            enabled: !_busy,
            decoration: const InputDecoration(
              labelText: 'Name',
              hintText: 'Hilltop',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final hex in _MapScreenState._palette)
                GestureDetector(
                  onTap: _busy
                      ? null
                      : () => setState(() => _color = hex.toUpperCase()),
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: _MapScreenState._hexColor(hex),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: _color.toUpperCase() == hex.toUpperCase()
                            ? Colors.white
                            : Colors.white24,
                        width: _color.toUpperCase() == hex.toUpperCase() ? 3 : 1,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          if (_err != null) ...[
            const SizedBox(height: 8),
            Text(_err!, style: const TextStyle(color: Color(0xFFFCA5A5))),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _save,
            child: Text(_busy ? 'Saving…' : 'Save'),
          ),
        ],
      ),
    );
  }
}

class _PositionDot extends StatelessWidget {
  const _PositionDot();

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: const Color(0xFF3B82F6),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 3),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF3B82F6).withValues(alpha: 0.5),
              blurRadius: 12,
              spreadRadius: 3,
            ),
          ],
        ),
      );
}
