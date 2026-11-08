// Tests for the self-test harness. Run with:
//   flutter test tools/eval/eval_core_test.dart
//
// Everything here uses a FAKE API and synthetic images in a temp folder. These
// responses exist only to check the harness's own bookkeeping (parsing,
// caching, scoring, report); they say nothing about how good the real models
// are, and nothing from here is ever written to tools/eval/report.md.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:ahha_app/detection_logic.dart';

import 'eval_core.dart';

Uint8List solidJpeg(int r, int g, int b, {int w = 64, int h = 64}) {
  final im = img.Image(width: w, height: h);
  img.fill(im, color: img.ColorRgb8(r, g, b));
  return Uint8List.fromList(img.encodeJpg(im, quality: 90));
}

/// A mid-grey image with a white block whose position depends on [id], so two
/// ids can never compress to identical bytes (near-identical solid colours can).
Uint8List uniqueJpeg(int id) {
  final im = img.Image(width: 96, height: 96);
  img.fill(im, color: img.ColorRgb8(120, 120, 120));
  img.fillRect(im, x1: (id * 11) % 70, y1: (id * 7) % 70, x2: (id * 11) % 70 + 20, y2: (id * 7) % 70 + 20, color: img.ColorRgb8(250, 250, 250));
  return Uint8List.fromList(img.encodeJpg(im, quality: 90));
}

Map<String, Object> pred(String cls, double conf, {double x = 320, double y = 490, double w = 200, double h = 300}) =>
    {'class': cls, 'class_id': 0, 'x': x, 'y': y, 'width': w, 'height': h, 'confidence': conf};

Map<String, Object> body(List<Map<String, Object>> preds) => {
      'image': {'width': 640, 'height': 640},
      'predictions': preds,
    };

/// y of the box bottom, as a fraction of a 640 px frame, set via the centre y
/// and height: bottom = y + h/2.
Map<String, Object> predBottom(String cls, double conf, double bottomFrac, {double x = 320, double h = 200}) =>
    pred(cls, conf, x: x, y: bottomFrac * 640 - h / 2, h: h);

class FakeApi {
  /// Keyed by 'modelId|frameHash'. The value is a response body (Map), an HTTP status (int) or an Exception to throw.
  final Map<String, Object> scripted = {};
  int calls = 0;

  static final emptyBody = body(const []);

  Future<RawResponse> post(Uri url, Map<String, String> headers, String b, Duration timeout) async {
    calls++;
    final modelId = url.path.substring(1);
    final key = '$modelId|${contentHash(base64Decode(b))}';
    final s = scripted[key];
    if (s is Exception) throw s;
    if (s is int) return RawResponse(status: s, body: 'error body', elapsedMs: 50);
    return RawResponse(
      status: 200,
      body: jsonEncode(s ?? emptyBody),
      headers: {'x-remote-processing-time': '0.05', 'content-type': 'application/json'},
      elapsedMs: 100 + calls,
    );
  }
}

