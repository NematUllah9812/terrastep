import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'services/h3_indexer.dart';
import 'services/location_service.dart';
import 'services/step_service.dart';
import 'services/tracking_coordinator.dart';
import 'ui/map/map_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TerrastepApp());
}

class TerrastepApp extends StatelessWidget {
  const TerrastepApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Terrastep',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          scaffoldBackgroundColor: const Color(0xFF0B1220),
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF3B82F6),
            brightness: Brightness.dark,
          ),
        ),
        home: const _Boot(),
      );
}

/// Permission gate. Re-runs when the app comes back from Settings so a
/// grant made in App Info actually starts tracking (ISSUES_LOG #28).
class _Boot extends StatefulWidget {
  const _Boot();

  @override
  State<_Boot> createState() => _BootState();
}

class _BootState extends State<_Boot> with WidgetsBindingObserver {
  TrackingCoordinator? _tracker;
  String? _error;
  bool _busy = false;
  bool _gpsOff = false;
  bool _needSettings = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tracker?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _tracker == null && !_busy) {
      _start();
    }
  }

  Future<void> _start() async {
    setState(() {
      _busy = true;
      _error = null;
      _gpsOff = false;
      _needSettings = false;
    });

    final result = await LocationService.requestForeground();
    if (!mounted) return;

    if (result != 'ok') {
      setState(() {
        _busy = false;
        _gpsOff = result == 'gps_off';
        _needSettings = result == 'permanent';
        _error = switch (result) {
          'gps_off' =>
            'Location (GPS) is turned off. Tap “Turn on GPS”, enable it, then come back.',
          'permanent' =>
            'Location permission is blocked. Tap “App settings” → Permissions → Location → Allow.',
          _ =>
            'Terrastep needs location to award territory. Tap Grant and allow it.',
        };
      });
      return;
    }

    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        await Permission.activityRecognition.request();
      } catch (_) {}
    }

    try {
      final t = TrackingCoordinator(
        indexer: H3Indexer(),
        location: LocationService(),
        steps: StepService(),
      );
      await t.init();
      if (!mounted) return;
      setState(() {
        _tracker = t;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Failed to start sensors: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = _tracker;
    if (t != null) return MapScreen(tracker: t);

    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.hexagon_outlined,
                  size: 64, color: Color(0xFF3B82F6)),
              const SizedBox(height: 16),
              const Text('Terrastep',
                  style:
                      TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              const Text('Walk to claim territory.',
                  style: TextStyle(color: Color(0xFF8FA3C4))),
              const SizedBox(height: 28),
              if (_busy)
                const CircularProgressIndicator()
              else ...[
                Text(
                  _error ?? 'Location and steps are used only on this phone.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: _error == null
                        ? const Color(0xFF8FA3C4)
                        : const Color(0xFFFCA5A5),
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton(
                    onPressed: _start, child: const Text('Grant & start')),
                if (_gpsOff)
                  TextButton(
                    onPressed: LocationService.openGpsSettings,
                    child: const Text('Turn on GPS'),
                  ),
                if (_needSettings || _error != null)
                  TextButton(
                    onPressed: LocationService.openAppSettingsPage,
                    child: const Text('App settings'),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
