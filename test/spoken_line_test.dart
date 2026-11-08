import 'package:flutter_test/flutter_test.dart';
import 'package:ahha_app/alert_policy.dart';
import 'package:ahha_app/detection_logic.dart';

Candidate desk({double dist = 6.0, Proximity prox = Proximity.veryNear, AlertTier tier = AlertTier.high}) => Candidate(
      tag: 'obstacle_low',
      label: 'desk',
      zone: 'center',
      model: 'test',
      distFeet: dist,
      clipped: false,
      proximity: prox,
      severity: 2,
      tier: tier,
      conf: 0.9,
      box: const [0.3, 0.2, 0.7, 0.9],
      yMax: 0.9,
    );

/// Mirrors what lib/main.dart does for one dispatched hazard: the Audio line
/// is written only when the policy actually lets the speech through.
void dispatch(AlertPolicy policy, SpokenLine line, Candidate c, DateTime now, {bool audio = true}) {
  final out = policy.decide(c, now);
  if (out.speak) line.record(out.speech, audible: audio);
}

void main() {
  const failSafe = "Camera can't see ahead. Stop and check.";

  group('A2: the Audio line is always the last thing actually spoken', () {
    test('starts empty', () {
      expect(SpokenLine().text, '-');
    });

    test('shows a spoken alert', () {
      final line = SpokenLine();
      dispatch(AlertPolicy(), line, desk(), DateTime(2026, 1, 1));
      expect(line.text, 'Desk very close ahead.');
    });

    test('a withheld alert (no change) leaves the previous spoken text alone', () {
      final policy = AlertPolicy();
      final line = SpokenLine();
      final t = DateTime(2026, 1, 1);
      dispatch(policy, line, desk(), t);
      dispatch(policy, line, desk(), t.add(const Duration(seconds: 1)));
      expect(line.text, 'Desk very close ahead.');
    });

    test('a fail-safe phrase replaces the line, and a later spoken alert replaces it again', () {
      final policy = AlertPolicy();
      final line = SpokenLine();
      final t = DateTime(2026, 1, 1);
      dispatch(policy, line, desk(), t);
      line.record(failSafe, audible: true);
      expect(line.text, failSafe);
      dispatch(policy, line, desk(dist: 3, prox: Proximity.veryNear), t.add(const Duration(seconds: 5)));
      expect(line.text, 'Desk very close ahead.');
    });

    test('with AUDIO off the line is marked, so it is never mistaken for speech', () {
      final line = SpokenLine();
      dispatch(AlertPolicy(), line, desk(), DateTime(2026, 1, 1), audio: false);
      expect(line.text, '(audio off) Desk very close ahead.');
    });

    test('clear() resets it', () {
      final line = SpokenLine()..record('x', audible: true);
      line.clear();
      expect(line.text, '-');
    });
  });

  group('A2: the real cause - a fail-safe must not leave the "no change" memory behind', () {
    test('BEFORE the fix: same desk after a fail-safe is withheld as "no change", so the line stays on the fail-safe', () {
      final policy = AlertPolicy();
      final line = SpokenLine();
      final t = DateTime(2026, 1, 1);
      dispatch(policy, line, desk(), t); // "Desk very close ahead." spoken
      line.record(failSafe, audible: true); // camera went dark: fail-safe spoke
      // camera recovers, same desk, same distance: policy still remembers the
      // earlier announcement and withholds it
      final out = policy.decide(desk(), t.add(const Duration(seconds: 6)));
      expect(out.speak, isFalse);
      expect(out.suppressedReason, 'no change');
    });

    test('AFTER the fix: forgetAnnounced() after the fail-safe lets the desk be spoken again', () {
      final policy = AlertPolicy();
      final line = SpokenLine();
      final t = DateTime(2026, 1, 1);
      dispatch(policy, line, desk(), t);
      line.record(failSafe, audible: true);
      policy.forgetAnnounced();
      dispatch(policy, line, desk(), t.add(const Duration(seconds: 6)));
      expect(line.text, 'Desk very close ahead.', reason: 'orange card and Audio line now agree');
    });

    test('forgetAnnounced() keeps the speech budget (it does not reset the cognitive-load cap)', () {
      final policy = AlertPolicy();
      final t = DateTime(2026, 1, 1);
      for (var i = 0; i < 9; i++) {
        policy.decide(desk(dist: 3.0 + i * 3, tier: AlertTier.medium), t.add(Duration(seconds: i)));
      }
      expect(policy.utterancesLastMinute(t.add(const Duration(seconds: 10))), 9);
      policy.forgetAnnounced();
      expect(policy.utterancesLastMinute(t.add(const Duration(seconds: 10))), 9);
      final out = policy.decide(desk(dist: 40, tier: AlertTier.medium), t.add(const Duration(seconds: 11)));
      expect(out.suppressedReason, 'budget');
    });
  });
}
