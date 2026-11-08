import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:ahha_app/alert_policy.dart';
import 'package:ahha_app/detection_logic.dart';

const _model = DistanceModel(cameraHeightM: 1.3, pitchDeg: 5.5, fovVDeg: 63.0, yHorizon: 0.5);

/// Box-bottom y that the distance model reads as [feet] (inverse of distanceFeet).
double yFor(double feet) {
  final angle = math.atan(_model.cameraHeightM * DistanceModel.metersToFeet / feet) * 180 / math.pi;
  return (angle - _model.pitchDeg) / _model.fovVDeg + _model.yHorizon;
}

Map<String, dynamic> det(String tag, double feet, {String? label, double conf = 0.85, double x1 = 0.35, double x2 = 0.65}) => {
      'box': [x1, 0.1, x2, yFor(feet), conf],
      'tag': tag,
      'label': label ?? tag.replaceAll('_', ' '),
      'model': 'test',
    };

Candidate cand(String tag, Proximity p, {String zone = 'center', double dist = 8, AlertTier tier = AlertTier.medium, String label = 'chair'}) =>
    Candidate(
      tag: tag,
      label: label,
      zone: zone,
      model: 't',
      distFeet: dist,
      clipped: false,
      proximity: p,
      severity: 2,
      tier: tier,
      conf: 0.9,
      box: const [0.3, 0.2, 0.7, 0.9],
      yMax: 0.9,
    );

class Counts {
  int alerts = 0; // dispatches (each one is a haptic)
  int spoken = 0;
  int veryNearAlerts = 0;
  @override
  String toString() => 'alerts=$alerts spoken=$spoken';
}

/// Runs a 60-second scene at 1 frame/s. [frame] gives the detections for second i.
Counts simulate(List<Map<String, dynamic>> Function(int sec) frame, {required bool field}) {
  final pipe = field
      ? DetectionPipeline(distanceModel: _model, config: kFieldPipelineConfig)
      : DetectionPipeline(distanceModel: _model);
  // Same policy settings as lib/main.dart.
  final policy = field ? AlertPolicy(speakBands: true, criticalSpeechGap: const Duration(seconds: 3)) : AlertPolicy();
  final c = Counts();
  final start = DateTime(2026, 1, 1);
  for (var s = 0; s < 60; s++) {
    final now = start.add(Duration(seconds: s));
    final r = pipe.process(frame(s), now);
    final a = r.alert;
    if (a == null) continue;
    c.alerts++;
    if (a.proximity == Proximity.veryNear) c.veryNearAlerts++;
    if (policy.decide(a, now).speak) c.spoken++;
  }
  return c;
}

