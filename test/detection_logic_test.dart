import 'package:flutter_test/flutter_test.dart';
import 'package:ahha_app/detection_logic.dart';

// Same constants main.dart ships with.
const _model = DistanceModel(cameraHeightM: 1.3, pitchDeg: 5.5, fovVDeg: 63.0, yHorizon: 0.5);

// Box-bottom (y2) values and what they mean with those constants:
//   1.00 -> clipped (base out of frame, <= ~5.7 ft)   0.95 -> ~6.4 ft (very near)
//   0.90 -> ~7.2 ft (near)   0.85 -> ~8.2 ft (near)   0.82 -> ~8.9 ft (far)
//   0.70 -> ~13 ft (beyond range, ignored)

Map<String, dynamic> det(
  String tag, {
  double x1 = 0.3,
  double x2 = 0.7,
  double y2 = 0.8,
  double conf = 0.8,
  String? label,
}) =>
    {
      'box': [x1, 0.2, x2, y2, conf],
      'tag': tag,
      'label': label ?? tag.replaceAll('_', ' '),
      'model': 'test',
    };

DetectionPipeline newPipeline() => DetectionPipeline(distanceModel: _model);

// Feeds the same detections for several frames, 1s apart, returning the
// result of the last frame.
PipelineResult feed(DetectionPipeline p, List<Map<String, dynamic>> dets, int frames, {DateTime? start}) {
  var t = start ?? DateTime(2026, 1, 1);
  late PipelineResult r;
  for (var i = 0; i < frames; i++) {
    r = p.process(dets, t);
    t = t.add(const Duration(seconds: 1));
  }
  return r;
}

