import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

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

class _MapScreenState extends State<MapScreen> {
  final _map = MapController();
  bool _followMe = true;
  bool _showDebug = true;
  bool _mapReady = false;

  /// How many rings of hexes to draw around the current cell. 2 rings = 19
  /// hexes, which is plenty on screen and cheap to rebuild every fix.
  static const _ringSize = 2;

  @override
  void initState() {
    super.initState();
    widget.tracker.addListener(_onTracker);
    widget.tracker.onCellClaimed = _celebrate;
  }

  @override
  void dispose() {
    widget.tracker.removeListener(_onTracker);
    super.dispose();
  }

  void _onTracker() {
    if (!mounted) return;
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

      final isMine = t.claimed.containsKey(id);
      final isCurrent = id == cell;

      polys.add(Polygon(
        points: pts,
        color: isMine
            ? const Color(0xFF3B82F6).withValues(alpha: 0.45)
            : isCurrent
                ? const Color(0xFFF59E0B).withValues(alpha: 0.18)
                : Colors.white.withValues(alpha: 0.04),
        borderColor: isMine
            ? const Color(0xFF3B82F6)
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
