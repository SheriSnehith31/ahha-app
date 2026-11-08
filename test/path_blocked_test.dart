import 'package:flutter_test/flutter_test.dart';
import 'package:ahha_app/alert_policy.dart';
import 'package:ahha_app/detection_logic.dart';
import 'package:ahha_app/path_blocked.dart';

// A box that fills the lane: x 0.30-0.70 (all of the centre third), bottom at
// 0.97, height 0.70 of the frame.
const _big = <double>[0.30, 0.27, 0.70, 0.97, 0.80];

DateTime t(int sec) => DateTime(2026, 1, 1).add(Duration(seconds: sec));

/// Feeds one frame per second; returns what each frame returned.
List<BlockedReason?> feed(PathBlockedDetector d, List<List<List<double>>> frames,
    {bool covered = false, bool critical = false, double lum = 120, List<PlainStats?>? plains, int startSec = 0}) {
  final out = <BlockedReason?>[];
  for (var i = 0; i < frames.length; i++) {
    out.add(d.update(
      boxes: frames[i],
      plain: plains?[i],
      luminance: lum,
      now: t(startSec + i),
      laneCoveredByLabel: covered,
      criticalActive: critical,
    ));
  }
  return out;
}

// ---- synthetic 64x48 gray frames for the label-free check ------------------
const _w = 64, _h = 48;

int _noise(int x, int y) => ((x * 7 + y * 13) % 5) - 2; // deterministic +-2 sensor noise

List<int> grid(int Function(int x, int y) f) => [
      for (var y = 0; y < _h; y++)
        for (var x = 0; x < _w; x++) f(x, y).clamp(0, 255),
    ];

PlainStats stats(List<int> g) => plainStatsFromGray(g, _w, _h);

// Plain ceiling (or a plain wall filling the whole view): one flat shade + noise.
final plainFill = grid((x, y) => 210 + _noise(x, y));
// Far blank wall: flat wall above, a floor below, one wall/floor boundary.
final farWall = grid((x, y) => (y < 34 ? 205 : 120) + _noise(x, y));
// Empty hallway: ceiling, two side walls, and a floor meeting along diagonals.
final hallway = grid((x, y) {
  final dx = (x - 32).abs();
  final isCeiling = y < 10 + (32 - dx) * 0 && y < 12;
  final isFloor = y > 30 + (dx ~/ 3);
  final isSideWall = dx > 14 + (y ~/ 2) && !isFloor;
  final base = isCeiling ? 225 : isFloor ? 110 : isSideWall ? 170 : 195;
  return base + _noise(x, y);
});

