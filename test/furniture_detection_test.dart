import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ahha_app/detection_logic.dart';
import 'package:ahha_app/furniture_detection.dart';

final _jpeg = Uint8List.fromList([1, 2, 3]);

DeviceBox box(String label, double score, {double x1 = 0.3, double y1 = 0.2, double x2 = 0.7, double y2 = 0.95}) =>
    DeviceBox(label: label, score: score, x1: x1, y1: y1, x2: x2, y2: y2);

Map<String, dynamic> rf(String tag, double conf, {double x1 = 0.3, double y1 = 0.2, double x2 = 0.7, double y2 = 0.95, String label = 'chair'}) => {
      'box': [x1, y1, x2, y2, conf],
      'tag': tag,
      'label': label,
      'model': 'obstacle',
    };

/// Scripted fake: each call pops the next behaviour.
class FakeSource implements FurnitureSource {
  FakeSource(this.script);
  final List<Future<List<DeviceBox>> Function()> script;
  int calls = 0;

  @override
  Future<List<DeviceBox>> detect(Uint8List jpeg) {
    final f = script[calls < script.length ? calls : script.length - 1];
    calls++;
    return f();
  }
}

Future<List<DeviceBox>> Function() ok(List<DeviceBox> b) => () async => b;
Future<List<DeviceBox>> Function() boom() => () async => throw StateError('mediapipe failed');

