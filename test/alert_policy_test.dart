import 'package:flutter_test/flutter_test.dart';
import 'package:ahha_app/alert_policy.dart';
import 'package:ahha_app/detection_logic.dart';

Candidate cand({
  String tag = 'obstacle_low',
  String label = 'chair',
  String zone = 'center',
  double dist = 8.0,
  bool clipped = false,
  Proximity prox = Proximity.near,
  AlertTier tier = AlertTier.medium,
  double conf = 0.8,
}) =>
    Candidate(
      tag: tag,
      label: label,
      zone: zone,
      model: 'test',
      distFeet: dist,
      clipped: clipped,
      proximity: prox,
      severity: kHazardSeverity[tag] ?? 1,
      tier: tier,
      conf: conf,
      box: const [0.3, 0.2, 0.7, 0.9],
      yMax: 0.9,
    );

final t0 = DateTime(2026, 1, 1);
DateTime at(int seconds) => t0.add(Duration(seconds: seconds));

void main() {
  group('wording', () {
    test('critical stairs down keeps the designed imperative', () {
      final c = cand(tag: 'stairs_down', label: 'stairs down', tier: AlertTier.critical, prox: Proximity.veryNear);
      expect(AlertPolicy.speechFor(c), 'Stop. Stairs down.');
    });

    test('critical vehicle is "Stop. Car ahead."', () {
      final c = cand(tag: 'vehicle', label: 'car', tier: AlertTier.critical, prox: Proximity.veryNear);
      expect(AlertPolicy.speechFor(c), 'Stop. Car ahead.');
    });

    test('very near is urgent and gives NO number (it cannot be trusted that close)', () {
      final c = cand(label: 'chair', tier: AlertTier.high, prox: Proximity.veryNear, dist: 5.7, clipped: true);
      expect(AlertPolicy.speechFor(c), 'Chair very close ahead.');
    });

    test('in the way, farther out: says the thing and the distance', () {
      final c = cand(tag: 'pothole', label: 'pothole', tier: AlertTier.medium, prox: Proximity.near, dist: 8.2);
      expect(AlertPolicy.speechFor(c), 'Pothole ahead, 8 feet.');
    });

    test('off-path hazards say which side', () {
      final left = cand(tag: 'vehicle', label: 'car', zone: 'left', tier: AlertTier.medium, prox: Proximity.near, dist: 8.0);
      expect(AlertPolicy.speechFor(left), 'Car on your left, 8 feet.');
      final right = cand(tag: 'vehicle', label: 'bus', zone: 'right', tier: AlertTier.high, prox: Proximity.veryNear);
      expect(AlertPolicy.speechFor(right), 'Bus very close on your right.');
    });
  });

  group('haptics: closer is always stronger, tier sets the rhythm', () {
    test('strength rises as the hazard gets closer, for every tier', () {
      for (final tier in [AlertTier.high, AlertTier.medium]) {
        final vn = AlertPolicy.hapticFor(tier, Proximity.veryNear).peakAmplitude;
        final nr = AlertPolicy.hapticFor(tier, Proximity.near).peakAmplitude;
        final fr = AlertPolicy.hapticFor(tier, Proximity.far).peakAmplitude;
        expect(vn, greaterThan(nr), reason: '$tier');
        expect(nr, greaterThan(fr), reason: '$tier');
      }
    });

    test('critical is the strongest thing the app ever does', () {
      final crit = AlertPolicy.hapticFor(AlertTier.critical, Proximity.veryNear).peakAmplitude;
      expect(crit, 255);
      for (final tier in [AlertTier.high, AlertTier.medium]) {
        for (final p in Proximity.values) {
          expect(AlertPolicy.hapticFor(tier, p).peakAmplitude, lessThan(crit));
        }
      }
    });

    test('rhythm identifies the tier by pulse count: 3 / 2 / 1', () {
      // pattern = [delay, on, off, on, ...]; on-segments are at odd indexes
      int onCount(HapticSpec h) => [for (var i = 1; i < h.pattern.length; i += 2) 1].length;
      expect(onCount(AlertPolicy.hapticFor(AlertTier.critical, Proximity.veryNear)), 3);
      expect(onCount(AlertPolicy.hapticFor(AlertTier.high, Proximity.near)), 2);
      expect(onCount(AlertPolicy.hapticFor(AlertTier.medium, Proximity.near)), 1);
    });

    test('very near packs the double pulse tighter than near', () {
      final vn = AlertPolicy.hapticFor(AlertTier.high, Proximity.veryNear).pattern;
      final nr = AlertPolicy.hapticFor(AlertTier.high, Proximity.near).pattern;
      expect(vn[2], lessThan(nr[2])); // gap between the two pulses
    });

    test('info never vibrates', () {
      expect(AlertPolicy.hapticFor(AlertTier.info, Proximity.veryNear).isSilent, isTrue);
    });

    test('every amplitude list lines up with its pattern', () {
      for (final tier in AlertTier.values) {
        for (final p in Proximity.values) {
          final h = AlertPolicy.hapticFor(tier, p);
          expect(h.amplitudes.length, h.pattern.length, reason: '$tier $p');
        }
      }
    });
  });

  group('speech: closer sounds faster, higher, and louder', () {
    test('rate and pitch rise with proximity; volume never falls', () {
      final vn = AlertPolicy.ttsFor(AlertTier.high, Proximity.veryNear);
      final nr = AlertPolicy.ttsFor(AlertTier.high, Proximity.near);
      final fr = AlertPolicy.ttsFor(AlertTier.medium, Proximity.far);
      expect(vn.rate, greaterThan(nr.rate));
      expect(nr.rate, greaterThan(fr.rate));
      expect(vn.pitch, greaterThan(nr.pitch));
      expect(nr.pitch, greaterThan(fr.pitch));
      expect(vn.volume, greaterThanOrEqualTo(nr.volume));
      expect(nr.volume, greaterThanOrEqualTo(fr.volume));
    });

    test('critical always uses the most urgent voice', () {
      final crit = AlertPolicy.ttsFor(AlertTier.critical, Proximity.veryNear);
      final vn = AlertPolicy.ttsFor(AlertTier.high, Proximity.veryNear);
      expect(crit.rate, vn.rate);
      expect(crit.pitch, vn.pitch);
    });
  });

  group('cognitive load: what speech is suppressed', () {
    test('repeating the same unchanged hazard is haptic-only', () {
      final p = AlertPolicy();
      final c = cand(tier: AlertTier.high, prox: Proximity.veryNear, dist: 6);
      expect(p.decide(c, at(0)).speak, isTrue);
      final again = p.decide(c, at(1));
      expect(again.speak, isFalse);
      expect(again.suppressedReason, 'no change');
      expect(again.haptic.isSilent, isFalse, reason: 'haptics still fire');
    });

    test('a meaningful change is spoken again', () {
      final p = AlertPolicy();
      p.decide(cand(tier: AlertTier.medium, dist: 9), at(0));
      expect(p.decide(cand(tier: AlertTier.medium, dist: 7), at(1)).speak, isTrue);
    });

    test('a tier change is spoken again even at the same distance', () {
      final p = AlertPolicy();
      p.decide(cand(tier: AlertTier.medium, dist: 8), at(0));
      expect(p.decide(cand(tier: AlertTier.high, dist: 8), at(1)).speak, isTrue);
    });

    test('critical is spoken every time, even when nothing changed', () {
      final p = AlertPolicy();
      final c = cand(tag: 'stairs_down', tier: AlertTier.critical, prox: Proximity.veryNear);
      for (var i = 0; i < 5; i++) {
        expect(p.decide(c, at(i)).speak, isTrue, reason: 'repeat $i');
      }
    });

    test('medium speech is capped at 9 a minute; the 10th is haptic-only', () {
      final p = AlertPolicy();
      for (var i = 0; i < 9; i++) {
        expect(p.decide(cand(tag: 'a$i', tier: AlertTier.medium), at(i)).speak, isTrue, reason: 'utterance $i');
      }
      final tenth = p.decide(cand(tag: 'a9', tier: AlertTier.medium), at(9));
      expect(tenth.speak, isFalse);
      expect(tenth.suppressedReason, 'budget');
    });

    test('capacity is held back for High: after 9 mediums a High still speaks, up to 12', () {
      final p = AlertPolicy();
      for (var i = 0; i < 9; i++) {
        p.decide(cand(tag: 'a$i', tier: AlertTier.medium), at(i));
      }
      for (var i = 0; i < 3; i++) {
        expect(p.decide(cand(tag: 'h$i', tier: AlertTier.high), at(9 + i)).speak, isTrue, reason: 'high $i');
      }
      final overflow = p.decide(cand(tag: 'h3', tier: AlertTier.high), at(12));
      expect(overflow.speak, isFalse);
      expect(overflow.suppressedReason, 'budget');
    });

    test('critical is never rationed, even with the whole budget spent', () {
      final p = AlertPolicy();
      for (var i = 0; i < 12; i++) {
        p.decide(cand(tag: 'h$i', tier: AlertTier.high), at(i));
      }
      final crit = p.decide(cand(tag: 'vehicle', tier: AlertTier.critical), at(13));
      expect(crit.speak, isTrue);
    });

    test('the budget is a rolling minute, not a lifetime cap', () {
      final p = AlertPolicy();
      for (var i = 0; i < 9; i++) {
        p.decide(cand(tag: 'a$i', tier: AlertTier.medium), at(i));
      }
      expect(p.decide(cand(tag: 'late', tier: AlertTier.medium), at(20)).speak, isFalse);
      expect(p.decide(cand(tag: 'later', tier: AlertTier.medium), at(75)).speak, isTrue);
    });

    test('a budget-suppressed alert is NOT marked announced, so it speaks once room frees up', () {
      final p = AlertPolicy();
      for (var i = 0; i < 9; i++) {
        p.decide(cand(tag: 'a$i', tier: AlertTier.medium), at(i));
      }
      final blocked = cand(tag: 'blocked', tier: AlertTier.medium, dist: 8);
      expect(p.decide(blocked, at(10)).speak, isFalse);
      expect(p.decide(blocked, at(80)).speak, isTrue);
    });

    test('suppressed alerts do not use up budget', () {
      final p = AlertPolicy();
      final c = cand(tier: AlertTier.high, dist: 6);
      p.decide(c, at(0));
      p.decide(c, at(1));
      p.decide(c, at(2));
      expect(p.utterancesLastMinute(at(3)), 1);
    });

    test('a busy voice defers the speech: not counted, not marked announced, spoken next time', () {
      final p = AlertPolicy();
      final c = cand(tier: AlertTier.high, dist: 6);
      final deferred = p.decide(c, at(0), ttsBusy: true);
      expect(deferred.speak, isFalse);
      expect(deferred.suppressedReason, 'busy');
      expect(p.utterancesLastMinute(at(1)), 0);
      expect(p.decide(c, at(1)).speak, isTrue, reason: 'nothing was announced, so it is not "no change"');
    });

    test('critical ignores a busy voice (it preempts)', () {
      final p = AlertPolicy();
      final c = cand(tag: 'vehicle', tier: AlertTier.critical, prox: Proximity.veryNear);
      expect(p.decide(c, at(0), ttsBusy: true).speak, isTrue);
    });

    test('reset() forgets what was announced', () {
      final p = AlertPolicy();
      final c = cand(tier: AlertTier.high, dist: 6);
      p.decide(c, at(0));
      p.reset();
      expect(p.decide(c, at(1)).speak, isTrue);
    });
  });

  group('AlertLog (evaluation data)', () {
    AlertOutput out(AlertPolicy p, Candidate c, DateTime t) => p.decide(c, t);

    test('CSV has a header, one row per event, and quotes speech containing commas', () {
      final p = AlertPolicy();
      final log = AlertLog(start: t0);
      final c = cand(tag: 'pothole', label: 'pothole', tier: AlertTier.medium, dist: 8.2);
      log.alert(out(p, c, at(2)), at(2), hapticFired: true);
      final lines = log.toCsv().split('\n');
      expect(lines.first, AlertLog.header);
      expect(lines.length, 2);
      expect(lines[1], contains('"Pothole ahead, 8 feet."'));
      expect(lines[1], startsWith('2000,alert,medium,pothole'));
    });

    test('records why speech was withheld', () {
      final p = AlertPolicy();
      final log = AlertLog(start: t0);
      final c = cand(tier: AlertTier.high, dist: 6);
      log.alert(out(p, c, at(0)), at(0), hapticFired: true);
      log.alert(out(p, c, at(1)), at(1), hapticFired: true);
      expect(log.suppressionCounts(), {'no change': 1});
    });

    test('fail-safe transitions are logged with their name', () {
      final log = AlertLog(start: t0);
      log.failsafe('detection_offline', on: true, now: at(5));
      log.failsafe('detection_offline', on: false, now: at(20));
      expect(log.events.map((e) => e.kind), ['failsafe_on', 'failsafe_off']);
      expect(log.toCsv(), contains('detection_offline'));
    });

    test('peak utterances/min finds the busiest 60 s window', () {
      final p = AlertPolicy();
      final log = AlertLog(start: t0);
      // 4 spoken in the first 10 s, then a quiet gap, then 2 more.
      for (var i = 0; i < 4; i++) {
        log.alert(out(p, cand(tag: 'x$i', tier: AlertTier.high), at(i * 2)), at(i * 2), hapticFired: true);
      }
      for (var i = 0; i < 2; i++) {
        log.alert(out(p, cand(tag: 'y$i', tier: AlertTier.high), at(200 + i)), at(200 + i), hapticFired: true);
      }
      expect(log.peakUtterancesPerMinute(), 4);
    });

    test('median latency', () {
      final log = AlertLog(start: t0);
      expect(log.medianLatencyMs(), isNull);
      for (final ms in [900, 1200, 1000, 5000, 1100]) {
        log.latency(ms);
      }
      expect(log.medianLatencyMs(), 1100);
    });

    test('the log is capped so a long walk cannot exhaust memory', () {
      final log = AlertLog(start: t0, maxEvents: 5);
      for (var i = 0; i < 20; i++) {
        log.failsafe('x', on: true, now: at(i));
      }
      expect(log.events.length, 5);
    });
  });
}
