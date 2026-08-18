import 'package:flutter/material.dart';
import 'package:terrastep_core/domain/session_accumulator.dart';

import '../../services/location_service.dart';
import '../../services/tracking_coordinator.dart';

/// Live sensor readout.
///
/// This is the most important part of the first APK. The whole point of
/// threshold 0.3 is to find out what the sensors actually do on real hardware,
/// and that is unknowable without seeing the raw numbers. Screenshot this
/// during a test walk.
class DebugOverlay extends StatelessWidget {
  final TrackingCoordinator tracker;
  const DebugOverlay({super.key, required this.tracker});

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

            _row('gps acc',
                tracker.lastAccuracy == null
                    ? '—'
                    : '${tracker.lastAccuracy!.toStringAsFixed(1)} m'),
            _row('accepted', '${tracker.fixesAccepted}'),
            _row('pedometer',
                tracker.steps.isAvailable ? 'ok (${tracker.steps.sessionTotal})' : 'NO SENSOR'),
            _row('territory', '${tracker.claimed.length} hexes'),

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

  Widget _row(String k, String val, {String? hint, Color? valueColor}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(
          children: [
            SizedBox(
                width: 76,
                child: Text(k,
                    style: const TextStyle(color: Color(0xFF8FA3C4)))),
            Text(val,
                style: TextStyle(
                    color: valueColor ?? const Color(0xFFE6EDF7),
                    fontWeight: FontWeight.w600)),
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