void main() {
  group('A3 box rule: what counts as blocking the lane', () {
    final d = PathBlockedDetector();
    test('a lane-filling, tall, bottom-touching box blocks', () => expect(d.blocksLane(_big), isTrue));
    test('overlap of exactly 60% of the lane does not (needs MORE than 60%)', () {
      // lane 1/3..2/3 (width 1/3); 60% of it = 0.2 -> box from 0.4667 covers 0.2
      expect(d.blocksLane([0.4667, 0.2, 0.9, 0.97, 0.8]), isFalse);
      expect(d.blocksLane([0.4600, 0.2, 0.9, 0.97, 0.8]), isTrue);
    });
    test('a box off to one side does not', () => expect(d.blocksLane([0.0, 0.2, 0.3, 0.97, 0.8]), isFalse));
    test('bottom edge above 0.90 does not (object is far away)', () {
      expect(d.blocksLane([0.30, 0.1, 0.70, 0.89, 0.8]), isFalse);
      expect(d.blocksLane([0.30, 0.1, 0.70, 0.90, 0.8]), isTrue);
    });
    test('height of 50% or less does not', () {
      expect(d.blocksLane([0.30, 0.50, 0.70, 0.97, 0.8]), isFalse); // height 0.47
      expect(d.blocksLane([0.30, 0.44, 0.70, 0.97, 0.8]), isTrue); // height 0.53
    });
    test('low-confidence boxes are ignored (below 0.40)', () => expect(d.blocksLane([0.3, 0.2, 0.7, 0.97, 0.39]), isFalse));
  });

  group('A3 box rule: timing', () {
    test('needs 2 of the last 3 frames: fires on the second hit, not the first', () {
      final r = feed(PathBlockedDetector(), [[_big], [_big], [_big]]);
      expect(r[0], isNull);
      expect(r[1], BlockedReason.largeObject);
    });

    test('a single-frame blip never fires', () {
      final r = feed(PathBlockedDetector(), [[_big], [], [], [], []]);
      expect(r, everyElement(isNull));
    });

    test('hits 3 frames apart fall out of the window and do not fire', () {
      final r = feed(PathBlockedDetector(), [[_big], [], [], [_big]]);
      expect(r, everyElement(isNull));
    });

    test('repeats at most once every 5 s while the path stays blocked', () {
      final d = PathBlockedDetector();
      final fired = <int>[];
      for (var s = 0; s < 20; s++) {
        if (d.update(boxes: [_big], luminance: 120, now: t(s)) != null) fired.add(s);
      }
      expect(fired, [1, 6, 11, 16]);
    });
  });

  group('A3 priority and suppression (H2)', () {
    test('a critical alert in the same frame suppresses it', () {
      final r = feed(PathBlockedDetector(), [[_big], [_big]], critical: true);
      expect(r, everyElement(isNull));
    });

    test('a labelled hazard already covering the centre lane suppresses it', () {
      final r = feed(PathBlockedDetector(), [[_big], [_big], [_big]], covered: true);
      expect(r, everyElement(isNull));
    });

    test('suppression does not lose the history: once the cover is gone it fires immediately', () {
      final d = PathBlockedDetector();
      feed(d, [[_big], [_big]], covered: true);
      final r = d.update(boxes: [_big], luminance: 120, now: t(2));
      expect(r, BlockedReason.largeObject);
    });

    test('pipeline reports centerCovered for a confirmed centre hazard, not for an off-path or info one', () {
      const model = DistanceModel(cameraHeightM: 1.3, pitchDeg: 5.5, fovVDeg: 63.0);
      Map<String, dynamic> det(String tag, double x1, double x2, double y2) => {
            'box': [x1, 0.2, x2, y2, 0.9],
            'tag': tag,
            'label': tag,
            'model': 't',
          };
      final center = DetectionPipeline(distanceModel: model);
      PipelineResult? r;
      for (var i = 0; i < 3; i++) {
        r = center.process([det('obstacle_low', 0.4, 0.6, 0.95)], t(i));
      }
      expect(r!.centerCovered, isTrue);

      final side = DetectionPipeline(distanceModel: model);
      for (var i = 0; i < 3; i++) {
        r = side.process([det('stairs_down', 0.0, 0.2, 0.95)], t(i));
      }
      expect(r!.centerCovered, isFalse, reason: 'left-zone hazard does not cover the centre lane');

      final person = DetectionPipeline(distanceModel: model);
      for (var i = 0; i < 3; i++) {
        r = person.process([det('person', 0.4, 0.6, 0.85)], t(i)); // person, near: info tier
      }
      expect(r!.centerCovered, isFalse, reason: 'info-tier is never dispatched, so it does not cover');
    });
  });

  group('A3 what the alert is: severity 2, strong double pulse, existing budget', () {
    final c = blockedPathCandidate();

    test('severity 2, never critical, centre lane', () {
      expect(c.severity, 2);
      expect(c.tier, isNot(AlertTier.critical));
      expect(c.tier, AlertTier.high);
      expect(c.zone, 'center');
    });

    test('says exactly "Path blocked ahead."', () {
      final out = AlertPolicy().decide(c, t(0));
      expect(out.speech, 'Path blocked ahead.');
      expect(out.speak, isTrue);
    });

    test('uses the strong double-pulse haptic (two pulses at full high-tier strength)', () {
      final h = AlertPolicy().decide(c, t(0)).haptic;
      expect(h.pattern.length, 4);
      expect(h.pattern, [0, 300, 90, 300]);
      expect(h.peakAmplitude, 230);
      expect(h.description, startsWith('DOUBLE PULSE'));
    });

    test('is not suppressed as "no change" when it repeats', () {
      final p = AlertPolicy();
      expect(p.decide(c, t(0)).speak, isTrue);
      expect(p.decide(c, t(5)).speak, isTrue);
    });

    test('still obeys the speech budget (12 high per minute)', () {
      final p = AlertPolicy();
      var spoken = 0;
      for (var i = 0; i < 20; i++) {
        if (p.decide(c, t(i)).speak) spoken++;
      }
      expect(spoken, 12);
      expect(p.decide(c, t(21)).suppressedReason, 'budget');
    });

    test('is tagged with a registered severity', () => expect(kHazardSeverity[kPathBlockedTag], 2));
  });

  group('A3 label-free wall check (H3): ships OFF', () {
    test('the shipped default is OFF', () => expect(kLabelFreeWallCheck, isFalse));

    test('with the flag off it never fires, even on a perfectly plain frame', () {
      final d = PathBlockedDetector();
      final r = feed(d, List.filled(6, const <List<double>>[]), plains: List.filled(6, stats(plainFill)));
      expect(r, everyElement(isNull));
    });

    group('with the flag turned on', () {
      PathBlockedDetector on() => PathBlockedDetector(wallCheckEnabled: true);

      test('a far blank wall (floor and a wall/floor boundary visible) does NOT fire', () {
        final r = feed(on(), List.filled(8, const <List<double>>[]), plains: List.filled(8, stats(farWall)));
        expect(r, everyElement(isNull));
      });

      test('an empty hallway (side walls, ceiling, floor) does NOT fire', () {
        final r = feed(on(), List.filled(8, const <List<double>>[]), plains: List.filled(8, stats(hallway)));
        expect(r, everyElement(isNull));
      });

      test('a frame too dark to see does NOT fire (that is the camera-dark fail-safe\'s job)', () {
        final dark = grid((x, y) => 12 + _noise(x, y).abs());
        final r = feed(on(), List.filled(6, const <List<double>>[]), plains: List.filled(6, stats(dark)), lum: 15);
        expect(r, everyElement(isNull));
      });

      test('a truly featureless bright frame fires only on the 3rd consecutive frame', () {
        final r = feed(on(), List.filled(5, const <List<double>>[]), plains: List.filled(5, stats(plainFill)));
        expect(r[0], isNull);
        expect(r[1], isNull);
        expect(r[2], BlockedReason.plainWall);
      });

      test('one textured frame in between resets the 3-frame count', () {
        final p = [stats(plainFill), stats(plainFill), stats(hallway), stats(plainFill), stats(plainFill)];
        final r = feed(on(), List.filled(5, const <List<double>>[]), plains: p);
        expect(r, everyElement(isNull));
      });

      test('KNOWN LIMIT: a plain ceiling is pixel-for-pixel a plain wall, so it DOES fire', () {
        // This is why the flag ships OFF. Documented in KNOWN_LIMITS.md. H3 asked
        // for a ceiling that does not fire; that cannot be achieved from pixels.
        final ceiling = grid((x, y) => 232 + _noise(x, y));
        final r = feed(on(), List.filled(4, const <List<double>>[]), plains: List.filled(4, stats(ceiling)));
        expect(r[2], BlockedReason.plainWall);
      });
    });

    test('plainStatsFromGray: featureless frame is ~0, textured is far above the 1% limit', () {
      expect(stats(plainFill).edgeFractionAll, lessThan(0.001));
      expect(stats(farWall).edgeFractionAll, greaterThan(PathBlockedDetector.maxEdgeFraction));
      expect(stats(hallway).edgeFractionAll, greaterThan(PathBlockedDetector.maxEdgeFraction));
    });
  });
}
