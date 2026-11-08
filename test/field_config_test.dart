import 'package:flutter_test/flutter_test.dart';
import 'package:ahha_app/detection_logic.dart';

// Tests for kFieldPipelineConfig: the settings the app actually runs with after
// real phone testing. The older tests keep pinning PipelineConfig's defaults.
const _model = DistanceModel(cameraHeightM: 1.3, pitchDeg: 5.5, fovVDeg: 63.0, yHorizon: 0.5);

Map<String, dynamic> det(
  String tag, {
  double x1 = 0.3,
  double x2 = 0.7,
  double y2 = 0.95, // ~6.4 ft estimated: very near
  double conf = 0.8,
  String? label,
}) =>
    {
      'box': [x1, 0.2, x2, y2, conf],
      'tag': tag,
      'label': label ?? tag.replaceAll('_', ' '),
      'model': 'test',
    };

DetectionPipeline field() => DetectionPipeline(distanceModel: _model, config: kFieldPipelineConfig);

/// Runs one frame per entry (1 s apart). `null` = nothing detected that frame.
/// Returns the result of every frame.
List<PipelineResult> run(DetectionPipeline p, List<Map<String, dynamic>?> frames) {
  var t = DateTime(2026, 1, 1);
  final out = <PipelineResult>[];
  for (final f in frames) {
    out.add(p.process(f == null ? [] : [f], t));
    t = t.add(const Duration(seconds: 1));
  }
  return out;
}

void main() {
  group('A1: confirmation for hazards below severity 3 is 3 of the last 5 frames', () {
    test('a chair seen in only 2 of 5 frames is NOT confirmed', () {
      final r = run(field(), [det('obstacle_low', label: 'chair'), null, det('obstacle_low', label: 'chair'), null, null]);
      expect(r.map((x) => x.confirmedCount), everyElement(0));
    });

    test('a chair seen in 3 of 5 frames (not consecutive) IS confirmed on the third sighting', () {
      final r = run(field(), [
        det('obstacle_low', label: 'chair'),
        null,
        det('obstacle_low', label: 'chair'),
        null,
        det('obstacle_low', label: 'chair'),
      ]);
      expect(r[0].confirmedCount, 0);
      expect(r[2].confirmedCount, 0);
      expect(r[4].confirmedCount, 1);
    });

    test('the old rule (2 of 3) would have confirmed that same 2-sighting chair; the field rule does not', () {
      final frames = [det('obstacle_low', label: 'chair'), det('obstacle_low', label: 'chair'), null];
      final old = DetectionPipeline(distanceModel: _model);
      expect(run(old, frames)[1].confirmedCount, 1);
      expect(run(field(), frames)[1].confirmedCount, 0);
    });

    test('a sighting that is more than 5 frames old no longer counts', () {
      final r = run(field(), [
        det('obstacle_low', label: 'chair'),
        det('obstacle_low', label: 'chair'),
        null,
        null,
        null,
        det('obstacle_low', label: 'chair'),
      ]);
      expect(r.last.confirmedCount, 0, reason: 'frames 1-2 have slid out of the 5-frame window');
    });
  });

  group('A1: stairs down and vehicles are not weakened', () {
    test('stairs down at 0.85+ confidence is still confirmed on the first frame (fast path)', () {
      final r = run(field(), [det('stairs_down', conf: 0.9)]);
      expect(r[0].confirmedCount, 1);
      expect(r[0].alert?.tier, AlertTier.critical);
    });

    test('stairs down below the fast-path confidence still confirms in 2 of 3 frames', () {
      final r = run(field(), [det('stairs_down', conf: 0.6), det('stairs_down', conf: 0.6)]);
      expect(r[0].confirmedCount, 0);
      expect(r[1].confirmedCount, 1);
    });

    test('a vehicle still confirms in 2 of 3 frames and its fast path is untouched', () {
      final r = run(field(), [det('vehicle', label: 'car', conf: 0.6), det('vehicle', label: 'car', conf: 0.6)]);
      expect(r[1].confirmedCount, 1);
      expect(run(field(), [det('vehicle', label: 'car', conf: 0.9)])[0].confirmedCount, 1);
    });

    test('field config does not change the severity-3 settings at all', () {
      const d = PipelineConfig();
      expect(kFieldPipelineConfig.confirmWindow, d.confirmWindow);
      expect(kFieldPipelineConfig.confirmNeeded, d.confirmNeeded);
      expect(kFieldPipelineConfig.fastPathConf, d.fastPathConf);
      expect(kFieldPipelineConfig.minConf, d.minConf);
      expect(kFieldPipelineConfig.minConfFor('stairs_down', 'stairs down'), d.minConf);
      expect(kFieldPipelineConfig.minConfFor('vehicle', 'car'), d.minConf);
    });
  });

  group('A1: the two false alarms seen on a real phone', () {
    test('"STAIRS UP 45%" on plain floor is rejected, even if it repeats every frame', () {
      final r = run(field(), List.filled(6, det('stairs_up', conf: 0.45)));
      expect(r.map((x) => x.rawCount), everyElement(0), reason: 'dropped at the confidence floor');
      expect(r.map((x) => x.alert), everyElement(isNull));
    });

    test('"DESK 74%" on plain floor is rejected, even if it repeats every frame', () {
      final r = run(field(), List.filled(6, det('obstacle_low', label: 'desk', conf: 0.74)));
      expect(r.map((x) => x.rawCount), everyElement(0));
      expect(r.map((x) => x.alert), everyElement(isNull));
    });

    test('a confident desk (0.85) and confident stairs up (0.60) are still accepted', () {
      final desk = run(field(), List.filled(3, det('obstacle_low', label: 'desk', conf: 0.85)));
      expect(desk.last.confirmedCount, 1);
      final up = run(field(), List.filled(3, det('stairs_up', conf: 0.60)));
      expect(up.last.confirmedCount, 1);
    });

    test('the desk floor does NOT apply to chairs or doors (same policy tag)', () {
      final chair = run(field(), List.filled(3, det('obstacle_low', label: 'chair', conf: 0.5)));
      expect(chair.last.confirmedCount, 1);
      final door = run(field(), List.filled(3, det('obstacle_low', label: 'door', conf: 0.5)));
      expect(door.last.confirmedCount, 1);
    });

    test('the stairs-up floor does NOT apply to stairs down', () {
      final r = run(field(), [det('stairs_down', conf: 0.5), det('stairs_down', conf: 0.5)]);
      expect(r[1].confirmedCount, 1);
    });

    test('a genuine up-stairs at the bottom of the verified 32-65% range is lost (documented trade-off)', () {
      // Stairs model correct detections were seen at 32-65%; below 0.55 is now dropped.
      final r = run(field(), List.filled(4, det('stairs_up', conf: 0.40)));
      expect(r.last.confirmedCount, 0);
    });
  });
}
