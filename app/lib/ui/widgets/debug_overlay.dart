import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:terrastep_core/domain/session_accumulator.dart';

import '../../app_version.dart';
import '../../config/supabase_env.dart';
import '../../services/location_service.dart';
import '../../services/tracking_coordinator.dart';

/// Live sensor readout. Tap the copy icon — first line is the version check.
class DebugOverlay extends StatefulWidget {
  final TrackingCoordinator tracker;
  const DebugOverlay({super.key, required this.tracker});

  @override
  State<DebugOverlay> createState() => _DebugOverlayState();
}

class _DebugOverlayState extends State<DebugOverlay> {
  final _battery = Battery();
  int? _batteryPct;
  BatteryState? _batteryState;
  Timer? _timer;
  int _ticks = 0;

  TrackingCoordinator get tracker => widget.tracker;

  @override
  void initState() {
    super.initState();
    _pollBattery();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      _ticks++;
      if (_ticks % 20 == 0) _pollBattery();
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _pollBattery() async {
    try {
      final pct = await _battery.batteryLevel;
      final state = await _battery.batteryState;
      if (!mounted) return;
      setState(() {
        _batteryPct = pct;
        _batteryState = state;
      });
    } catch (_) {}
  }

  String get _elapsed {
    final start = tracker.sessionStartedAt;
    if (start == null) return '—';
    final d = DateTime.now().difference(start);
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (d.inHours > 0) return '${d.inHours}:$m:$s';
    return '$m:$s';
  }

  String get _batteryLabel {
    if (_batteryPct == null) return '—';
    final charging = _batteryState == BatteryState.charging ? ' ⚡' : '';
    return '$_batteryPct%$charging';
  }

  String get _pedometerLabel {
    if (tracker.steps.isAvailable) {
      return 'ok (${tracker.steps.sessionTotal})';
    }
    if (tracker.estimatingSteps) {
      return 'EST. from dist';
    }
    return 'waiting…';
  }

  String get _lastFixAge {
    final at = tracker.lastFixAt;
    if (at == null) return 'none';
    final s = DateTime.now().difference(at).inSeconds;
    if (s < 2) return 'now';
    if (s < 60) return '${s}s ago';
    return '${s ~/ 60}m ${s % 60}s ago';
  }

  String get _errorLabel {
    final e = tracker.lastError ?? tracker.location.lastError;
    if (e == null || e.isEmpty) return 'none';
    return e;
  }

  bool get _weakLock =>
      tracker.lastAccuracy != null && tracker.lastAccuracy! > 50;

  /// First-line proof that this APK has a session (or is offline).
  String get _authLabel {
    if (!SupabaseEnv.configured) return 'no-key';
    try {
      final u = Supabase.instance.client.auth.currentUser;
      if (u == null) return 'offline';
      return u.email ?? u.id.substring(0, 8);
    } catch (_) {
      return 'offline';
    }
  }

  String _syncLine(String prefix, SyncStatus s) =>
      '$prefix pending:${s.pending} ok:${s.accepted} '
      'new:${s.newlyOwned} rej:${s.rejected}'
      '${s.rateLimited ? " RATE-LIMITED" : ""}'
      '${s.error != null ? " err:${s.error}" : ""}';

  String _dump() {
    final v = tracker.currentVisit;
    final cfg = tracker.cfg;
    final buf = StringBuffer()
      ..writeln('Terrastep debug  $kAppVersion')
      ..writeln('auth $_authLabel')
      ..writeln('elapsed $_elapsed   battery $_batteryLabel')
      ..writeln('cell ${v?.cellId ?? '—'}')
      ..writeln('steps ${v?.steps ?? 0} / ${cfg.claimMinSteps}')
      ..writeln(
          'distance ${(v?.distanceM ?? 0).toStringAsFixed(1)} m / ${cfg.claimMinDistanceM}')
      ..writeln('dwell ${v?.dwellS ?? 0} s / ${cfg.claimMinDwellS}')
      ..writeln('fixes ${v?.fixCount ?? 0} / ${cfg.claimMinFixes}')
      ..writeln('m/step ${(v?.metresPerStep ?? 0).toStringAsFixed(2)}')
      ..writeln(
          'gps acc ${tracker.lastAccuracy == null ? '—' : '${tracker.lastAccuracy!.toStringAsFixed(1)} m'}')
      ..writeln('raw gps ${tracker.rawFixes}')
      ..writeln('accepted ${tracker.fixesAccepted}')
      ..writeln('pedometer $_pedometerLabel')
      ..writeln('error $_errorLabel')
      ..writeln('fgs ${tracker.foregroundServiceOn ? 'on' : 'off'}')
      ..writeln('gps src ${tracker.usingLocationManager ? 'chip' : 'fused'}')
      ..writeln('last fix $_lastFixAge')
      ..writeln('motion ${tracker.motion.name}')
      ..writeln('territory ${tracker.claimed.length} hexes');
    final sync = tracker.syncStatus;
    if (sync != null) {
      buf.writeln(_syncLine('sync', sync));
    } else if (SupabaseEnv.configured) {
      buf.writeln('sync offline (local only)');
    }
    if (tracker.rejections.isNotEmpty) {
      buf.writeln('rejected:');
      for (final e in tracker.rejections.entries) {
        buf.writeln('  ${_rejName(e.key)} ${e.value}');
      }
    }
    return buf.toString();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _dump()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Debug dump copied'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final v = tracker.currentVisit;
    final cfg = tracker.cfg;
    final rej = tracker.rejections;

    return Container(
      margin: const EdgeInsets.all(10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xE60B1220),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF243352)),
      ),
      child: DefaultTextStyle(
        style: const TextStyle(
          fontSize: 11.5,
          color: Color(0xFFE6EDF7),
          fontFamily: 'monospace',
          height: 1.5,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('SENSORS',
                    style: TextStyle(
                        fontSize: 10,
                        letterSpacing: 1.2,
                        color: Color(0xFF8FA3C4),
                        fontWeight: FontWeight.bold)),
                const Spacer(),
                GestureDetector(
                  onTap: _copy,
                  child: const Icon(Icons.copy, size: 14, color: Color(0xFF8FA3C4)),
                ),
                const SizedBox(width: 8),
                _Pill(
                  label: tracker.foregroundServiceOn ? 'fgs' : 'no-fgs',
                  color: tracker.foregroundServiceOn
                      ? const Color(0xFF22C55E)
                      : const Color(0xFFEF4444),
                ),
                const SizedBox(width: 6),
                _Pill(
                  label: tracker.motion.name,
                  color: switch (tracker.motion) {
                    MotionState.walking => const Color(0xFF22C55E),
                    MotionState.running => const Color(0xFF3B82F6),
                    MotionState.vehicle => const Color(0xFFEF4444),
                    MotionState.stationary => const Color(0xFF64748B),
                  },
                ),
              ],
            ),
            if (_weakLock) ...[
              const SizedBox(height: 6),
              const Text(
                'WEAK LOCK — Wi-Fi/network, not GPS.',
                style: TextStyle(
                    color: Color(0xFFFBBF24), fontWeight: FontWeight.bold),
              ),
            ],
            const SizedBox(height: 6),
            _row('cell', v?.cellId ?? '—'),
            _row('steps', '${v?.steps ?? 0} / ${cfg.claimMinSteps}'),
            _row('distance',
                '${(v?.distanceM ?? 0).toStringAsFixed(1)} m / ${cfg.claimMinDistanceM}'),
            _row('dwell', '${v?.dwellS ?? 0} s / ${cfg.claimMinDwellS}'),
            _row('fixes', '${v?.fixCount ?? 0} / ${cfg.claimMinFixes}'),
            _row('m/step', (v?.metresPerStep ?? 0).toStringAsFixed(2),
                hint: 'server wants 0.30-1.60'),
            const Divider(height: 14, color: Color(0xFF243352)),
            _row(
                'gps acc',
                tracker.lastAccuracy == null
                    ? '—'
                    : '${tracker.lastAccuracy!.toStringAsFixed(1)} m'),
            _row('raw gps', '${tracker.rawFixes}'),
            _row('accepted', '${tracker.fixesAccepted}'),
            _row('last fix', _lastFixAge),
            _row('pedometer', _pedometerLabel,
                valueColor: tracker.estimatingSteps
                    ? const Color(0xFFFBBF24)
                    : null),
            _row('fgs', tracker.foregroundServiceOn ? 'on' : 'off',
                valueColor: tracker.foregroundServiceOn
                    ? const Color(0xFF22C55E)
                    : const Color(0xFFEF4444)),
            _row('gps src', tracker.usingLocationManager ? 'chip' : 'fused'),
            _row('territory', '${tracker.claimed.length} hexes'),
            if (tracker.syncStatus != null)
              _row(
                'sync',
                'pending ${tracker.syncStatus!.pending}  '
                    'ok ${tracker.syncStatus!.accepted}  '
                    'new ${tracker.syncStatus!.newlyOwned}',
                valueColor: tracker.syncStatus!.pending > 0
                    ? const Color(0xFFFBBF24)
                    : const Color(0xFF22C55E),
              )
            else if (SupabaseEnv.configured)
              _row('sync', 'offline (local only)',
                  valueColor: const Color(0xFF64748B)),
            _row('auth', _authLabel),
            _row('battery', _batteryLabel),
            _row('elapsed', _elapsed),
            _row('error', _errorLabel,
                valueColor: _errorLabel == 'none'
                    ? null
                    : const Color(0xFFFCA5A5)),
            if (rej.isNotEmpty) ...[
              const Divider(height: 14, color: Color(0xFF243352)),
              const Text('REJECTED FIXES',
                  style: TextStyle(
                      fontSize: 10,
                      letterSpacing: 1.2,
                      color: Color(0xFF8FA3C4),
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              for (final e in rej.entries)
                _row(_rejName(e.key), '${e.value}',
                    valueColor: const Color(0xFFFCA5A5)),
            ],
          ],
        ),
      ),
    );
  }

  static String _rejName(FixRejection r) => switch (r) {
        FixRejection.mocked => 'mock gps',
        FixRejection.poorAccuracy => 'poor acc',
        FixRejection.vehicleSpeed => 'too fast',
        FixRejection.impossibleJump => 'teleport',
        FixRejection.clockSkew => 'clock',
      };

  Widget _row(String k, String val, {String? hint, Color? valueColor}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(
          children: [
            SizedBox(
                width: 76,
                child: Text(k,
                    style: const TextStyle(color: Color(0xFF8FA3C4)))),
            Flexible(
              child: Text(val,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: valueColor ?? const Color(0xFFE6EDF7),
                      fontWeight: FontWeight.w600)),
            ),
            if (hint != null) ...[
              const SizedBox(width: 6),
              Text(hint,
                  style: const TextStyle(
                      fontSize: 9.5, color: Color(0xFF64748B))),
            ],
          ],
        ),
      );
}

class _Pill extends StatelessWidget {
  final String label;
  final Color color;
  const _Pill({required this.label, required this.color});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: color.withValues(alpha: 0.6)),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 9.5, color: color, fontWeight: FontWeight.bold)),
      );
}
