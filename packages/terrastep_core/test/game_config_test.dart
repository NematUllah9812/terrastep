import 'package:test/test.dart';
import 'package:terrastep_core/core/game_config.dart';

/// These assertions mirror the verified SQL suite in `tests/01_engine_tests.sql`.
/// If the client and server ever disagree on these numbers, players see claims
/// silently rejected. Any change here must change the SQL in the same commit.
void main() {
  const cfg = GameConfig();

  group('effort parity with compute_effort() in SQL', () {
    test('B1: 400 steps, 310 m, 420 s -> 529.50', () {
      // SQL test B1 asserts exactly '529.50'
      expect(cfg.computeEffort(400, 310, 420), closeTo(529.50, 0.001));
    });

    test('B2: capped at 600', () {
      expect(cfg.computeEffort(5000, 5000, 5000), equals(600));
    });

    test('D2 fixture: 300 steps, 250 m, 300 s -> 402.5', () {
      expect(cfg.computeEffort(300, 250, 300), closeTo(402.5, 0.001));
    });

    test('D3 fixture: 250 steps, 200 m, 250 s -> 332.5', () {
      expect(cfg.computeEffort(250, 200, 250), closeTo(332.5, 0.001));
    });
  });

  group('decay parity with current_influence() in SQL', () {
    final now = DateTime.utc(2026, 8, 18, 12, 0, 0);

    test('E1: no decay at t=0', () {
      expect(cfg.currentInfluence(1000, now, now: now), closeTo(1000, 0.01));
    });

    test('E2: one half-life (7 days) -> 500', () {
      final at = now.subtract(const Duration(days: 7));
      expect(cfg.currentInfluence(1000, at, now: now), closeTo(500, 0.01));
    });

    test('E3: two half-lives (14 days) -> 250', () {
      final at = now.subtract(const Duration(days: 14));
      expect(cfg.currentInfluence(1000, at, now: now), closeTo(250, 0.01));
    });

    test('E4: 28 days falls below the neutral floor', () {
      final at = now.subtract(const Duration(days: 28));
      expect(cfg.currentInfluence(1000, at, now: now), lessThan(cfg.neutralFloor));
    });
  });

  group('hysteresis parity', () {
    test('D1: takeover bar for a 300-influence owner is 395', () {
      // bar = 300 * 1.15 + 50
      expect(cfg.effortToCapture(300, 0), closeTo(395, 0.001));
    });

    test('challenger already above the bar needs nothing more', () {
      expect(cfg.effortToCapture(300, 500), equals(0));
    });

    test('D2/D3 boundary: 402.5 captures, 332.5 does not', () {
      const ownerInfluence = 300.0;
      final bar = ownerInfluence * cfg.takeoverMultiplier + cfg.takeoverFlatMargin;
      expect(402.5 > bar, isTrue);
      expect(332.5 > bar, isFalse);
    });
  });

  group('fromRows parses the game_config table', () {
    test('overrides defaults and tolerates string numerics', () {
      final cfg2 = GameConfig.fromRows([
        {'key': 'claim_min_steps', 'value': '200'},
        {'key': 'decay_half_life_days', 'value': 14},
        {'key': 'unknown_key', 'value': 1},
      ]);
      expect(cfg2.claimMinSteps, equals(200));
      expect(cfg2.decayHalfLifeDays, equals(14));
      expect(cfg2.claimMinDistanceM, equals(80), reason: 'untouched default');
    });

    test('empty rows yield defaults', () {
      final cfg2 = GameConfig.fromRows([]);
      expect(cfg2.claimMinSteps, equals(const GameConfig().claimMinSteps));
    });
  });
}