void main() {
  group('DistanceModel vs field readings', () {
    test('a box ending ~78% down the frame reads about 10 ft (the 10 ft point)', () {
      expect(_model.distanceFeet(0.776)!, closeTo(10.0, 0.6));
    });

    test('a box ending ~97% down reads about 6 ft (the 6 ft door point)', () {
      expect(_model.distanceFeet(0.97)!, closeTo(6.0, 0.4));
    });

    test('the nearest visible floor is ~5.7 ft; nothing closer can be measured', () {
      expect(_model.floorFeet, closeTo(5.7, 0.2));
    });

    test('lower in the frame is always closer', () {
      double prev = double.infinity;
      for (var y = 0.55; y <= 1.0; y += 0.05) {
        final d = _model.distanceFeet(y)!;
        expect(d, lessThan(prev));
        prev = d;
      }
    });

    test('at or above the horizon there is no distance', () {
      expect(_model.distanceFeet(0.30), isNull);
    });
  });

  group('proximity bands', () {
    const c = PipelineConfig();
    test('clipped is always very near, whatever the number says', () {
      expect(proximityFor(9.9, true, c), Proximity.veryNear);
    });
    test('band edges: <=7 very near, <=8.5 near, beyond far', () {
      expect(proximityFor(7.0, false, c), Proximity.veryNear);
      expect(proximityFor(7.01, false, c), Proximity.near);
      expect(proximityFor(8.5, false, c), Proximity.near);
      expect(proximityFor(8.51, false, c), Proximity.far);
    });
  });

  group('tier policy: severity x proximity x in-path', () {
    AlertTier? t(String tag, Proximity p, [String zone = 'center']) =>
        classifyTier(tag: tag, proximity: p, zone: zone);

    test('severity 3 in path (stairs down, vehicles): critical / high / medium', () {
      for (final tag in ['stairs_down', 'vehicle']) {
        expect(t(tag, Proximity.veryNear), AlertTier.critical, reason: tag);
        expect(t(tag, Proximity.near), AlertTier.high, reason: tag);
        expect(t(tag, Proximity.far), AlertTier.medium, reason: tag);
      }
    });

    test('severity 2 in path (potholes, obstacles, stairs up, bicycles): high / medium / medium', () {
      for (final tag in ['pothole', 'obstacle_low', 'stairs_up', 'two_wheeler']) {
        expect(t(tag, Proximity.veryNear), AlertTier.high, reason: tag);
        expect(t(tag, Proximity.near), AlertTier.medium, reason: tag);
        expect(t(tag, Proximity.far), AlertTier.medium, reason: tag);
      }
    });

    test('people/dogs only interrupt when nearly touching, otherwise info (shown, silent)', () {
      for (final tag in ['person', 'dog']) {
        expect(t(tag, Proximity.veryNear), AlertTier.medium, reason: tag);
        expect(t(tag, Proximity.near), AlertTier.info, reason: tag);
        expect(t(tag, Proximity.far), AlertTier.info, reason: tag);
      }
    });

    test('off the walking path only drops and vehicles matter, and only when close', () {
      for (final tag in ['stairs_down', 'vehicle']) {
        expect(t(tag, Proximity.veryNear, 'left'), AlertTier.high, reason: tag);
        expect(t(tag, Proximity.near, 'right'), AlertTier.medium, reason: tag);
        expect(t(tag, Proximity.far, 'left'), isNull, reason: tag);
      }
      for (final tag in ['pothole', 'obstacle_low', 'person', 'dog', 'two_wheeler', 'stairs_up']) {
        for (final p in Proximity.values) {
          expect(t(tag, p, 'left'), isNull, reason: '$tag $p');
        }
      }
    });

    test('an unknown tag is treated as low severity', () {
      expect(t('mystery', Proximity.near), AlertTier.info);
    });
  });

  group('close objects that cannot be measured', () {
    test('a chair whose base is out of frame is flagged clipped and treated as immediate', () {
      final r = feed(newPipeline(), [det('obstacle_low', y2: 1.0, label: 'chair')], 2);
      expect(r.display!.clipped, isTrue);
      expect(r.display!.proximity, Proximity.veryNear);
      expect(r.display!.tier, AlertTier.high);
      expect(r.display!.distFeet, closeTo(_model.floorFeet, 0.01));
    });

    test('the same chair well inside the frame is NOT clipped and stays measured', () {
      final r = feed(newPipeline(), [det('obstacle_low', y2: 0.85)], 2);
      expect(r.display!.clipped, isFalse);
      expect(r.display!.distFeet, closeTo(8.2, 0.5));
      expect(r.display!.proximity, Proximity.near);
      expect(r.display!.tier, AlertTier.medium);
    });

    test('stairs down with base out of frame is critical', () {
      final r = feed(newPipeline(), [det('stairs_down', y2: 1.0)], 2);
      expect(r.display!.tier, AlertTier.critical);
    });

    // The clip fallback only fires when the box bottom reaches clipYMax
    // (0.985). Just short of that the distance is still measured (~5.9 ft) —
    // but that is inside the "very near" band, so it is still treated as High.
    test('boundary: box bottom at 0.984 is measured (not clipped) yet still very near', () {
      final r = feed(newPipeline(), [det('obstacle_low', y2: 0.984)], 2);
      expect(r.display!.clipped, isFalse);
      expect(r.display!.distFeet, closeTo(_model.distanceFeet(0.984)!, 0.001));
      expect(r.display!.proximity, Proximity.veryNear);
      expect(r.display!.tier, AlertTier.high);
    });

    test('boundary: box bottom at 0.985 is clipped and Immediate', () {
      final r = feed(newPipeline(), [det('obstacle_low', y2: 0.985)], 2);
      expect(r.display!.clipped, isTrue);
      expect(r.display!.tier, AlertTier.high);
    });

    test('a clipped candidate reports the floor as an upper bound, never a finer number', () {
      for (final y in [0.985, 0.99, 1.0]) {
        final r = feed(newPipeline(), [det('obstacle_low', y2: y)], 2);
        expect(r.display!.distFeet, closeTo(_model.floorFeet, 0.001), reason: 'y=$y');
      }
    });
  });

  group('street hazards', () {
    test('a car in the path, out of frame, is critical', () {
      final r = feed(newPipeline(), [det('vehicle', y2: 1.0, conf: 0.9, label: 'car')], 1);
      expect(r.alert!.tier, AlertTier.critical);
    });

    test('a car to the side, close, is High rather than Critical', () {
      final r = feed(newPipeline(), [det('vehicle', x1: 0.0, x2: 0.2, y2: 0.95, conf: 0.9)], 1);
      expect(r.alert!.tier, AlertTier.high);
      expect(r.alert!.zone, 'left');
    });

    test('a pothole in the path, close, is High', () {
      final r = feed(newPipeline(), [det('pothole', y2: 0.95, conf: 0.9)], 2);
      expect(r.alert!.tier, AlertTier.high);
    });

    test('a person at near range is shown but never alerts', () {
      final r = feed(newPipeline(), [det('person', y2: 0.85)], 3);
      expect(r.display!.tier, AlertTier.info);
      expect(r.alert, isNull);
    });

    test('a person nearly touching you alerts at Medium', () {
      final r = feed(newPipeline(), [det('person', y2: 1.0)], 2);
      expect(r.alert!.tier, AlertTier.medium);
    });
  });

  group('recognition noise', () {
    test('a one-frame detection never alerts or displays', () {
      final p = newPipeline();
      final r = p.process([det('stairs_down', y2: 1.0)], DateTime(2026, 1, 1));
      expect(r.alert, isNull);
      expect(r.display, isNull);
      expect(r.rawCount, 1);
      expect(r.confirmedCount, 0);
    });

    test('the same detection in a second frame is confirmed and alerts', () {
      final p = newPipeline();
      p.process([det('stairs_down', y2: 1.0)], DateTime(2026, 1, 1));
      final r = p.process([det('stairs_down', y2: 1.0)], DateTime(2026, 1, 1, 0, 0, 1));
      expect(r.alert, isNotNull);
      expect(r.alert!.tier, AlertTier.critical);
    });

    test('fast path: a confident drop/vehicle is confirmed on the FIRST frame', () {
      final r = newPipeline().process([det('vehicle', y2: 0.95, conf: 0.92)], DateTime(2026, 1, 1));
      expect(r.confirmedCount, 1);
      expect(r.alert, isNotNull);
    });

    test('fast path needs both high confidence and high severity', () {
      final lowConf = newPipeline().process([det('vehicle', y2: 0.95, conf: 0.80)], DateTime(2026, 1, 1));
      expect(lowConf.confirmedCount, 0);
      final lowSeverity = newPipeline().process([det('person', y2: 1.0, conf: 0.99)], DateTime(2026, 1, 1));
      expect(lowSeverity.confirmedCount, 0);
      final pothole = newPipeline().process([det('pothole', y2: 1.0, conf: 0.99)], DateTime(2026, 1, 1));
      expect(pothole.confirmedCount, 0, reason: 'potholes are static, so they can afford the 2-frame wait');
    });

    test('the fast path can be switched off', () {
      final p = DetectionPipeline(distanceModel: _model, config: const PipelineConfig(fastPathConf: 1.1));
      final r = p.process([det('vehicle', y2: 1.0, conf: 0.99)], DateTime(2026, 1, 1));
      expect(r.confirmedCount, 0);
    });

    test('a detection followed by a miss frame does not alert', () {
      final p = newPipeline();
      final t0 = DateTime(2026, 1, 1);
      p.process([det('obstacle_low', y2: 0.9)], t0);
      final r2 = p.process([], t0.add(const Duration(seconds: 1)));
      expect(r2.alert, isNull);
    });

    test('low-confidence detections are ignored entirely', () {
      final r = feed(newPipeline(), [det('stairs_down', y2: 1.0, conf: 0.30)], 3);
      expect(r.rawCount, 0);
      expect(r.display, isNull);
    });

    test('off-center obstacles are ignored, off-center stairs-down is kept', () {
      final obstacle = feed(newPipeline(), [det('obstacle_low', x1: 0.0, x2: 0.2, y2: 0.9)], 3);
      expect(obstacle.rawCount, 0);
      final stairs = feed(newPipeline(), [det('stairs_down', x1: 0.0, x2: 0.2, y2: 0.9)], 3);
      expect(stairs.rawCount, 1);
      expect(stairs.display!.zone, 'left');
    });

    test('anything beyond 10 ft is ignored', () {
      final r = feed(newPipeline(), [det('obstacle_low', y2: 0.70)], 3);
      expect(r.rawCount, 0);
    });
  });

  group('the displayed distance no longer jumps between detections', () {
    test('a higher-confidence box of the same tier wins regardless of list order', () {
      final low = det('obstacle_low', y2: 0.87, conf: 0.45); // spurious duplicate, lower
      final high = det('obstacle_low', y2: 0.85, conf: 0.92); // the real one
      for (final order in [
        [low, high],
        [high, low]
      ]) {
        final r = feed(newPipeline(), order, 2);
        expect(r.display!.conf, 0.92);
      }
    });

    // Regression: frame 1 used to go unbuffered (it's unconfirmed), so an
    // outlier on frame 3 met a median of only two readings and dragged the
    // number halfway. Frame 1's reading is now buffered too.
    test('warm-up: an outlier on the 3rd frame is rejected, not averaged in', () {
      final p = newPipeline();
      final t0 = DateTime(2026, 1, 1);
      p.process([det('obstacle_low', y2: 0.85)], t0);
      p.process([det('obstacle_low', y2: 0.85)], t0.add(const Duration(seconds: 1)));
      final r = p.process([det('obstacle_low', y2: 0.96)], t0.add(const Duration(seconds: 2)));
      expect(r.displayDistFeet!, closeTo(_model.distanceFeet(0.85)!, 0.01));
    });

    test('warm-up: the first confirmed reading uses the unconfirmed frame before it', () {
      final p = newPipeline();
      final t0 = DateTime(2026, 1, 1);
      p.process([det('obstacle_low', y2: 0.85)], t0); // unconfirmed, but buffered
      final r = p.process([det('obstacle_low', y2: 0.95)], t0.add(const Duration(seconds: 1)));
      final expected = (_model.distanceFeet(0.85)! + _model.distanceFeet(0.95)!) / 2;
      expect(r.displayDistFeet!, closeTo(expected, 0.01));
    });

    test('a different tag does not inherit another tag\'s readings', () {
      final p = newPipeline();
      final t0 = DateTime(2026, 1, 1);
      p.process([det('obstacle_low', y2: 0.85)], t0);
      p.process([det('obstacle_low', y2: 0.85)], t0.add(const Duration(seconds: 1)));
      // stairs_up appears; its own two frames must decide its number
      p.process([det('stairs_up', y2: 0.90, conf: 0.99)], t0.add(const Duration(seconds: 2)));
      final r = p.process([det('stairs_up', y2: 0.90, conf: 0.99)], t0.add(const Duration(seconds: 3)));
      expect(r.display!.tag, 'stairs_up');
      expect(r.displayDistFeet!, closeTo(_model.distanceFeet(0.90)!, 0.01));
    });

    test('once steady, one outlier reading does not move the number (median of last 3)', () {
      final p = newPipeline();
      final t0 = DateTime(2026, 1, 1);
      for (var i = 0; i < 3; i++) {
        p.process([det('obstacle_low', y2: 0.85)], t0.add(Duration(seconds: i)));
      }
      final r = p.process([det('obstacle_low', y2: 0.96)], t0.add(const Duration(seconds: 3))); // outlier
      final steady = _model.distanceFeet(0.85)!;
      expect(r.displayDistFeet!, closeTo(steady, 0.01));
    });

    test('the last detection is held briefly instead of blanking on one missed frame', () {
      final p = newPipeline();
      final t0 = DateTime(2026, 1, 1);
      p.process([det('obstacle_low', y2: 0.85)], t0);
      p.process([det('obstacle_low', y2: 0.85)], t0.add(const Duration(seconds: 1)));
      final held1 = p.process([], t0.add(const Duration(seconds: 2)));
      final held2 = p.process([], t0.add(const Duration(seconds: 3)));
      final gone = p.process([], t0.add(const Duration(seconds: 4)));
      expect(held1.display, isNotNull);
      expect(held2.display, isNotNull);
      expect(gone.display, isNull);
    });

    test('a critical stairs detection outranks an obstacle for the readout', () {
      final r = feed(newPipeline(), [
        det('obstacle_low', y2: 0.9, conf: 0.95),
        det('stairs_down', y2: 1.0, conf: 0.5),
      ], 2);
      expect(r.display!.tag, 'stairs_down');
    });
  });

  group('alert repeat interval scales with proximity (haptic heartbeat)', () {
    // Frame 1 is unconfirmed, so the first alert is on frame 2 (t0+1s).
    Set<int> alertSeconds(List<Map<String, dynamic>> d) {
      final p = newPipeline();
      final t0 = DateTime(2026, 1, 1);
      final fired = <int>{};
      for (var ms = 0; ms <= 8000; ms += 500) {
        final r = p.process(d, t0.add(Duration(milliseconds: ms)));
        if (r.alert != null) fired.add(ms);
      }
      return fired;
    }

    test('very near repeats every 1 s', () {
      final fired = alertSeconds([det('obstacle_low', y2: 1.0)]).toList()..sort();
      final gaps = [for (var i = 1; i < fired.length; i++) fired[i] - fired[i - 1]];
      expect(gaps, isNotEmpty);
      expect(gaps.every((g) => g == 1000), isTrue, reason: '$fired');
    });

    test('near repeats every 2 s', () {
      final fired = alertSeconds([det('obstacle_low', y2: 0.85)]).toList()..sort();
      final gaps = [for (var i = 1; i < fired.length; i++) fired[i] - fired[i - 1]];
      expect(gaps.every((g) => g == 2000), isTrue, reason: '$fired');
    });

    test('far repeats every 3 s', () {
      final fired = alertSeconds([det('obstacle_low', y2: 0.82)]).toList()..sort();
      final gaps = [for (var i = 1; i < fired.length; i++) fired[i] - fired[i - 1]];
      expect(gaps.every((g) => g == 3000), isTrue, reason: '$fired');
    });

    test('critical alerts bypass the interval entirely', () {
      final p = newPipeline();
      final t0 = DateTime(2026, 1, 1);
      final d = [det('stairs_down', y2: 1.0)];
      p.process(d, t0);
      final a = p.process(d, t0.add(const Duration(seconds: 1)));
      final b = p.process(d, t0.add(const Duration(milliseconds: 1200)));
      expect(a.alert, isNotNull);
      expect(b.alert, isNotNull);
    });

    test('reset() clears confirmation history', () {
      final p = newPipeline();
      final d = [det('stairs_down', y2: 1.0)];
      p.process(d, DateTime(2026, 1, 1));
      p.reset();
      final r = p.process(d, DateTime(2026, 1, 1, 0, 0, 1));
      expect(r.alert, isNull);
    });
  });
}
