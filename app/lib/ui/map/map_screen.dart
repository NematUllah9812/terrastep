import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:terrastep_core/domain/session_accumulator.dart';

import '../../services/h3_indexer.dart';
import '../../services/sync/territory_repository.dart';
import '../../services/tracking_coordinator.dart';
import '../widgets/debug_overlay.dart';
import '../widgets/progress_card.dart';

/// The main screen: live position, the H3 grid around you, and territory.
///
/// When [territory] is provided (logged in), the map is server-authoritative:
/// it samples the H3 cells in the viewport, asks `get_cells_in_view` who owns
/// them, and colours those hexes. Your own walked hexes render blue
/// optimistically; other players' render in their faction colour. This is what
/// makes a reinstall restore your territory and lets two phones agree (the
/// Phase 2 exit criterion).
class MapScreen extends StatefulWidget {
  final TrackingCoordinator tracker;
  final TerritoryRepository? territory;
  final CellIndexer? indexer;
  const MapScreen({
    super.key,
    required this.tracker,
    this.territory,
    this.indexer,
  });

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> with WidgetsBindingObserver {
  final _map = MapController();
  bool _followMe = true;
  bool _showDebug = true;
  bool _mapReady = false;

  /// How many rings of hexes to draw around the current cell. 2 rings = 19
  /// hexes, which is plenty on screen and cheap to rebuild every fix.
  static const _ringSize = 2;

  /// Viewport sampling for server ownership queries. At z>=14 a res-9 hex is
  /// ~0.1 km²; a ~70 m grid samples every visible hex without overlap. Below
  /// that zoom we don't query (hexes too small to be meaningful on screen).
  static const _sampleMinZoom = 14.0;
  static const _sampleStepM = 75.0;
  static const _sampleCap = 600;

  Timer? _viewDebounce;
  bool _loadingView = false;
  int _viewGeneration = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.tracker.addListener(_onTracker);
    widget.tracker.onCellClaimed = _celebrate;
  }