void main() {
  late Directory tmp;
  late AppSettings settings;

  setUpAll(() {
    settings = readAppSettings(File('lib/main.dart').readAsStringSync());
  });

  setUp(() => tmp = Directory.systemTemp.createTempSync('ahha_eval_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Directory imagesDir() => Directory('${tmp.path}/images');
  EvalCache newCache() => EvalCache(Directory('${tmp.path}/cache'));

  /// Writes an image and returns the hash the harness will see for it.
  String addImage(String label, String name, Uint8List bytes) {
    final d = Directory('${imagesDir().path}/$label')..createSync(recursive: true);
    File('${d.path}/$name').writeAsBytesSync(bytes);
    return prepareImage(bytes, jpegQuality: settings.jpegQuality).info.key;
  }

  void script(FakeApi api, String modelId, String hash, Object response) => api.scripted['$modelId|$hash'] = response;

  group('keeping in step with the app', () {
    test('the model tables the harness copied still match lib/main.dart, and its settings parse', () {
      final src = File('lib/main.dart').readAsStringSync();
      expect(specDrift(src), isEmpty);
      expect(readAppSettings(src).notes, isEmpty);
    });

    test('drift is reported when main.dart no longer has a model', () {
      final src = File('lib/main.dart').readAsStringSync().replaceAll('coco/50', 'coco/99');
      final notes = specDrift(src);
      expect(notes.any((n) => n.contains('coco/50')), isTrue);
      expect(notes.any((n) => n.contains('coco/99')), isTrue);
    });

    test('an unreadable main.dart falls back with a note instead of failing', () {
      final s = readAppSettings(null);
      expect(s.notes, isNotEmpty);
      expect(s.darkness, 40.0);
    });
  });

  group('statistics helpers', () {
    test('wilson interval', () {
      final (lo, hi) = wilson(5, 10);
      expect(lo, closeTo(0.237, 0.005));
      expect(hi, closeTo(0.763, 0.005));
      expect(wilson(0, 0), (0.0, 1.0));
      expect(wilson(10, 10).$2, closeTo(1.0, 1e-9));
      expect(wilson(0, 30).$1, 0.0);
    });

    test('percentile (nearest rank) and median', () {
      expect(percentile([100, 200, 300, 400, 500], 90), 500);
      expect(percentile([100, 200, 300, 400, 500], 50), 300);
      expect(percentile([5, 1, 3], 100), 5);
      expect(percentile(const [], 90), 0);
      expect(median([1, 2, 3, 4]), 2.5);
      expect(median([3, 1, 2]), 2);
    });

    test('contentHash is stable and sensitive to content', () {
      final a = Uint8List.fromList([1, 2, 3]);
      expect(contentHash(a), contentHash(Uint8List.fromList([1, 2, 3])));
      expect(contentHash(a), isNot(contentHash(Uint8List.fromList([1, 2, 4]))));
      expect(contentHash(a), isNot(contentHash(Uint8List.fromList([1, 2, 3, 0]))));
    });
  });

  group('frame preparation', () {
    test('a plain JPEG is sent as the original bytes, with brightness measured', () {
      final bytes = uniqueJpeg(22);
      final p = prepareImage(bytes, jpegQuality: 85);
      expect(p.jpeg, bytes);
      expect(p.info.reencoded, isFalse);
      expect(p.info.luminance, closeTo(120, 6));
    });

    test('a dark image reads as dark', () {
      expect(prepareImage(solidJpeg(5, 5, 5), jpegQuality: 85).info.luminance, lessThan(settings.darkness));
    });

    /// A real JPEG with a hand-built EXIF APP1 segment holding Orientation = [orientation],
    /// laid out the way a phone writes it (little-endian TIFF, one IFD0 entry).
    Uint8List jpegWithExifOrientation(int orientation, {int w = 64, int h = 32}) {
      final base = solidJpeg(120, 120, 120, w: w, h: h);
      final tiff = <int>[
        0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00, // "II", 42, IFD0 at offset 8
        0x01, 0x00, // one entry
        0x12, 0x01, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, orientation, 0x00, 0x00, 0x00, // Orientation, SHORT, 1
        0x00, 0x00, 0x00, 0x00, // no next IFD
      ];
      final payload = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00, ...tiff]; // "Exif\0\0" + TIFF
      final len = payload.length + 2;
      return Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE1, len >> 8, len & 0xFF, ...payload, ...base.sublist(2)]);
    }

    /// Width and height as STORED in the JPEG's start-of-frame header, i.e. the
    /// raw pixel layout a server sees before it applies any EXIF rotation.
    (int, int) storedSize(Uint8List b) {
      var i = 2;
      while (i + 9 < b.length) {
        if (b[i] != 0xFF) {
          i++;
          continue;
        }
        final m = b[i + 1];
        if (m >= 0xC0 && m <= 0xCF && m != 0xC4 && m != 0xC8 && m != 0xCC) {
          return ((b[i + 7] << 8) | b[i + 8], (b[i + 5] << 8) | b[i + 6]); // (width, height)
        }
        i += 2 + ((b[i + 2] << 8) | b[i + 3]);
      }
      throw StateError('no start-of-frame marker');
    }

    // These three tests pin down a fact about the app, found while testing the
    // harness: the image library's decoder applies EXIF rotation itself and
    // clears the tag, so the app's "bake rotation" step never runs and the
    // ORIGINAL bytes (unrotated pixels + tag) are what gets sent.
    test('FACT: the image library decoder already applies EXIF rotation and clears the tag', () {
      final bytes = jpegWithExifOrientation(6);
      expect(storedSize(bytes), (64, 32), reason: 'the file stores landscape pixels');
      final decoded = img.decodeJpg(bytes)!;
      expect((decoded.width, decoded.height), (32, 64), reason: 'the decoder rotated it');
      expect(decoded.exif.imageIfd.hasOrientation, isFalse, reason: 'and cleared the tag, so a later check for it finds nothing');
    });

    test('like the app, the original bytes are sent: unrotated pixels with the rotation tag still in the file', () {
      final bytes = jpegWithExifOrientation(6);
      final p = prepareImage(bytes, jpegQuality: 85);
      expect(p.info.rotated, isFalse, reason: 'the app-equivalent "needs baking" check is false');
      expect(p.jpeg, bytes, reason: 'so nothing is re-encoded');
      expect(storedSize(p.jpeg), (64, 32));
      expect(p.info.exifOrientation, 6);
      expect(p.info.sentWithRotationTag, isTrue);
      expect((p.info.width, p.info.height), (32, 64), reason: 'measurements use the upright size');
    });

    test('forceUpright re-encodes so the stored pixels are upright and no rotation tag remains', () {
      final p = prepareImage(jpegWithExifOrientation(6), jpegQuality: 85, forceUpright: true);
      expect(p.info.reencoded, isTrue);
      expect(storedSize(p.jpeg), (32, 64));
      expect(img.decodeJpgExif(p.jpeg)?.imageIfd.hasOrientation ?? false, isFalse);
      expect(p.info.sentWithRotationTag, isFalse);
    });

    test('an upright file (orientation 1) is sent untouched either way it is described', () {
      final bytes = jpegWithExifOrientation(1);
      final p = prepareImage(bytes, jpegQuality: 85);
      expect(p.jpeg, bytes);
      expect((p.info.width, p.info.height), (64, 32));
      expect(p.info.sentWithRotationTag, isFalse);
    });

    test('a file with no EXIF at all has no rotation tag', () {
      final p = prepareImage(solidJpeg(120, 120, 120), jpegQuality: 85);
      expect(p.info.exifOrientation, isNull);
      expect(p.info.sentWithRotationTag, isFalse);
    });

    test('a PNG is converted to JPEG', () {
      final im = img.Image(width: 40, height: 40);
      img.fill(im, color: img.ColorRgb8(90, 90, 90));
      final p = prepareImage(Uint8List.fromList(img.encodePng(im)), jpegQuality: 85);
      expect(p.info.reencoded, isTrue);
      expect(p.jpeg[0], 0xFF);
      expect(p.jpeg[1], 0xD8);
    });

    test('resize shrinks the longest side only when needed', () {
      final big = prepareImage(solidJpeg(100, 100, 100, w: 400, h: 200), jpegQuality: 85, resizeLongSide: 100);
      expect((big.info.width, big.info.height), (100, 50));
      final small = prepareImage(solidJpeg(100, 100, 100, w: 60, h: 40), jpegQuality: 85, resizeLongSide: 100);
      expect(small.info.reencoded, isFalse);
    });

    test('an undecodable file is an error, not a crash', () {
      expect(() => prepareImage(Uint8List.fromList([1, 2, 3, 4]), jpegQuality: 85), throwsFormatException);
    });
  });

  group('parsing a response', () {
    test('stairs: class renamed to the policy tag, box converted to corners', () {
      final r = parseResponse(stairsSpec, body([pred('downstair', 0.9)]));
      expect(r.detections, hasLength(1));
      final d = r.detections.first;
      expect(d['tag'], 'stairs_down');
      expect(d['label'], 'stairs down');
      final box = (d['box'] as List).cast<double>();
      expect(box[0], closeTo((320 - 100) / 640, 1e-9));
      expect(box[3], closeTo(1.0, 1e-9));
      expect(box[4], 0.9);
    });

    test('street: classes outside the allow-list are dropped but remembered with a reason', () {
      final r = parseResponse(streetSpec, body([pred('chair', 0.8), pred('car', 0.7)]));
      expect(r.detections.map((d) => d['tag']), ['vehicle']);
      expect(r.preds.where((p) => p.dropped != null).single.rawClass, 'chair');
    });

    test('indoor: ignored classes are listed, others renamed', () {
      final r = parseResponse(obstacleSpec, body([pred('Mug', 0.9), pred('Chair', 0.8)]));
      expect(r.ignored, ['Mug']);
      expect(r.detections.single['tag'], 'obstacle_low');
      expect(r.detections.single['label'], 'chair');
    });

    test('a response that is not an object is an error', () {
      expect(() => parseResponse(stairsSpec, [1, 2]), throwsFormatException);
    });
  });

  group('replay through the real pipeline and policy', () {
    test('a confident stairs-down that fills the frame bottom is critical, spoken once with the designed words', () {
      final r = replay(parseResponse(stairsSpec, body([pred('downstair', 0.9)])).detections, settings.distanceModel);
      final first = r.alerts.first;
      expect(first.frame, 1, reason: 'fast path: severity 3 at >=85% skips the 2-frame wait');
      expect(first.tier, AlertTier.critical);
      expect(first.speech, 'Stop. Stairs down.');
      expect(first.spoken, isTrue);
    });

    test('a low-confidence stairs-down needs the second frame', () {
      final r = replay(parseResponse(stairsSpec, body([pred('downstair', 0.6)])).detections, settings.distanceModel);
      expect(r.alerts.first.frame, 2);
    });

    test('no detections means no alerts', () {
      expect(replay(const [], settings.distanceModel).alerts, isEmpty);
    });
  });

  group('explaining a drop agrees with the real pipeline', () {
    ParsedPrediction p(String cls, double bottom, {double x = 320, double conf = 0.9, ModelSpec spec = streetSpec}) =>
        parseResponse(spec, body([predBottom(cls, conf, bottom, x: x)])).preds.single;

    test('beyond range', () {
      final pr = p('car', 0.6);
      expect(explainPrediction(pr, settings.distanceModel, const PipelineConfig()).reason, DropReason.outOfRange);
      expect(replay(parseResponse(streetSpec, body([predBottom('car', 0.9, 0.6)])).detections, settings.distanceModel).rawCount, 0);
    });

    test('a person far away is silent by design but still counted', () {
      final pr = p('person', 0.82);
      expect(explainPrediction(pr, settings.distanceModel, const PipelineConfig()).reason, DropReason.infoTier);
      final r = replay(parseResponse(streetSpec, body([predBottom('person', 0.9, 0.82)])).detections, settings.distanceModel);
      expect(r.rawCount, 1);
      expect(r.alerts, isEmpty);
    });

    test('off the walking path', () {
      final pr = p('bench', 0.95, x: 60);
      expect(explainPrediction(pr, settings.distanceModel, const PipelineConfig()).reason, DropReason.offPath);
    });

    test('low confidence', () {
      final pr = p('car', 0.95, conf: 0.2);
      expect(explainPrediction(pr, settings.distanceModel, const PipelineConfig()).reason, DropReason.lowConfidence);
    });
  });

  group('scanning the photo folder', () {
    test('folder names are normalised; unknown, stray and empty cases are reported', () {
      addImage('Stairs-Down', 'a.jpg', uniqueJpeg(20));
      addImage('mystery', 'a.jpg', uniqueJpeg(21));
      Directory('${imagesDir().path}/person').createSync(recursive: true);
      File('${imagesDir().path}/stray.jpg').writeAsBytesSync(uniqueJpeg(22));
      File('${imagesDir().path}/stairs_up_notes.txt').writeAsStringSync('hi');

      final scan = scanImages(imagesDir(), ModesOption.auto);
      expect(scan.entries.map((e) => e.rel), ['stairs_down/a.jpg']);
      expect(scan.unknownDirs, ['mystery']);
      expect(scan.strayFiles, ['stray.jpg']);
      expect(scan.emptyLabelDirs, ['person']);
    });

    test('a missing folder is an empty scan, not an error', () {
      expect(scanImages(Directory('${tmp.path}/nope'), ModesOption.auto).entries, isEmpty);
    });

    test('auto mode picks the modes that can find a label; both forces two', () {
      expect(modesFor(kLabels['car']!, ModesOption.auto), [DetectMode.street]);
      expect(modesFor(kLabels['chair']!, ModesOption.auto), [DetectMode.indoor]);
      expect(modesFor(kLabels['clear']!, ModesOption.auto), [DetectMode.street, DetectMode.indoor]);
      expect(modesFor(kLabels['car']!, ModesOption.both), hasLength(2));
    });

    test('call estimate for the recommended 30 per core label', () {
      final counts = {for (final l in kCoreLabels) l: 30};
      // stairs_down/stairs_up/clear: 4 models; car/person/pothole: 3; chair: 2.
      expect(estimateCalls(counts, ModesOption.auto), 30 * 4 * 3 + 30 * 3 * 3 + 30 * 2);
    });
  });

  group('end to end with a fake API', () {
    late FakeApi api;
    late String hStairsDown, hStairsUp, hClearB, hPerson, hChair, hFail;

    void buildDataset() {
      api = FakeApi();
      hStairsDown = addImage('stairs_down', 'a.jpg', uniqueJpeg(1));
      hStairsUp = addImage('stairs_up', 'a.jpg', uniqueJpeg(2));
      addImage('clear', 'a.jpg', uniqueJpeg(3)); // no script: models see nothing
      hClearB = addImage('clear', 'b.jpg', uniqueJpeg(4));
      hPerson = addImage('person', 'a.jpg', uniqueJpeg(5));
      hChair = addImage('chair', 'a.jpg', uniqueJpeg(6));
      addImage('pothole', 'a.jpg', uniqueJpeg(7)); // no script: a miss
      addImage('car', 'dark.jpg', solidJpeg(5, 5, 5)); // dark: no calls at all
      hFail = addImage('car', 'fail.jpg', uniqueJpeg(8));

      // stairs_down photo: the stairs model finds it, filling the frame bottom.
      script(api, stairsSpec.id, hStairsDown, body([pred('downstair', 0.9)]));
      // stairs_up photo: the stairs model says DOWN instead (a wrong-class case).
      script(api, stairsSpec.id, hStairsUp, body([pred('downstair', 0.9)]));
      // clear photo B: the street model sees a car right ahead (a false alarm in street mode).
      script(api, streetSpec.id, hClearB, body([pred('car', 0.9)]));
      // person photo: found, but far away, so silent by design.
      script(api, streetSpec.id, hPerson, body([predBottom('person', 0.9, 0.82)]));
      // chair photo: found, but estimated far beyond range.
      script(api, obstacleSpec.id, hChair, body([predBottom('Chair', 0.9, 0.6)]));
      // pothole photo: nothing returned by any model (a miss).
      // fail photo: every call throws.
      for (final s in [stairsSpec, streetSpec, potholeSpec]) {
        script(api, s.id, hFail, Exception('network down'));
      }
    }

    Future<(Plan, RunOutput, EvalClient)> runOnce({String key = 'SECRETKEY123', ModesOption modes = ModesOption.auto}) async {
      final cache = newCache();
      final scan = scanImages(imagesDir(), modes);
      final plan = buildPlan(scan: scan, settings: settings, cache: cache, resize: 0);
      final client = EvalClient(cache: cache, apiKey: key, post: api.post);
      final out = await runEval(plan: plan, settings: settings, client: client, resize: 0);
      return (plan, out, client);
    }

    EvalRow rowOf(RunOutput o, String image, DetectMode m) => o.rows.firstWhere((r) => r.image == image && r.mode == m);

    test('planning counts calls and makes none', () {
      buildDataset();
      final plan = buildPlan(scan: scanImages(imagesDir(), ModesOption.auto), settings: settings, cache: newCache(), resize: 0);
      // stairs_down, stairs_up, clear a, clear b: 4 models each = 16
      // person, pothole, car/fail: 3 each = 9;  chair: 2;  car/dark: skipped (no calls)
      expect(plan.callsNeeded, 27);
      expect(plan.callsCached, 0);
      expect(plan.callsToMake, 27);
      expect(plan.dark, 1);
      expect(plan.toMakeByModel[stairsSpec.id], 8, reason: 'every photo except the dark one calls the stairs model');
      expect(api.calls, 0, reason: 'planning must never call the API');
      expect(describePlan(plan, ModesOption.auto), contains('NEW live calls:         27'));
    });

    test('every scenario is scored the way the rules say', () async {
      buildDataset();
      final (_, out, client) = await runOnce();

      for (final m in DetectMode.values) {
        final ok = rowOf(out, 'stairs_down/a.jpg', m);
        expect(ok.outcome, Outcome.alertedCorrect, reason: m.name);
        expect(ok.spokenText, 'Stop. Stairs down. (x3)', reason: 'critical is re-spoken every frame');

        final wrong = rowOf(out, 'stairs_up/a.jpg', m);
        expect(wrong.outcome, Outcome.wrongClass, reason: m.name);
        expect(wrong.why, contains('Stop. Stairs down.'));
        expect(wrong.spokenText, contains('(x3)'));
      }

      expect(rowOf(out, 'clear/a.jpg', DetectMode.street).outcome, Outcome.clearOk);
      expect(rowOf(out, 'clear/b.jpg', DetectMode.street).outcome, Outcome.falseAlarm);
      expect(rowOf(out, 'clear/b.jpg', DetectMode.street).spokenText, contains('Car'));
      expect(rowOf(out, 'clear/b.jpg', DetectMode.indoor).outcome, Outcome.clearOk, reason: 'indoor mode has no car model');

      final person = rowOf(out, 'person/a.jpg', DetectMode.street);
      expect(person.outcome, Outcome.silentByDesign);
      expect(person.spokenText, '(silent)');

      final chair = rowOf(out, 'chair/a.jpg', DetectMode.indoor);
      expect(chair.outcome, Outcome.filtered);
      expect(chair.why, contains('beyond'));

      expect(rowOf(out, 'pothole/a.jpg', DetectMode.street).outcome, Outcome.notSeen);

      final dark = rowOf(out, 'car/dark.jpg', DetectMode.street);
      expect(dark.outcome, Outcome.failsafeDark);

      final failed = rowOf(out, 'car/fail.jpg', DetectMode.street);
      expect(failed.outcome, Outcome.error);
      expect(failed.why, contains('network down'));

      expect(client.liveCalls, 27);
      expect(client.liveFailures, 3);
      expect(client.cacheHits, 0);
    });

    test('the cache makes a rerun free, but failed calls are retried', () async {
      buildDataset();
      await runOnce();
      final callsAfterFirst = api.calls;
      final (plan2, out2, client2) = await runOnce();
      expect(plan2.callsCached, 24, reason: 'the 24 successful responses were cached');
      expect(plan2.callsToMake, 3, reason: 'the 3 failures were not');
      expect(api.calls - callsAfterFirst, 3);
      expect(client2.cacheHits, 24);
      expect(rowOf(out2, 'stairs_down/a.jpg', DetectMode.street).outcome, Outcome.alertedCorrect);
      expect(rowOf(out2, 'car/fail.jpg', DetectMode.street).outcome, Outcome.error);
    });

    test('the live-call log counts every live call ever made, failures included', () async {
      buildDataset();
      await runOnce();
      expect(newCache().liveCallsEver(), 27);
      await runOnce();
      expect(newCache().liveCallsEver(), 30);
    });

    test('statistics match the rows', () async {
      buildDataset();
      final (_, out, _) = await runOnce();
      final g = groupStats(out.rows);
      expect(g['stairs_down/street']!.correct, 1);
      expect(g['stairs_up/street']!.wrong, 1);
      expect(g['clear/street']!.falseAlarm, 1);
      expect(g['clear/street']!.clearOk, 1);
      expect(g['car/street']!.dark, 1);
      expect(g['car/street']!.errors, 1);
      expect(g['car/street']!.tested, 1);

      final lat = latencyStats(out.calls);
      expect(lat.first.model, 'ALL MODELS');
      expect(lat.first.n, 24);
      expect(lat.first.failed, 3);
      expect(lat.first.max, greaterThan(100));
    });

    test('the report has every section and ranks the false alarm first', () async {
      buildDataset();
      final (_, out, client) = await runOnce();
      final report = buildReport(ReportInput(
        generated: DateTime(2026, 1, 1), command: 'test', rows: out.rows, calls: out.calls, settings: settings,
        modes: ModesOption.auto, resize: 0, scan: scanImages(imagesDir(), ModesOption.auto), client: client,
        minPerLabel: kMinPerLabel,
      ));
      for (final h in [
        '## 1. What was run', '## 2. Results by label', '## 3. Clear photos', '## 4. Wrong-class confusions',
        '## 5. Latency', '## 6. The 10 worst failures', '## 7. What would be spoken', '## 8. API calls and credits',
        '## 9. Plain-language diagnosis', '## 10. What this did NOT test',
      ]) {
        expect(report, contains(h));
      }
      final worst = report.split('## 6. The 10 worst failures')[1].split('## 7.')[0];
      final firstRow = worst.split('\n').firstWhere((l) => RegExp(r'^\| 1 \|').hasMatch(l));
      expect(firstRow, contains('clear/b.jpg'));
      expect(report, contains('Stop. Stairs down.'));
      expect(report, contains('Too few photos to judge recall'), reason: 'every group here has far fewer than 30 photos');
      expect(report, contains('Too few clear photos to judge the false-alarm rate'));
      expect(report, contains('- Command: `test`'));
      // the one false alarm fires on all 3 replayed frames but is listed once, with a count
      expect(RegExp(r'\| clear/b\.jpg \| street \| critical \| Stop\. Car ahead\. \(x3 frames\)').hasMatch(report), isTrue);
      expect(report, contains('x-remote-processing-time'));
      expect(report, contains('Credits used are not measured'));
      expect(report, isNot(contains('SECRETKEY123')));
      expect(buildCsv(out.rows), isNot(contains('SECRETKEY123')));
      expect(buildCsv(out.rows).split('\n').length, out.rows.length + 1);
    });

    test('an error message never contains the API key', () async {
      buildDataset();
      api.scripted['${stairsSpec.id}|$hFail'] = Exception('could not reach https://x with SECRETKEY123');
      final (_, out, client) = await runOnce();
      expect(client.lastError, isNot(contains('SECRETKEY123')));
      expect(rowOf(out, 'car/fail.jpg', DetectMode.street).why, isNot(contains('SECRETKEY123')));
    });

    test('a run stops after repeated failures instead of burning calls', () async {
      api = FakeApi();
      final h1 = addImage('car', 'a.jpg', uniqueJpeg(10));
      addImage('car', 'b.jpg', uniqueJpeg(11));
      addImage('car', 'c.jpg', uniqueJpeg(12));
      for (final s in [stairsSpec, streetSpec, potholeSpec]) {
        script(api, s.id, h1, 401);
      }
      final cache = newCache();
      final plan = buildPlan(scan: scanImages(imagesDir(), ModesOption.auto), settings: settings, cache: cache, resize: 0);
      final client = EvalClient(cache: cache, apiKey: 'k', post: api.post);
      final out = await runEval(plan: plan, settings: settings, client: client, resize: 0, abortAfterFailures: 3);
      expect(out.abortReason, isNotNull);
      expect(out.abortReason, contains('HTTP 401'));
      expect(out.rows, hasLength(1), reason: 'only the first photo was processed');
      expect(api.calls, 3);
    });

    test('forcing both modes also runs a car photo through indoor mode, where it cannot be found', () async {
      api = FakeApi();
      final h = addImage('car', 'a.jpg', uniqueJpeg(13));
      script(api, streetSpec.id, h, body([pred('car', 0.9)]));
      final (plan, out, _) = await runOnce(modes: ModesOption.both);
      expect(plan.callsNeeded, 4);
      expect(rowOf(out, 'car/a.jpg', DetectMode.street).outcome, Outcome.alertedCorrect);
      expect(rowOf(out, 'car/a.jpg', DetectMode.indoor).outcome, Outcome.notSeen);

      final report = buildReport(ReportInput(
        generated: DateTime(2026, 1, 1), command: 'test', rows: out.rows, calls: out.calls, settings: settings,
        modes: ModesOption.both, resize: 0, scan: scanImages(imagesDir(), ModesOption.both),
        client: EvalClient(cache: newCache(), apiKey: 'k'), minPerLabel: kMinPerLabel,
      ));
      final table = report.split('## 2. Results by label')[1].split('## 3.')[0];
      expect(table, contains('car/street'));
      expect(table, isNot(contains('car/indoor')), reason: 'recall is only computed where the app is expected to find it');
    });

    test('right hazard type but a different spoken name is flagged', () async {
      api = FakeApi();
      final h = addImage('car', 'a.jpg', uniqueJpeg(14));
      script(api, streetSpec.id, h, body([pred('truck', 0.9)]));
      final (_, out, _) = await runOnce();
      final r = rowOf(out, 'car/a.jpg', DetectMode.street);
      expect(r.outcome, Outcome.alertedCorrect);
      expect(r.nameMismatch, isTrue);
      expect(r.why, contains('truck'));
    });

    test('a class the street filter drops is reported as such, not as "not seen"', () async {
      api = FakeApi();
      final h = addImage('bench', 'a.jpg', uniqueJpeg(15));
      script(api, streetSpec.id, h, body([pred('chair', 0.9)]));
      final (_, out, _) = await runOnce();
      // bench is expected in street mode via the allow-list; "chair" is not on it.
      expect(rowOf(out, 'bench/a.jpg', DetectMode.street).outcome, Outcome.notSeen);

      // For a label whose own name is dropped by the filter, the reason says so.
      final hd = addImage('desk', 'a.jpg', uniqueJpeg(16));
      script(api, obstacleSpec.id, hd, body([pred('Desk', 0.9)]));
      final (_, out2, _) = await runOnce(modes: ModesOption.indoor);
      expect(rowOf(out2, 'desk/a.jpg', DetectMode.indoor).outcome, isNot(Outcome.notSeen));
    });
  });

  group('diagnosis rules, at a sample size big enough to judge (40 photos per group)', () {
    // Rows are built directly: these tests check the RULES, not the models.
    EvalRow hazardRow(int i, Outcome o, {bool saw = false, String label = 'stairs_down'}) => EvalRow(
          image: '$label/$i.jpg', label: label, mode: DetectMode.street, outcome: o, modelSaw: saw,
        );

    AlertEvent alert(String name, String tag, double conf) => AlertEvent(
          frame: 2, tier: AlertTier.critical, tag: tag, name: name, zone: 'center', proximity: 'veryNear',
          distFeet: 5, clipped: true, conf: conf, yMax: 1.0, speech: 'Stop. $name ahead.', spoken: true,
          withheldReason: null, haptic: 'x',
        );

    EvalRow clearRow(int i, {List<AlertEvent> alerts = const []}) => EvalRow(
          image: 'clear/$i.jpg', label: 'clear', mode: DetectMode.street,
          outcome: alerts.isEmpty ? Outcome.clearOk : Outcome.falseAlarm, alerts: alerts,
        );

    List<String> diagnose(List<EvalRow> rows, {List<LatencyStats> lat = const []}) {
      final images = {for (final r in rows) r.image}.length;
      return buildDiagnosis(groupStats(rows), rows, lat, kMinPerLabel, images);
    }

    String line(List<String> d, String start) => d.firstWhere((l) => l.startsWith(start), orElse: () => '(no line)');

    test('low recall where the model saw nothing: a DATA problem', () {
      final rows = [
        for (var i = 0; i < 10; i++) hazardRow(i, Outcome.alertedCorrect, saw: true),
        for (var i = 10; i < 40; i++) hazardRow(i, Outcome.notSeen),
      ];
      final l = line(diagnose(rows), 'stairs_down/street');
      expect(l, contains('recall 25%'));
      expect(l, contains('30 not seen by the model'));
      expect(l, contains('looks like a data problem'));
      expect(l, contains('Suggestion'));
    });

    test('low recall where the model DID see it but the pipeline dropped it: NOT a data problem', () {
      final rows = [
        for (var i = 0; i < 10; i++) hazardRow(i, Outcome.alertedCorrect, saw: true),
        for (var i = 10; i < 40; i++) hazardRow(i, Outcome.filtered, saw: true),
      ];
      final l = line(diagnose(rows), 'stairs_down/street');
      expect(l, contains('30 seen but dropped by the pipeline'));
      expect(l, contains('range, path or threshold problem'));
      expect(l, isNot(contains('looks like a data problem')));
    });

    test('low recall from mislabelling (wrong class) is a data problem too', () {
      final rows = [
        for (var i = 0; i < 8; i++) hazardRow(i, Outcome.alertedCorrect, saw: true),
        for (var i = 8; i < 40; i++) hazardRow(i, Outcome.wrongClass),
      ];
      expect(line(diagnose(rows), 'stairs_down/street'), contains('looks like a data problem'));
    });

    test('recall at or above the cut-off is reported as no problem, not as success', () {
      final rows = [
        for (var i = 0; i < 36; i++) hazardRow(i, Outcome.alertedCorrect, saw: true),
        for (var i = 36; i < 40; i++) hazardRow(i, Outcome.notSeen),
      ];
      final l = line(diagnose(rows), 'stairs_down/street');
      expect(l, contains('recall 90%'));
      expect(l, contains('no recall problem seen in this sample'));
      expect(l, isNot(contains('Suggestion')));
    });

    test('the boundary: exactly 70% recall is not low', () {
      final rows = [
        for (var i = 0; i < 28; i++) hazardRow(i, Outcome.alertedCorrect, saw: true),
        for (var i = 28; i < 40; i++) hazardRow(i, Outcome.notSeen),
      ];
      expect(line(diagnose(rows), 'stairs_down/street'), contains('no recall problem'));
    });

    test('a group under 30 photos is "too few to judge" even if recall looks terrible', () {
      final rows = [for (var i = 0; i < 29; i++) hazardRow(i, Outcome.notSeen)];
      final d = diagnose(rows);
      expect(line(d, 'Too few photos to judge recall'), contains('stairs_down/street (29)'));
      expect(d.any((l) => l.contains('data problem')), isFalse);
    });

    test('many false alarms on clear photos: a THRESHOLD / CLASS-FILTER problem, naming the cause', () {
      final rows = [
        for (var i = 0; i < 12; i++) clearRow(i, alerts: [alert('bench', 'obstacle_low', 0.45 + i * 0.01)]),
        for (var i = 12; i < 40; i++) clearRow(i),
      ];
      final l = line(diagnose(rows), 'clear/street');
      expect(l, contains('false-alarm rate 30%'));
      expect(l, contains('bench [obstacle_low] x12'));
      expect(l, contains('45-56%'));
      expect(l, contains('threshold or class-filter problem'));
    });

    test('few false alarms is not flagged', () {
      final rows = [
        for (var i = 0; i < 2; i++) clearRow(i, alerts: [alert('car', 'vehicle', 0.9)]),
        for (var i = 2; i < 40; i++) clearRow(i),
      ];
      final l = line(diagnose(rows), 'clear/street');
      expect(l, contains('not high in this sample'));
      expect(l, isNot(contains('Suggestion')));
    });

    test('slow calls point to a SPEED problem and an on-device model', () {
      final slow = LatencyStats('ALL MODELS', [for (var i = 0; i < 100; i++) i < 85 ? 400 : 1800], 0);
      final d = diagnose([for (var i = 0; i < 40; i++) hazardRow(i, Outcome.alertedCorrect, saw: true)], lat: [slow]);
      final l = line(d, 'Latency');
      expect(l, contains('speed problem'));
      expect(l, contains('on-device model'));
      expect(l, contains('not the phone'));
    });

    test('a share of calls over the app timeout also counts as slow, even with a fine 90th percentile', () {
      final v = [for (var i = 0; i < 100; i++) i < 93 ? 300 : 3500]; // p90 = 300, but 7% are over 3 s
      final d = diagnose([for (var i = 0; i < 40; i++) hazardRow(i, Outcome.alertedCorrect, saw: true)],
          lat: [LatencyStats('ALL MODELS', v, 0)]);
      expect(line(d, 'Latency'), contains('speed problem'));
    });

    test('fast calls are reported as not the main issue, with the phone caveat', () {
      final d = diagnose([for (var i = 0; i < 40; i++) hazardRow(i, Outcome.alertedCorrect, saw: true)],
          lat: [LatencyStats('ALL MODELS', [for (var i = 0; i < 100; i++) 300 + i], 0)]);
      final l = line(d, 'Latency');
      expect(l, contains('not the main issue'));
      expect(l, contains('Phone latency'));
    });

    test('no calls were made: latency is said to be unmeasured, not assumed fine', () {
      final d = diagnose([for (var i = 0; i < 40; i++) hazardRow(i, Outcome.alertedCorrect, saw: true)]);
      expect(line(d, 'Latency'), contains('not measured'));
    });

    test('fewer than 30 photos in total gets an overall small-sample warning', () {
      final d = diagnose([for (var i = 0; i < 5; i++) hazardRow(i, Outcome.alertedCorrect, saw: true)]);
      expect(d.first, contains('too small a sample'));
    });
  });

  group('CSV and markdown escaping', () {
    test('commas, quotes and newlines are escaped so a spoken sentence cannot break a row', () {
      expect(csvEscape('Pothole ahead, 8 feet.'), '"Pothole ahead, 8 feet."');
      expect(csvEscape('said "Stop"'), '"said ""Stop"""');
      expect(csvEscape('a\nb'), '"a\nb"');
      expect(csvEscape(null), '');
      expect(csvEscape(3), '3');
    });
  });

  group('diagnosis wording', () {
    test('no photos', () {
      expect(buildDiagnosis(const {}, const [], const [], kMinPerLabel, 0).single, contains('nothing to diagnose'));
    });

    test('the no-data report says plainly that nothing was run', () {
      final r = buildNoDataReport(minPerLabel: 30);
      expect(r, contains('NO RESULTS'));
      expect(r, contains('at least 30 photos per folder'));
      expect(r, contains('no API calls were made'));
    });
  });
}