void main() {
  group('B: which classes are kept, and at what confidence', () {
    test('keeps exactly the six furniture classes', () {
      final out = furnitureDetections([
        for (final l in ['chair', 'dining table', 'couch', 'bed', 'tv', 'potted plant']) box(l, 0.5),
      ]);
      expect(out.length, 6);
      expect(out.map((d) => d['label']), ['chair', 'table', 'couch', 'bed', 'tv', 'plant']);
      expect(out.map((d) => d['tag']), everyElement('obstacle_low'));
    });

    test('drops every other COCO class (person, car, dog, laptop, ...)', () {
      final out = furnitureDetections([for (final l in ['person', 'car', 'dog', 'laptop', 'bottle', 'bicycle']) box(l, 0.9)]);
      expect(out, isEmpty);
    });

    test('0.30 is the floor for these classes: 0.30 passes, 0.29 does not', () {
      expect(furnitureDetections([box('chair', 0.30)]).length, 1);
      expect(furnitureDetections([box('chair', 0.29)]), isEmpty);
    });

    test('label matching ignores case', () {
      expect(furnitureDetections([DeviceBox.fromMap({'label': 'Chair', 'score': 0.5, 'x1': 0, 'y1': 0, 'x2': 1, 'y2': 1})]).length, 1);
    });

    test('detections are tagged as coming from the device model', () {
      expect(furnitureDetections([box('couch', 0.6)]).single['model'], kDeviceModelName);
    });
  });

  group('B: the pipeline threshold for device detections is 0.30; everything else stays 0.40', () {
    const model = DistanceModel(cameraHeightM: 1.3, pitchDeg: 5.5, fovVDeg: 63.0);
    int raw(List<Map<String, dynamic>> dets) =>
        DetectionPipeline(distanceModel: model, config: kFieldPipelineConfig).process(dets, DateTime(2026)).rawCount;

    test('a device chair at 0.35 gets through', () {
      expect(raw(furnitureDetections([box('chair', 0.35)])), 1);
    });
    test('a Roboflow chair at 0.35 does not (its floor is still 0.40)', () {
      expect(raw([rf('obstacle_low', 0.35)]), 0);
    });
    test('a Roboflow chair at 0.40 does', () => expect(raw([rf('obstacle_low', 0.40)]), 1));
    test('the stricter desk floor (0.80) is not loosened by the device floor', () {
      expect(raw([rf('obstacle_low', 0.74, label: 'desk')]), 0);
    });
    test('a device detection at 0.29 is still rejected by the pipeline', () {
      expect(raw([
        {'box': [0.3, 0.2, 0.7, 0.95, 0.29], 'tag': 'obstacle_low', 'label': 'chair', 'model': kDeviceModelName}
      ]), 0);
    });
  });

  group('B: merging with Roboflow (IoU > 0.5, keep the higher confidence)', () {
    test('iou of identical boxes is 1, of disjoint boxes 0', () {
      expect(iou([0, 0, 1, 1], [0, 0, 1, 1]), closeTo(1, 1e-9));
      expect(iou([0, 0, 0.2, 0.2], [0.5, 0.5, 1, 1]), 0);
    });

    test('iou of two half-overlapping boxes is 1/3', () {
      expect(iou([0, 0, 1, 1], [0.5, 0, 1.5, 1]), closeTo(1 / 3, 1e-9));
    });

    test('duplicate with a higher device confidence: the device one replaces the Roboflow one', () {
      final m = mergeDetections([rf('obstacle_low', 0.5)], furnitureDetections([box('chair', 0.8)]));
      expect(m.length, 1);
      expect(m.single['model'], kDeviceModelName);
    });

    test('duplicate with a higher Roboflow confidence: the Roboflow one stays, device one is dropped', () {
      final m = mergeDetections([rf('obstacle_low', 0.9)], furnitureDetections([box('chair', 0.5)]));
      expect(m.length, 1);
      expect(m.single['model'], 'obstacle');
    });

    test('equal confidence keeps the Roboflow one', () {
      final m = mergeDetections([rf('obstacle_low', 0.6)], furnitureDetections([box('chair', 0.6)]));
      expect(m.single['model'], 'obstacle');
    });

    test('overlap of exactly 0.5 is NOT a duplicate (needs more than 0.5): both are kept', () {
      // Two boxes with IoU exactly 0.5: widths 1.0 and 0.5 nested -> inter 0.5, union 1.0.
      final a = rf('obstacle_low', 0.7, x1: 0, y1: 0, x2: 1, y2: 1);
      final d = furnitureDetections([box('chair', 0.9, x1: 0, y1: 0, x2: 0.5, y2: 1)]);
      expect(iou([0, 0, 1, 1], [0, 0, 0.5, 1]), closeTo(0.5, 1e-12));
      expect(mergeDetections([a], d).length, 2);
    });

    test('same place but different policy tag is NOT merged (a person is not a chair)', () {
      final m = mergeDetections([rf('person', 0.9, label: 'person')], furnitureDetections([box('chair', 0.9)]));
      expect(m.length, 2);
    });

    test('non-overlapping detections are all kept; Roboflow-only input passes through unchanged', () {
      final r1 = rf('obstacle_low', 0.7, x1: 0, x2: 0.2);
      final d = furnitureDetections([box('couch', 0.6, x1: 0.6, x2: 0.9)]);
      expect(mergeDetections([r1], d).length, 2);
      expect(mergeDetections([r1], const []), [r1]);
    });

    test('merge does not modify its inputs', () {
      final r1 = [rf('obstacle_low', 0.5)];
      final d = furnitureDetections([box('chair', 0.8)]);
      mergeDetections(r1, d);
      expect(r1.single['model'], 'obstacle');
    });
  });

  group('B: failure handling - the app carries on with Roboflow only', () {
    test('a good call returns merge-ready detections and records its time', () async {
      final g = GuardedFurnitureDetector(FakeSource([ok([box('chair', 0.6)])]));
      final r = await g.detect(_jpeg);
      expect(r!.length, 1);
      expect(g.lastMs, isNotNull);
      expect(g.status, startsWith('ok'));
    });

    test('an exception becomes null, not a crash', () async {
      final g = GuardedFurnitureDetector(FakeSource([boom()]));
      expect(await g.detect(_jpeg), isNull);
    });

    test('a synchronous throw inside the source is also contained', () async {
      final g = GuardedFurnitureDetector(_SyncThrower());
      expect(await g.detect(_jpeg), isNull);
    });

    test('a slow call times out to null instead of holding up the frame', () async {
      Future<List<DeviceBox>> slow() => Future.delayed(const Duration(milliseconds: 400), () => [box('chair', 0.9)]);
      final g = GuardedFurnitureDetector(FakeSource([slow]), timeout: const Duration(milliseconds: 50));
      final sw = Stopwatch()..start();
      expect(await g.detect(_jpeg), isNull);
      expect(sw.elapsedMilliseconds, lessThan(300), reason: 'returned at the timeout, not after the slow call');
    });

    test('while a slow call is still running, new frames skip it rather than stacking requests', () async {
      Future<List<DeviceBox>> slow() => Future.delayed(const Duration(milliseconds: 200), () => <DeviceBox>[]);
      final src = FakeSource([slow]);
      final g = GuardedFurnitureDetector(src, timeout: const Duration(milliseconds: 20));
      await g.detect(_jpeg); // times out, but the platform call is still running
      await g.detect(_jpeg); // skipped
      await g.detect(_jpeg); // skipped
      expect(src.calls, 1);
      expect(g.skippedBusy, 2);
      await Future<void>.delayed(const Duration(milliseconds: 260));
      await g.detect(_jpeg); // free again
      expect(src.calls, 2);
    });

    test('after 3 failures in a row it switches itself off and stops calling the source', () async {
      final src = FakeSource([boom()]);
      final g = GuardedFurnitureDetector(src);
      for (var i = 0; i < 6; i++) {
        expect(await g.detect(_jpeg), isNull);
      }
      expect(src.calls, 3);
      expect(g.disabled, isTrue);
      expect(g.status, contains('off'));
    });

    test('a success resets the failure count', () async {
      final src = FakeSource([boom(), boom(), ok([]), boom(), boom(), ok([])]);
      final g = GuardedFurnitureDetector(src);
      for (var i = 0; i < 6; i++) {
        await g.detect(_jpeg);
      }
      expect(g.disabled, isFalse);
      expect(src.calls, 6);
    });

    test('reset() brings a disabled detector back (e.g. after a mode switch)', () async {
      final g = GuardedFurnitureDetector(FakeSource([boom(), boom(), boom(), ok([box('chair', 0.9)])]));
      for (var i = 0; i < 3; i++) {
        await g.detect(_jpeg);
      }
      expect(g.disabled, isTrue);
      g.reset();
      expect((await g.detect(_jpeg))!.length, 1);
    });

    test('with the detector failing, the Roboflow detections reach the merge unchanged', () async {
      final g = GuardedFurnitureDetector(FakeSource([boom()]));
      final roboflow = [rf('obstacle_low', 0.7)];
      final device = await g.detect(_jpeg);
      expect(mergeDetections(roboflow, device ?? const []), roboflow);
    });
  });
}

class _SyncThrower implements FurnitureSource {
  @override
  Future<List<DeviceBox>> detect(Uint8List jpeg) => throw StateError('sync failure');
}