void main() {
  group('A4: thresholds are exactly 1.5x the originals, kept in one place', () {
    const orig = PipelineConfig();
    test('very near / near / max range', () {
      expect(kFieldPipelineConfig.veryNearFeet, closeTo(orig.veryNearFeet * 1.5, 1e-9));
      expect(kFieldPipelineConfig.nearFeet, closeTo(orig.nearFeet * 1.5, 1e-9));
      expect(kFieldPipelineConfig.maxDistFeet, closeTo(orig.maxDistFeet * 1.5, 1e-9));
    });

    test('the distance model itself is untouched', () {
      expect(_model.cameraHeightM, 1.3);
      expect(_model.pitchDeg, 5.5);
      expect(_model.fovVDeg, 63.0);
      expect(_model.yHorizon, 0.5);
    });

    test('a chair that read 7.4 ft (seen on a phone at about 4-5 ft) is now very near; before it was only near', () {
      expect(proximityFor(7.4, false, orig), Proximity.near);
      expect(proximityFor(7.4, false, kFieldPipelineConfig), Proximity.veryNear);
    });

    test('bands still exist at the new scale (very near / near / far)', () {
      expect(proximityFor(10.0, false, kFieldPipelineConfig), Proximity.veryNear);
      expect(proximityFor(12.0, false, kFieldPipelineConfig), Proximity.near);
      expect(proximityFor(14.0, false, kFieldPipelineConfig), Proximity.far);
      expect(proximityFor(14.0, true, kFieldPipelineConfig), Proximity.veryNear, reason: 'clipped is always very near');
    });
  });

  group('A4: repeat intervals still follow the ORIGINAL 7 / 8.5 ft thresholds', () {
    test('a chair at an estimated 9 ft is "very near" in tier but repeats every 3 s, as it did when it was "far"', () {
      final p = DetectionPipeline(distanceModel: _model, config: kFieldPipelineConfig);
      var t = DateTime(2026, 1, 1);
      final fired = <int>[];
      for (var s = 0; s < 12; s++) {
        final r = p.process([det('obstacle_low', 9.0, label: 'chair')], t.add(Duration(seconds: s)));
        if (r.alert != null) {
          fired.add(s);
          expect(r.alert!.proximity, Proximity.veryNear);
        }
      }
      expect(fired.skip(1).toList().asMap().entries.every((e) => e.key == 0 || fired[e.key + 1] - fired[e.key] == 3), isTrue,
          reason: 'fired at $fired');
    });
  });

  group('A4: spoken bands, no numbers', () {
    test('near and far carry no digits and no "feet"', () {
      for (final p in Proximity.values) {
        final s = AlertPolicy.speechFor(cand('obstacle_low', p, dist: 9), bands: true);
        expect(s, isNot(matches(RegExp(r'\d'))));
        expect(s.toLowerCase(), isNot(contains('feet')));
      }
    });

    test('exact wording per band, centre and sides', () {
      expect(AlertPolicy.speechFor(cand('o', Proximity.veryNear), bands: true), 'Chair very close ahead.');
      expect(AlertPolicy.speechFor(cand('o', Proximity.near), bands: true), 'Chair close ahead.');
      expect(AlertPolicy.speechFor(cand('o', Proximity.far), bands: true), 'Chair ahead.');
      expect(AlertPolicy.speechFor(cand('o', Proximity.near, zone: 'left'), bands: true), 'Chair close on your left.');
      expect(AlertPolicy.speechFor(cand('o', Proximity.far, zone: 'right'), bands: true), 'Chair on your right.');
    });

    test('critical wording is unchanged by bands', () {
      final c = cand('stairs_down', Proximity.veryNear, tier: AlertTier.critical, label: 'stairs down');
      expect(AlertPolicy.speechFor(c, bands: true), 'Stop. Stairs down.');
    });

    test('the default (non-band) wording is unchanged: numbers still read out', () {
      expect(AlertPolicy.speechFor(cand('o', Proximity.near, dist: 8)), 'Chair ahead, 8 feet.');
    });

    test('"no change" is judged by band in band mode: a 2 ft move inside one band stays quiet', () {
      final p = AlertPolicy(speakBands: true);
      final t = DateTime(2026, 1, 1);
      expect(p.decide(cand('o', Proximity.near, dist: 11), t).speak, isTrue);
      expect(p.decide(cand('o', Proximity.near, dist: 12.5), t.add(const Duration(seconds: 3))).speak, isFalse);
    });

    test('...and a change of band is spoken even when the feet barely moved', () {
      final p = AlertPolicy(speakBands: true);
      final t = DateTime(2026, 1, 1);
      expect(p.decide(cand('o', Proximity.far, dist: 13.0), t).speak, isTrue);
      expect(p.decide(cand('o', Proximity.near, dist: 12.6), t.add(const Duration(seconds: 3))).speak, isTrue);
    });
  });

  group('critical speech repeat gap (speech only)', () {
    Candidate stairsDown(Proximity p) =>
        cand('stairs_down', p, tier: AlertTier.critical, label: 'stairs down');
    DateTime at(int s) => DateTime(2026, 1, 1).add(Duration(seconds: s));

    test('default (zero gap) keeps the original: critical is spoken every time', () {
      final p = AlertPolicy();
      for (var s = 0; s < 5; s++) {
        expect(p.decide(stairsDown(Proximity.veryNear), at(s)).speak, isTrue);
      }
    });

    test('with a 3 s gap: first is spoken, repeats inside 3 s are not, then it speaks again', () {
      final p = AlertPolicy(criticalSpeechGap: const Duration(seconds: 3));
      final spoke = [for (var s = 0; s < 7; s++) p.decide(stairsDown(Proximity.veryNear), at(s)).speak];
      expect(spoke, [true, false, false, true, false, false, true]);
    });

    test('the haptic is NOT held back: every repeat still carries the full triple pulse', () {
      final p = AlertPolicy(criticalSpeechGap: const Duration(seconds: 3));
      p.decide(stairsDown(Proximity.veryNear), at(0));
      final out = p.decide(stairsDown(Proximity.veryNear), at(1));
      expect(out.speak, isFalse);
      expect(out.suppressedReason, 'repeat');
      expect(out.haptic.pattern, [0, 100, 60, 100, 60, 100]);
      expect(out.haptic.peakAmplitude, 255);
    });

    test('a different hazard, or a change of band, is spoken immediately', () {
      final p = AlertPolicy(criticalSpeechGap: const Duration(seconds: 3));
      p.decide(stairsDown(Proximity.veryNear), at(0));
      expect(p.decide(cand('vehicle', Proximity.veryNear, tier: AlertTier.critical, label: 'car'), at(1)).speak, isTrue);
      expect(p.decide(stairsDown(Proximity.near), at(1)).speak, isTrue);
    });

    test('critical is still never limited by the per-minute budget', () {
      final p = AlertPolicy(criticalSpeechGap: const Duration(seconds: 3));
      // 12 high-tier utterances fill the high budget...
      for (var i = 0; i < 12; i++) {
        p.decide(cand('o$i', Proximity.veryNear, tier: AlertTier.high), at(i));
      }
      expect(p.decide(cand('x', Proximity.veryNear, tier: AlertTier.high), at(13)).suppressedReason, 'budget');
      // ...and a critical alert is still spoken.
      expect(p.decide(stairsDown(Proximity.veryNear), at(14)).speak, isTrue);
    });

    test('forgetAnnounced() (a fail-safe spoke) lets the critical speak again straight away', () {
      final p = AlertPolicy(criticalSpeechGap: const Duration(seconds: 3));
      p.decide(stairsDown(Proximity.veryNear), at(0));
      p.forgetAnnounced();
      expect(p.decide(stairsDown(Proximity.veryNear), at(1)).speak, isTrue);
    });
  });

  group('H5: alert counts in 60 s scenes, before (original config) vs after (field config)', () {
    // Synthetic scripted scenes, NOT real footage. They show how the changes
    // interact; they are not evidence about real-world behaviour.
    final scenes = <String, List<Map<String, dynamic>> Function(int)>{
      'chair static at est 6 ft': (s) => [det('obstacle_low', 6, label: 'chair')],
      'chair static at est 9 ft': (s) => [det('obstacle_low', 9, label: 'chair')],
      'person static at est 6 ft': (s) => [det('person', 6, label: 'person')],
      'stairs down 6 ft (0.9)': (s) => [det('stairs_down', 6, conf: 0.9)],
      'car 8 ft (0.9)': (s) => [det('vehicle', 8, label: 'car', conf: 0.9)],
      'chair 6 ft + person 9 ft left': (s) =>
          [det('obstacle_low', 6, label: 'chair'), det('person', 9, label: 'person', x1: 0.05, x2: 0.25)],
      'chair static at est 13 ft': (s) => [det('obstacle_low', 13, label: 'chair')],
      'chair approaching 14 -> 3 ft': (s) => [det('obstacle_low', math.max(3.0, 14 - s * 0.35), label: 'chair')],
    };

    final before = <String, Counts>{};
    final after = <String, Counts>{};
    setUpAll(() {
      scenes.forEach((name, f) {
        before[name] = simulate(f, field: false);
        after[name] = simulate(f, field: true);
      });
      // ignore: avoid_print
      print('\nH5 (60 s, 1 frame/s, synthetic)\n${'scene'.padRight(34)} before                    after');
      for (final n in scenes.keys) {
        // ignore: avoid_print
        print('${n.padRight(34)} ${before[n].toString().padRight(26)}${after[n]}');
      }
    });

    for (final name in [
      'chair static at est 6 ft',
      'chair static at est 9 ft',
      'person static at est 6 ft',
      'stairs down 6 ft (0.9)',
      'chair 6 ft + person 9 ft left',
    ]) {
      test('no more alerts and no more speech than before: $name', () {
        expect(after[name]!.alerts, lessThanOrEqualTo(before[name]!.alerts));
        expect(after[name]!.spoken, lessThanOrEqualTo(before[name]!.spoken));
      });
    }

    test('stairs down held in view: speech drops from every second to every 3 s (haptic unchanged)', () {
      expect(before['stairs down 6 ft (0.9)']!.spoken, 60);
      expect(after['stairs down 6 ft (0.9)']!.spoken, 20);
      expect(after['stairs down 6 ft (0.9)']!.alerts, before['stairs down 6 ft (0.9)']!.alerts);
    });

    test('KNOWN INCREASE (tier promotion): a car at est 8 ft was "high", is now "critical"', () {
      // Critical bypasses the repeat interval, so the haptic fires every frame
      // instead of every 2 s. Speech is held to every 3 s by criticalSpeechGap
      // (without it this scene spoke 60 times in a minute).
      expect(before['car 8 ft (0.9)']!.alerts, 30);
      expect(after['car 8 ft (0.9)']!.alerts, 60);
      expect(after['car 8 ft (0.9)']!.spoken, lessThanOrEqualTo(20));
    });

    test('non-critical speech never exceeds the 12/min budget in any scene', () {
      for (final n in scenes.keys.where((n) => !n.startsWith('stairs') && !n.startsWith('car'))) {
        expect(after[n]!.spoken, lessThanOrEqualTo(12), reason: n);
      }
    });

    test('KNOWN INCREASE: objects at an estimated 10-15 ft were out of range before and now alert', () {
      // This is the direct, intended effect of the 1.5x range (it is what
      // "alert at a larger estimated distance" means). It is NOT hidden.
      expect(before['chair static at est 13 ft']!.alerts, 0);
      expect(after['chair static at est 13 ft']!.alerts, greaterThan(0));
      expect(after['chair approaching 14 -> 3 ft']!.alerts, greaterThanOrEqualTo(before['chair approaching 14 -> 3 ft']!.alerts));
    });
  });
}