  @override
  void dispose() {
    _viewDebounce?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    widget.tracker.removeListener(_onTracker);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      _scheduleViewRefresh();
    }
  }

  /// Sample the H3 cells in the current viewport and ask the server who owns
  /// them. Debounced so panning/zooming doesn't fire an RPC per frame. No-op
  /// offline (no [territory] repository).
  void _scheduleViewRefresh() {
    if (widget.territory == null || widget.indexer == null) return;
    _viewDebounce?.cancel();
    _viewDebounce = Timer(const Duration(milliseconds: 450), _refreshView);
  }

  Future<void> _refreshView() async {
    final repo = widget.territory;
    final indexer = widget.indexer;
    if (repo == null || indexer == null || !_mapReady || !mounted) return;
    if (_map.camera.zoom < _sampleMinZoom) return;

    final gen = ++_viewGeneration;
    setState(() => _loadingView = true);

    final bounds = _map.camera.visibleBounds;
    final ids = _sampleCells(indexer, bounds);
    if (ids.isEmpty) {
      if (mounted) setState(() => _loadingView = false);
      return;
    }

    final cells = await repo.cellsInView(ids.toList());
    if (!mounted || gen != _viewGeneration) return;
    widget.tracker.setServerCells(cells);
    setState(() => _loadingView = false);
  }

  /// Walk the viewport in [_sampleStepM] steps, mapping each sample to its
  /// res-9 cell. Returns the unique set, capped at [_sampleCap].
  Set<String> _sampleCells(CellIndexer indexer, LatLngBounds bounds) {
    const metersPerDegLat = 111320.0;
    final lat = bounds.center.latitude;
    final metersPerDegLng =
        111320.0 * math.cos(lat * math.pi / 180.0).abs();

    final stepLat = _sampleStepM / metersPerDegLat;
    final stepLng =
        _sampleStepM / (metersPerDegLng == 0 ? 1 : metersPerDegLng);

    final ids = <String>{};
    for (var y = bounds.south; y <= bounds.north; y += stepLat) {
      for (var x = bounds.west; x <= bounds.east; x += stepLng) {
        ids.add(indexer.cellFor(y, x));
        if (ids.length >= _sampleCap) return ids;
      }
    }
    return ids;
  }

  void _onTracker() {
    if (!mounted) return;
    final p = widget.tracker.position;
    // MapController throws if used before FlutterMap has attached.
    if (_mapReady && _followMe && p != null) {
      try {
        _map.move(LatLng(p.lat, p.lng), _map.camera.zoom);
      } catch (_) {}
      // Moving changes the viewport; refresh server ownership for it.
      _scheduleViewRefresh();
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

  /// Build the hex polygons: the ring around the player plus every
  /// server-owned cell in view, coloured by ownership.
  List<Polygon> _hexes() {
    final t = widget.tracker;
    final cell = t.currentCell;

    final ids = <String>{
      ...t.serverCells.keys,
      ...t.claimed.keys,
    };
    if (cell != null) ids.addAll(t.indexer.disk(cell, _ringSize));
    if (ids.isEmpty) return const [];

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

      final local = t.claimed[id];
      final server = t.serverCells[id];
      final isCurrent = id == cell;

      // A local optimistic claim is "mine". Otherwise trust the server, which
      // is also what restores your hexes after a reinstall (2.8 exit).
      final isMine = local != null || (server?.isMine ?? false);
      final ownerColor = _colorFor(server?.color);
      final otherOwned = server != null && !server.isMine;

      polys.add(Polygon(
        points: pts,
        color: isMine
            ? const Color(0xFF3B82F6).withValues(alpha: 0.45)
            : otherOwned
                ? ownerColor.withValues(alpha: 0.40)
                : isCurrent
                    ? const Color(0xFFF59E0B).withValues(alpha: 0.18)
                    : Colors.white.withValues(alpha: 0.04),
        borderColor: isMine
            ? const Color(0xFF3B82F6)
            : otherOwned
                ? ownerColor
                : isCurrent
                    ? const Color(0xFFF59E0B)
                    : Colors.white24,
        borderStrokeWidth: isCurrent ? 3 : 1.5,
      ));
    }
    return polys;
  }

  static Color _colorFor(String? hex) {
    if (hex == null || hex.length != 7 || !hex.startsWith('#')) {
      return const Color(0xFFA855F7);
    }
    final v = int.tryParse(hex.substring(1), radix: 16);
    if (v == null) return const Color(0xFFA855F7);
    return Color(0xFF000000 | v);
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
              onMapReady: () {
                setState(() => _mapReady = true);
                _scheduleViewRefresh();
              },
              onPositionChanged: (_, hasGesture) {
                if (hasGesture && _followMe) setState(() => _followMe = false);
                _scheduleViewRefresh();
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
              if (p != null)
                MarkerLayer(markers: [
                  Marker(
                    point: LatLng(p.lat, p.lng),
                    width: 22,
                    height: 22,
                    child: const _PositionDot(),
                  ),
                ]),
            ],
          ),

          if (widget.territory != null)
            Positioned(
              left: 12,
              bottom: 2,
              child: _SyncPill(
                loading: _loadingView,
                serverHexes: widget.tracker.serverCells.length,
                myServerHexes: widget.tracker.serverOwnedMine.length,
              ),
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

class _SyncPill extends StatelessWidget {
  final bool loading;
  final int serverHexes;
  final int myServerHexes;
  const _SyncPill({
    required this.loading,
    required this.serverHexes,
    required this.myServerHexes,
  });

  @override
  Widget build(BuildContext context) {
    final color = loading ? const Color(0xFFFBBF24) : const Color(0xFF22C55E);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xCC0B1220),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 8,
            height: 8,
            child: loading
                ? const CircularProgressIndicator(strokeWidth: 1.5)
                : Icon(Icons.cloud_done, size: 10, color: color),
          ),
          const SizedBox(width: 6),
          Text(
            loading ? 'sync…' : 'cloud  mine:$myServerHexes  view:$serverHexes',
            style: TextStyle(
                fontSize: 9.5,
                color: color,
                fontFamily: 'monospace',
                fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
