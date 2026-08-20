import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_version.dart';
import 'config/supabase_env.dart';
import 'services/h3_indexer.dart';
import 'services/location_service.dart';
import 'services/step_service.dart';
import 'services/sync/sync_coordinator.dart';
import 'services/sync/territory_repository.dart';
import 'services/tracking_coordinator.dart';
import 'ui/auth/login_screen.dart';
import 'ui/map/map_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (SupabaseEnv.configured) {
    await Supabase.initialize(
      url: SupabaseEnv.url,
      anonKey: SupabaseEnv.anonKey,
    );
  }
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
        home: const _Gate(),
      );
}

/// Login (if configured) → permissions → map.
class _Gate extends StatefulWidget {
  const _Gate();

  @override
  State<_Gate> createState() => _GateState();
}

class _GateState extends State<_Gate> {
  bool _offline = false;

  Session? get _session {
    if (!SupabaseEnv.configured) return null;
    try {
      return Supabase.instance.client.auth.currentSession;
    } catch (_) {
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    if (SupabaseEnv.configured) {
      Supabase.instance.client.auth.onAuthStateChange.listen((_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final signedIn = _session != null;
    if (!signedIn && !_offline && SupabaseEnv.configured) {
      return LoginScreen(onOffline: () => setState(() => _offline = true));
    }
    return const _Boot();
  }
}

class _Boot extends StatefulWidget {
  const _Boot();

  @override
  State<_Boot> createState() => _BootState();
}

class _BootState extends State<_Boot> with WidgetsBindingObserver {
  TrackingCoordinator? _tracker;
  SyncCoordinator? _sync;
  TerritoryRepository? _territory;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sync?.dispose();
    _tracker?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Returning to foreground may have queued claims or restored connectivity
    // — drain promptly rather than waiting for the periodic timer.
    if (state == AppLifecycleState.resumed) {
      _sync?.flushNow();
    }
  }

  Future<void> _start() async {
    setState(() {
      _busy = true;
      _error = null;
    });

    if (!await Geolocator.isLocationServiceEnabled()) {
      setState(() {
        _busy = false;
        _error = 'Location is turned off. Enable GPS and tap retry.';
      });
      return;
    }

    final perm = await LocationService.requestForeground();
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      setState(() {
        _busy = false;
        _error = perm == LocationPermission.deniedForever
            ? 'Location permission was permanently denied. Enable it in '
                'Settings › Apps › Terrastep › Permissions.'
            : 'Terrastep needs location to award you territory.';
      });
      return;
    }

    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        await Permission.activityRecognition.request();
      } catch (_) {}
    }

    // Cloud sync is available only when the APK was built with the anon key
    // AND the user has a session (magic link). Offline mode keeps Phase 1
    // walking working without either.
    SyncCoordinator? sync;
    TerritoryRepository? territory;
    final indexer = H3Indexer();

    if (SupabaseEnv.configured) {
      try {
        final hasSession =
            Supabase.instance.client.auth.currentSession != null;
        if (hasSession) {
          final client = Supabase.instance.client;
          late final TrackingCoordinator t;
          sync = SyncCoordinator(
            client: client,
            clientVersion: kAppVersion,
            onReport: (report) async {
              t.syncStatus = SyncStatus(
                pending: await sync!.outbox.count(),
                accepted: report.cellsAccepted,
                rejected: report.cellsRejected,
                newlyOwned: report.newlyOwned,
                rateLimited: report.rateLimited,
                at: DateTime.now(),
                error: report.errors.isEmpty ? null : report.errors.first,
              );
              t.notifyListeners();
            },
          );
          territory = TerritoryRepository(client);
          t = TrackingCoordinator(
            indexer: indexer,
            location: LocationService(),
            steps: StepService(),
            outbox: sync.outbox,
            enqueueClaims: sync.enqueue,
          );
          await t.init();
          if (!mounted) {
            sync.dispose();
            return;
          }
          t.syncStatus = SyncStatus(
            pending: await sync.outbox.count(),
            accepted: 0,
            rejected: 0,
            newlyOwned: 0,
            rateLimited: false,
            at: DateTime.now(),
          );
          sync.start();
          _sync = sync;
          _territory = territory;
          if (!mounted) {
            sync.dispose();
            return;
          }
          setState(() {
            _tracker = t;
            _busy = false;
          });
          return;
        }
      } catch (_) {
        sync?.dispose();
        sync = null;
        territory = null;
      }
    }

    // Offline / no-session path: local claims only.
    final t = TrackingCoordinator(
      indexer: indexer,
      location: LocationService(),
      steps: StepService(),
      outbox: sync?.outbox,
      enqueueClaims: sync?.enqueue,
    );
    await t.init();

    if (!mounted) {
      sync?.dispose();
      return;
    }
    _sync = sync;
    _territory = territory;
    setState(() {
      _tracker = t;
      _busy = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = _tracker;
    if (t != null) {
      return MapScreen(
        tracker: t,
        territory: _territory,
        indexer: t.indexer,
      );
    }

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
                  _error ?? '',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Color(0xFFFCA5A5)),
                ),
                const SizedBox(height: 16),
                FilledButton(
                    onPressed: _start, child: const Text('Grant & start')),
                if (_error?.contains('Settings') ?? false)
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
