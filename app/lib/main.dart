import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:terrastep_core/core/game_config.dart';

import 'app_version.dart';
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

class _Boot extends StatefulWidget {
  const _Boot();

  @override
  State<_Boot> createState() => _BootState();
}

class _BootState extends State<_Boot> with WidgetsBindingObserver {
  TrackingCoordinator? _tracker;
  String? _error;
  bool _busy = false;
  bool _needGps = false;
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
      _needGps = false;
      _needSettings = false;
    });

    if (!await Geolocator.isLocationServiceEnabled()) {
      setState(() {
        _busy = false;
        _needGps = true;
        _error = 'Location is turned off. Enable GPS and tap retry.';
      });
      return;
    }

    PermissionStatus loc = PermissionStatus.denied;
    try {
      loc = await Permission.locationWhenInUse.request();
      if (!loc.isGranted) loc = await Permission.location.request();
    } catch (_) {}

    if (!loc.isGranted) {
      final viaGeo = await LocationService.requestForeground();
      if (viaGeo == LocationPermission.deniedForever || loc.isPermanentlyDenied) {
        setState(() {
          _busy = false;
          _needSettings = true;
          _error = 'Location permission was permanently denied. Enable it in '
              'Settings › Apps › Terrastep › Permissions.';
        });
        return;
      }
      if (viaGeo != LocationPermission.always &&
          viaGeo != LocationPermission.whileInUse) {
        setState(() {
          _busy = false;
          _error = 'Terrastep needs location to award you territory.';
        });
        return;
      }
    }

    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        await Permission.activityRecognition.request();
      } catch (_) {}
      try {
        await Permission.notification.request();
      } catch (_) {}
    }

    final t = TrackingCoordinator(
      indexer: H3Indexer(),
      location: LocationService(),
      steps: StepService(),
      cfg: const GameConfig(maxAccuracyM: 80),
    );
    await t.init();

    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        await Permission.ignoreBatteryOptimizations.request();
      } catch (_) {}
    }

    if (!mounted) return;
    setState(() {
      _tracker = t;
      _busy = false;
    });
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
              const SizedBox(height: 4),
              Text(kAppVersion,
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFF64748B))),
              const SizedBox(height: 28),
              if (_busy)
                const CircularProgressIndicator()
              else ...[
                Text(
                  _error ?? '',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Color(0xFFFCA5A5)),
                ),
                const SizedBox(height: 16),
                FilledButton(
                    onPressed: _start, child: const Text('Grant & start')),
                if (_needGps)
                  TextButton(
                    onPressed: Geolocator.openLocationSettings,
                    child: const Text('Turn on GPS'),
                  ),
                if (_needSettings)
                  TextButton(
                    onPressed: Geolocator.openAppSettings,
                    child: const Text('Open settings'),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
