import 'package:flutter/material.dart';

import '../../services/tracking_coordinator.dart';

/// Bottom card: how close the current hex is to being claimed.
class ProgressCard extends StatelessWidget {
  final TrackingCoordinator tracker;
  const ProgressCard({super.key, required this.tracker});

  @override
  Widget build(BuildContext context) {
    final v = tracker.currentVisit;
    final cfg = tracker.cfg;
    final progress = tracker.currentProgress;
    final effort = v == null
        ? 0.0
        : cfg.computeEffort(v.steps, v.distanceM, v.dwellS);

    return Container(
      margin: const EdgeInsets.fromLTRB(10, 0, 10, 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xF2111A2E),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF243352)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('CURRENT HEX',
                  style: TextStyle(
                      fontSize: 10,
                      letterSpacing: 1.3,
                      color: Color(0xFF8FA3C4),
                      fontWeight: FontWeight.bold)),
              const Spacer(),
              Text('effort ${effort.toStringAsFixed(0)}',
                  style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF8FA3C4),
                      fontFeatures: [FontFeature.tabularFigures()])),
            ],
          ),
          const SizedBox(height: 10),

          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 7,
              backgroundColor: const Color(0xFF0B1220),
              valueColor: AlwaysStoppedAnimation(
                progress >= 1
                    ? const Color(0xFF22C55E)
                    : const Color(0xFF3B82F6),
              ),
            ),
          ),
          const SizedBox(height: 12),

          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _Metric(
                  label: 'steps',
                  value: '${v?.steps ?? 0}',
                  target: '${cfg.claimMinSteps}',
                  done: (v?.steps ?? 0) >= cfg.claimMinSteps),
              _Metric(
                  label: 'metres',
                  value: (v?.distanceM ?? 0).toStringAsFixed(0),
                  target: '${cfg.claimMinDistanceM}',
                  done: (v?.distanceM ?? 0) >= cfg.claimMinDistanceM),
              _Metric(
                  label: 'seconds',
                  value: '${v?.dwellS ?? 0}',
                  target: '${cfg.claimMinDwellS}',
                  done: (v?.dwellS ?? 0) >= cfg.claimMinDwellS),
              _Metric(
                  label: 'owned',
                  value: '${tracker.claimed.length}',
                  target: null,
                  done: tracker.claimed.isNotEmpty),
            ],
          ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  final String label;
  final String value;
  final String? target;
  final bool done;

  const _Metric({
    required this.label,
    required this.value,
    required this.target,
    required this.done,
  });

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(value,
                  style: TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.bold,
                      color: done
                          ? const Color(0xFF22C55E)
                          : const Color(0xFFE6EDF7),
                      fontFeatures: const [FontFeature.tabularFigures()])),
              if (target != null)
                Text('/$target',
                    style: const TextStyle(
                        fontSize: 11, color: Color(0xFF64748B))),
            ],
          ),
          Text(label,
              style: const TextStyle(fontSize: 10, color: Color(0xFF8FA3C4))),
        ],
      );
}
