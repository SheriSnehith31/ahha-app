// Self-test harness core: runs labelled photos through the same models,
// request format, class filters, detection pipeline and alert policy the app
// uses, and measures what comes out.
//
// REUSED directly (imported, not copied):
//   lib/detection_logic.dart  DetectionPipeline, DistanceModel, tiering, ...
//   lib/alert_policy.dart     AlertPolicy (the exact words that would be spoken)
//
// PORTED (copied from lib/main.dart, because main.dart needs Flutter and
// cannot be imported by a plain Dart script). [specDrift] and [readAppSettings]
// compare against main.dart at run time and warn if the app has moved on:
//   - hosted model ids and class rename / allow-list / ignore-list tables
//   - request format (POST, base64 body, Bearer header, no confidence param)
//   - frame preparation (EXIF rotation baked in, brightness check, JPEG q85)
//   - the glue that turns a response into pipeline input
//
// NOT reproduced: speech playback state (the app skips speech while it is
// already talking; here the voice is always idle), haptic playback, camera.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ahha_app/alert_policy.dart';
import 'package:ahha_app/detection_logic.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

const String kBaseUrl = 'https://serverless.roboflow.com';

// Thresholds used ONLY for the plain-language suggestions at the end of the
// report. They are this harness's own choices, not measurements, and are
// printed in the report so they can be argued with.
const int kMinPerLabel = 30;
const double kLowRecall = 0.70;
const double kHighFalseAlarm = 0.10;
const int kSlowP90Ms = 1000;
const int kAppTimeoutMs = 3000;
const double kTimeoutShare = 0.05;

// ---------------------------------------------------------------------------
// Modes and models (PORTED from lib/main.dart)
// ---------------------------------------------------------------------------

enum DetectMode { street, indoor }

enum ModesOption { auto, street, indoor, both }

class ModelSpec {
  const ModelSpec({
    required this.id,
    required this.label,
    this.tagRename = const {},
    this.only,
    this.ignore = const {},
  });

  final String id;
  final String label;
  final Map<String, String> tagRename;
  final Set<String>? only;
  final Set<String> ignore;
}

const stairsSpec = ModelSpec(
  id: 'stairs_detection-jaj7e/2',
  label: 'stairs',
  tagRename: {'downstair': 'stairs_down', 'upstair': 'stairs_up'},
);

const obstacleSpec = ModelSpec(
  id: 'obstacle-detection-meg7r/19',
  label: 'obstacle',
  tagRename: {'Chair': 'obstacle_low', 'Desk': 'obstacle_low', 'Door': 'obstacle_low'},
  ignore: {'Bottle', 'Mug', 'Books', 'Laptop', 'Shoes'},
);

const streetSpec = ModelSpec(
  id: 'coco/50',
  label: 'street',
  only: {'person', 'bicycle', 'motorcycle', 'car', 'bus', 'truck', 'dog', 'bench', 'fire hydrant'},
  tagRename: {
    'person': 'person',
    'bicycle': 'two_wheeler',
    'motorcycle': 'vehicle',
    'car': 'vehicle',
    'bus': 'vehicle',
    'truck': 'vehicle',
    'dog': 'dog',
    'bench': 'obstacle_low',
    'fire hydrant': 'obstacle_low',
  },
);

const potholeSpec = ModelSpec(
  id: 'pothole-detection-mev9q/6',
  label: 'pothole',
  tagRename: {'pothole': 'pothole'},
);

const List<ModelSpec> allSpecs = [stairsSpec, streetSpec, potholeSpec, obstacleSpec];

List<ModelSpec> specsFor(DetectMode m) =>
    m == DetectMode.street ? [stairsSpec, streetSpec, potholeSpec] : [stairsSpec, obstacleSpec];

// ---------------------------------------------------------------------------
// Ground-truth labels
// ---------------------------------------------------------------------------

class LabelSpec {
  const LabelSpec(this.tags, this.names, this.modes);

  /// Policy tags that count as a correct alert. Empty = a "clear" photo.
  final Set<String> tags;

  /// Class names as spoken ("car"), to notice a right-type-wrong-name alert.
  final Set<String> names;

  /// Modes in which the app could be expected to find this.
  final Set<DetectMode> modes;

  bool get isClear => tags.isEmpty;
}

const _both = {DetectMode.street, DetectMode.indoor};
const _street = {DetectMode.street};
const _indoor = {DetectMode.indoor};

const Map<String, LabelSpec> kLabels = {
  'stairs_down': LabelSpec({'stairs_down'}, {'stairs down'}, _both),
  'stairs_up': LabelSpec({'stairs_up'}, {'stairs up'}, _both),
  'clear': LabelSpec({}, {}, _both),
  'car': LabelSpec({'vehicle'}, {'car'}, _street),
  'bus': LabelSpec({'vehicle'}, {'bus'}, _street),
  'truck': LabelSpec({'vehicle'}, {'truck'}, _street),
  'motorcycle': LabelSpec({'vehicle'}, {'motorcycle'}, _street),
  'bicycle': LabelSpec({'two_wheeler'}, {'bicycle'}, _street),
  'person': LabelSpec({'person'}, {'person'}, _street),
  'dog': LabelSpec({'dog'}, {'dog'}, _street),
  'pothole': LabelSpec({'pothole'}, {'pothole'}, _street),
  'bench': LabelSpec({'obstacle_low'}, {'bench'}, _street),
  'fire_hydrant': LabelSpec({'obstacle_low'}, {'fire hydrant'}, _street),
  'chair': LabelSpec({'obstacle_low'}, {'chair'}, _indoor),
  'desk': LabelSpec({'obstacle_low'}, {'desk'}, _indoor),
  'door': LabelSpec({'obstacle_low'}, {'door'}, _indoor),
};

/// The folders the harness creates with --init and recommends filling first.
const List<String> kCoreLabels = ['stairs_down', 'stairs_up', 'clear', 'car', 'person', 'pothole', 'chair'];

String normalizeLabel(String dirName) => dirName.trim().toLowerCase().replaceAll(RegExp(r'[\s\-]+'), '_');

List<DetectMode> modesFor(LabelSpec s, ModesOption o) {
  switch (o) {
    case ModesOption.auto:
      return [for (final m in DetectMode.values) if (s.modes.contains(m)) m];
    case ModesOption.both:
      return DetectMode.values;
    case ModesOption.street:
      return const [DetectMode.street];
    case ModesOption.indoor:
      return const [DetectMode.indoor];
  }
}

Set<ModelSpec> modelsFor(List<DetectMode> modes) => {for (final m in modes) ...specsFor(m)};

// ---------------------------------------------------------------------------
// Reading the app's own settings (so they cannot silently drift)
// ---------------------------------------------------------------------------

class AppSettings {
  const AppSettings({
    required this.distanceModel,
    required this.darkness,
    required this.timeoutSeconds,
    required this.jpegQuality,
    this.notes = const [],
  });

  final DistanceModel distanceModel;
  final double darkness;
  final int timeoutSeconds;
  final int jpegQuality;

  /// Anything that could not be read from main.dart, or looks different from
  /// what this harness assumes.
  final List<String> notes;
}

/// Values at the time this harness was written, used only if main.dart
/// cannot be read.
const _fallbackDistance = DistanceModel(cameraHeightM: 1.3, pitchDeg: 5.5, fovVDeg: 63.0, yHorizon: 0.5);

AppSettings readAppSettings(String? mainSource) {
  if (mainSource == null) {
    return const AppSettings(
      distanceModel: _fallbackDistance,
      darkness: 40.0,
      timeoutSeconds: 3,
      jpegQuality: 85,
      notes: ['lib/main.dart could not be read; using the values it had when this harness was written'],
    );
  }
  final notes = <String>[];
  double? number(RegExp re) {
    final m = re.firstMatch(mainSource);
    return m == null ? null : double.tryParse(m.group(1)!);
  }

  final dm = RegExp(
    r'DistanceModel\(\s*cameraHeightM:\s*([0-9.]+)\s*,\s*pitchDeg:\s*([0-9.]+)\s*,\s*fovVDeg:\s*([0-9.]+)\s*,\s*yHorizon:\s*([0-9.]+)\s*,?\s*\)',
  ).firstMatch(mainSource);
  DistanceModel distance = _fallbackDistance;
  if (dm == null) {
    notes.add('could not read the DistanceModel constants from main.dart; used the harness defaults');
  } else {
    distance = DistanceModel(
      cameraHeightM: double.parse(dm.group(1)!),
      pitchDeg: double.parse(dm.group(2)!),
      fovVDeg: double.parse(dm.group(3)!),
      yHorizon: double.parse(dm.group(4)!),
    );
  }

  final dark = number(RegExp(r'_darknessThreshold\s*=\s*([0-9.]+)'));
  if (dark == null) notes.add('could not read _darknessThreshold from main.dart; used 40');
  final timeout = number(RegExp(r'\.timeout\(\s*const Duration\(\s*seconds:\s*(\d+)\s*\)\s*\)'));
  if (timeout == null) notes.add('could not read the request timeout from main.dart; used 3 s');
  final quality = number(RegExp(r'encodeJpg\(\s*upright\s*,\s*quality:\s*(\d+)\s*\)'));
  if (quality == null) notes.add('could not read the JPEG quality from main.dart; used 85');

  if (!RegExp(r'DetectionPipeline\(\s*distanceModel:\s*_distanceModel\s*\)').hasMatch(mainSource)) {
    notes.add('main.dart builds the DetectionPipeline differently than the harness assumes (default config)');
  }
  if (!RegExp(r'AlertPolicy\(\s*\)').hasMatch(mainSource)) {
    notes.add('main.dart builds the AlertPolicy differently than the harness assumes (default budgets)');
  }
  if (!mainSource.contains('"Content-Type": "application/x-www-form-urlencoded"') ||
      !mainSource.contains('"Authorization": "Bearer \$roboflowApiKey"')) {
    notes.add('the request headers in main.dart differ from what the harness sends');
  }
  if (!mainSource.contains('"$kBaseUrl"')) notes.add('the base URL in main.dart differs from $kBaseUrl');

  return AppSettings(
    distanceModel: distance,
    darkness: dark ?? 40.0,
    timeoutSeconds: timeout?.round() ?? 3,
    jpegQuality: quality?.round() ?? 85,
    notes: [...notes, ...specDrift(mainSource)],
  );
}

/// One-directional check: everything this harness assumes about the models is
/// still written in main.dart, and main.dart declares no model the harness
/// does not know. It cannot detect a class added to an allow-list in main.dart.
List<String> specDrift(String src) {
  final out = <String>[];
  bool has(String s) => src.contains('"$s"');
  for (final s in allSpecs) {
    if (!has(s.id)) out.add('model ${s.id} is not in lib/main.dart any more');
    s.tagRename.forEach((k, v) {
      if (!src.contains('"$k": "$v"')) out.add('${s.label}: class map "$k" -> "$v" not found in lib/main.dart');
    });
    for (final c in [...?s.only, ...s.ignore]) {
      if (!has(c)) out.add('${s.label}: class "$c" not found in lib/main.dart');
    }
  }
  final known = {for (final s in allSpecs) s.id};
  for (final m in RegExp(r'id:\s*"([^"]+)"').allMatches(src)) {
    if (!known.contains(m.group(1))) out.add('lib/main.dart uses model ${m.group(1)}, which this harness does not know');
  }
  return out;
}

// ---------------------------------------------------------------------------
// Frame preparation (PORTED from main.dart prepareFrameIsolate)
// ---------------------------------------------------------------------------

class FrameInfo {
  const FrameInfo({
    required this.key,
    required this.luminance,
    required this.rotated,
    required this.reencoded,
    required this.width,
    required this.height,
    this.exifOrientation,
  });

  final String key; // hash of the exact bytes that get sent
  final double luminance;
  final bool rotated;
  final bool reencoded;

  /// Upright size, as the decoder reports it (the decoder applies rotation).
  final int width;
  final int height;

  /// EXIF Orientation tag found in the ORIGINAL file, if any (1 = upright).
  final int? exifOrientation;

  /// The file carried a rotation tag (not 1) and the bytes sent still carry it,
  /// with the pixels in their original, unrotated layout. This is what the app
  /// does today (see [prepareImage]).
  bool get sentWithRotationTag => exifOrientation != null && exifOrientation != 1 && !reencoded;
}

class PreparedFrame {
  const PreparedFrame(this.jpeg, this.info);
  final Uint8List jpeg;
  final FrameInfo info;
}

/// Stable content hash (two 32-bit FNV-1a passes plus the length).
String contentHash(Uint8List bytes) {
  var a = 0x811c9dc5;
  var b = 0x9747b28c;
  for (final x in bytes) {
    a = ((a ^ x) * 0x01000193) & 0xFFFFFFFF;
    b = ((b ^ x) * 0x2c9277b5) & 0xFFFFFFFF;
  }
  String hex(int v) => v.toRadixString(16).padLeft(8, '0');
  return '${bytes.length.toRadixString(16)}-${hex(a)}${hex(b)}';
}

/// Same steps as the app: decode, check for an EXIF rotation, measure
/// brightness on a 32x24 thumbnail, and send the ORIGINAL bytes when nothing
/// had to change (otherwise a JPEG re-encode).
///
/// KNOWN APP BEHAVIOUR THIS REPRODUCES: the image library's JPEG decoder
/// already applies EXIF rotation to the pixels and then clears the tag, so the
/// app's `needsBake` test (reading the tag from the decoded image) is never
/// true for a JPEG. The app therefore sends the original bytes: unrotated
/// pixels plus the rotation tag, leaving it to the server to honour the tag.
/// [forceUpright] instead re-encodes from the decoded (already upright)
/// pixels so no tag can reach the server, to test whether that matters.
///
/// Other differences from a real camera frame: non-JPEG files are converted,
/// and [resizeLongSide] (off by default) can shrink big photos to the size the
/// app's camera really sends.
PreparedFrame prepareImage(
  Uint8List fileBytes, {
  required int jpegQuality,
  int resizeLongSide = 0,
  bool forceUpright = false,
}) {
  final isJpeg = fileBytes.length > 2 && fileBytes[0] == 0xFF && fileBytes[1] == 0xD8;
  img.Image? decoded;
  try {
    decoded = isJpeg ? img.decodeJpg(fileBytes) : img.decodeImage(fileBytes);
  } catch (e) {
    // The image library throws raw RangeErrors etc. on corrupt files.
    throw FormatException('could not decode the image (corrupt or unsupported format)');
  }
  if (decoded == null) throw const FormatException('could not decode the image (corrupt or unsupported format)');

  final ifd = decoded.exif.imageIfd;
  final needsBake = ifd.hasOrientation && ifd.orientation != null && ifd.orientation != 1;
  var upright = needsBake ? img.bakeOrientation(decoded) : decoded;

  var resized = false;
  if (resizeLongSide > 0 && math.max(upright.width, upright.height) > resizeLongSide) {
    upright = upright.width >= upright.height
        ? img.copyResize(upright, width: resizeLongSide)
        : img.copyResize(upright, height: resizeLongSide);
    resized = true;
  }

  final small = img.copyResize(upright, width: 32, height: 24);
  double total = 0;
  int count = 0;
  for (int y = 0; y < small.height; y++) {
    for (int x = 0; x < small.width; x++) {
      final pixel = small.getPixel(x, y);
      total += 0.299 * pixel.r + 0.587 * pixel.g + 0.114 * pixel.b;
      count++;
    }
  }

  int? exifOrientation;
  if (isJpeg) {
    try {
      final ifd = img.decodeJpgExif(fileBytes)?.imageIfd;
      exifOrientation = (ifd != null && ifd.hasOrientation) ? ifd.orientation : null;
    } catch (_) {
      exifOrientation = null;
    }
  }

  final reencode = needsBake || resized || !isJpeg || forceUpright;
  final jpeg = reencode ? Uint8List.fromList(img.encodeJpg(upright, quality: jpegQuality)) : fileBytes;
  return PreparedFrame(
    jpeg,
    FrameInfo(
      key: contentHash(jpeg),
      luminance: count == 0 ? 0.0 : total / count,
      rotated: needsBake,
      reencoded: reencode,
      width: upright.width,
      height: upright.height,
      exifOrientation: exifOrientation,
    ),
  );
}

// ---------------------------------------------------------------------------
// Parsing a model response (PORTED from main.dart _fetchModelDetections)
// ---------------------------------------------------------------------------

class ParsedPrediction {
  const ParsedPrediction({
    required this.model,
    required this.rawClass,
    required this.tag,
    required this.label,
    required this.box,
    required this.conf,
    this.dropped,
  });

  final String model;
  final String rawClass;

  /// Policy tag after the rename table; null when the class was filtered out.
  final String? tag;
  final String label;
  final List<double> box; // normalized [x1, y1, x2, y2]
  final double conf;

  /// Why the app's class filter discarded it before the pipeline, if it did.
  final String? dropped;

  double get yMax => box[3];
}

class ParsedResponse {
  const ParsedResponse(this.preds, this.detections, this.ignored, this.width, this.height);
  final List<ParsedPrediction> preds; // everything the model returned
  final List<Map<String, dynamic>> detections; // what the app feeds the pipeline
  final List<String> ignored;
  final int width;
  final int height;
}

ParsedResponse parseResponse(ModelSpec spec, Object? body) {
  if (body is! Map) throw const FormatException('response is not a JSON object');
  final predictions = (body['predictions'] as List?) ?? [];
  final image = body['image'];
  final frameWidth = (image is Map ? (image['width'] as num?)?.toDouble() : null) ?? 640.0;
  final frameHeight = (image is Map ? (image['height'] as num?)?.toDouble() : null) ?? 480.0;

  final preds = <ParsedPrediction>[];
  final detections = <Map<String, dynamic>>[];
  final ignored = <String>[];
  for (final p in predictions) {
    final rawClass = p['class'] as String;
    final x = (p['x'] as num).toDouble();
    final y = (p['y'] as num).toDouble();
    final w = (p['width'] as num).toDouble();
    final h = (p['height'] as num).toDouble();
    final conf = (p['confidence'] as num).toDouble();
    final box = [
      (x - w / 2) / frameWidth,
      (y - h / 2) / frameHeight,
      (x + w / 2) / frameWidth,
      (y + h / 2) / frameHeight,
    ];
    if (spec.only != null && !spec.only!.contains(rawClass)) {
      preds.add(ParsedPrediction(
        model: spec.label, rawClass: rawClass, tag: null, label: rawClass.toLowerCase(),
        box: box, conf: conf, dropped: 'class "$rawClass" is not in the ${spec.label} allow-list',
      ));
      continue;
    }
    if (spec.ignore.contains(rawClass)) {
      ignored.add(rawClass);
      preds.add(ParsedPrediction(
        model: spec.label, rawClass: rawClass, tag: null, label: rawClass.toLowerCase(),
        box: box, conf: conf, dropped: 'class "$rawClass" is on the ignore list',
      ));
      continue;
    }
    final tag = spec.tagRename[rawClass] ?? rawClass;
    final label = spec.label == 'stairs' ? tag.replaceAll('_', ' ') : rawClass.toLowerCase();
    preds.add(ParsedPrediction(
      model: spec.label, rawClass: rawClass, tag: tag, label: label, box: box, conf: conf,
    ));
    detections.add({
      'box': [...box, conf],
      'tag': tag,
      'label': label,
      'model': spec.label,
    });
  }
  return ParsedResponse(preds, detections, ignored, frameWidth.round(), frameHeight.round());
}

// ---------------------------------------------------------------------------
// Cache and live calls
// ---------------------------------------------------------------------------

class RawResponse {
  const RawResponse({required this.status, required this.body, this.headers = const {}, this.elapsedMs});
  final int status;
  final String body;
  final Map<String, String> headers;

  /// Tests set this for a deterministic latency; real calls leave it null and
  /// the client measures wall-clock time itself.
  final int? elapsedMs;
}

typedef PostFn = Future<RawResponse> Function(Uri url, Map<String, String> headers, String body, Duration timeout);

Future<RawResponse> defaultPost(Uri url, Map<String, String> headers, String body, Duration timeout) async {
  final r = await http.post(url, headers: headers, body: body).timeout(timeout);
  return RawResponse(status: r.statusCode, body: r.body, headers: r.headers);
}

class CallRecord {
  const CallRecord({
    required this.model,
    required this.key,
    required this.ok,
    required this.status,
    required this.latencyMs,
    required this.fromCache,
    this.body,
    this.error,
    this.headers = const {},
  });

  final String model;
  final String key;
  final bool ok;
  final int status;
  final int latencyMs;
  final bool fromCache;
  final Object? body;
  final String? error;
  final Map<String, String> headers;

  CallRecord asCached() => CallRecord(
        model: model, key: key, ok: ok, status: status, latencyMs: latencyMs,
        fromCache: true, body: body, error: error, headers: headers,
      );
}

class EvalCache {
  EvalCache(this.dir) {
    dir.createSync(recursive: true);
  }

  final Directory dir;

  File get _callLog => File('${dir.path}${Platform.pathSeparator}_call_log.jsonl');

  String keyFor(String modelId, String frameKey) => '${modelId.replaceAll('/', '_')}__$frameKey';

  File _file(String key) => File('${dir.path}${Platform.pathSeparator}$key.json');

  bool has(String key) => _file(key).existsSync();

  CallRecord? read(String key) {
    final f = _file(key);
    if (!f.existsSync()) return null;
    try {
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      return CallRecord(
        model: j['model'] as String,
        key: key,
        ok: true,
        status: j['status'] as int,
        latencyMs: j['latencyMs'] as int,
        fromCache: true,
        body: j['body'],
        headers: (j['headers'] as Map?)?.map((k, v) => MapEntry('$k', '$v')) ?? const {},
      );
    } catch (_) {
      return null; // corrupt entry: treat as a miss and refetch
    }
  }

  /// Only successful responses are cached, so a failed call is retried on the
  /// next run instead of being remembered as "nothing found".
  void write(CallRecord r) {
    _file(r.key).writeAsStringSync(jsonEncode({
      'model': r.model,
      'status': r.status,
      'latencyMs': r.latencyMs,
      'headers': r.headers,
      'body': r.body,
      'cachedAt': DateTime.now().toIso8601String(),
    }));
  }

  void logCall(String model, int status, int ms, bool ok, String? error) {
    _callLog.writeAsStringSync(
      '${jsonEncode({
        't': DateTime.now().toIso8601String(),
        'model': model,
        'status': status,
        'ms': ms,
        'ok': ok,
        'error': ?error,
      })}\n',
      mode: FileMode.append,
    );
  }

  /// Every live call ever made through this cache directory.
  int liveCallsEver() => _callLog.existsSync() ? _callLog.readAsLinesSync().where((l) => l.trim().isNotEmpty).length : 0;
}

class EvalClient {
  EvalClient({
    required this.cache,
    required this.apiKey,
    PostFn? post,
    this.timeout = const Duration(seconds: 10),
  }) : _post = post ?? defaultPost;

  final EvalCache cache;
  final String apiKey;
  final Duration timeout;
  final PostFn _post;

  int liveCalls = 0;
  int liveFailures = 0;
  int cacheHits = 0;
  int consecutiveFailures = 0;
  String? lastError;

  String _clean(String s) => (apiKey.isEmpty ? s : s.replaceAll(apiKey, '***'));

  static bool _interesting(String name) {
    final n = name.toLowerCase();
    return n.contains('time') || n.contains('credit') || n.contains('usage') || n.contains('cost');
  }

  Future<CallRecord> call(ModelSpec spec, PreparedFrame frame) async {
    final key = cache.keyFor(spec.id, frame.info.key);
    final hit = cache.read(key);
    if (hit != null) {
      cacheHits++;
      return hit;
    }

    liveCalls++;
    final sw = Stopwatch()..start();
    CallRecord fail(int status, String message) {
      sw.stop();
      liveFailures++;
      consecutiveFailures++;
      lastError = _clean(message);
      cache.logCall(spec.id, status, sw.elapsedMilliseconds, false, lastError);
      return CallRecord(
        model: spec.id, key: key, ok: false, status: status,
        latencyMs: sw.elapsedMilliseconds, fromCache: false, error: lastError,
      );
    }

    try {
      final r = await _post(
        Uri.parse('$kBaseUrl/${spec.id}'),
        {'Content-Type': 'application/x-www-form-urlencoded', 'Authorization': 'Bearer $apiKey'},
        base64Encode(frame.jpeg),
        timeout,
      );
      sw.stop();
      final ms = r.elapsedMs ?? sw.elapsedMilliseconds;
      if (r.status != 200) {
        final snippet = r.body.length > 160 ? r.body.substring(0, 160) : r.body;
        return fail(r.status, 'HTTP ${r.status}: $snippet');
      }
      Object? body;
      try {
        body = jsonDecode(r.body);
      } catch (_) {
        return fail(r.status, 'HTTP 200 but the body was not valid JSON');
      }
      consecutiveFailures = 0;
      cache.logCall(spec.id, r.status, ms, true, null);
      final record = CallRecord(
        model: spec.id, key: key, ok: true, status: r.status, latencyMs: ms, fromCache: false, body: body,
        headers: {for (final e in r.headers.entries) if (_interesting(e.key)) e.key.toLowerCase(): e.value},
      );
      cache.write(record);
      return record;
    } on TimeoutException {
      return fail(0, 'timed out after ${timeout.inSeconds} s');
    } catch (e) {
      return fail(0, '$e');
    }
  }
}

// ---------------------------------------------------------------------------
// Scanning images and planning the run
// ---------------------------------------------------------------------------

class ImageEntry {
  ImageEntry({required this.path, required this.rel, required this.label, required this.spec, required this.modes});

  final String path;
  final String rel; // e.g. stairs_down/img_001.jpg
  final String label;
  final LabelSpec spec;
  final List<DetectMode> modes;
  FrameInfo? info;
  String? loadError;

  bool isDark(AppSettings s) => info != null && info!.luminance < s.darkness;
}

class ScanResult {
  ScanResult(this.entries, this.unknownDirs, this.strayFiles, this.emptyLabelDirs);
  final List<ImageEntry> entries;
  final List<String> unknownDirs;
  final List<String> strayFiles;
  final List<String> emptyLabelDirs;
}

const _imageExts = {'.jpg', '.jpeg', '.png', '.webp', '.bmp', '.gif'};

ScanResult scanImages(Directory root, ModesOption modes) {
  final entries = <ImageEntry>[];
  final unknown = <String>[];
  final stray = <String>[];
  final empty = <String>[];
  if (!root.existsSync()) return ScanResult(entries, unknown, stray, empty);

  final children = root.listSync()..sort((a, b) => a.path.compareTo(b.path));
  for (final c in children) {
    final name = c.uri.pathSegments.where((s) => s.isNotEmpty).last;
    if (c is File) {
      if (_imageExts.contains(_ext(name))) stray.add(name);
      continue;
    }
    if (c is! Directory || name.startsWith('.')) continue;
    final label = normalizeLabel(name);
    final spec = kLabels[label];
    final files = c.listSync().whereType<File>().where((f) => _imageExts.contains(_ext(f.path))).toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    if (spec == null) {
      if (files.isNotEmpty) unknown.add(name);
      continue;
    }
    if (files.isEmpty) {
      empty.add(label);
      continue;
    }
    for (final f in files) {
      final fn = f.uri.pathSegments.last;
      entries.add(ImageEntry(path: f.path, rel: '$label/$fn', label: label, spec: spec, modes: modesFor(spec, modes)));
    }
  }
  return ScanResult(entries, unknown, stray, empty);
}

String _ext(String path) {
  final i = path.lastIndexOf('.');
  return i < 0 ? '' : path.substring(i).toLowerCase();
}

class Plan {
  Plan(this.entries);
  final List<ImageEntry> entries;
  int unreadable = 0;
  int dark = 0;
  int callsNeeded = 0;
  int callsCached = 0;
  int get callsToMake => callsNeeded - callsCached;
  final Map<String, int> toMakeByModel = {};
  final Map<String, int> imagesPerLabel = {};
  int get imagesTotal => entries.length;
}

Plan buildPlan({
  required ScanResult scan,
  required AppSettings settings,
  required EvalCache cache,
  required int resize,
  bool upright = false,
}) {
  final plan = Plan(scan.entries);
  for (final e in scan.entries) {
    plan.imagesPerLabel[e.label] = (plan.imagesPerLabel[e.label] ?? 0) + 1;
    try {
      e.info = prepareImage(File(e.path).readAsBytesSync(),
              jpegQuality: settings.jpegQuality, resizeLongSide: resize, forceUpright: upright)
          .info;
    } catch (err) {
      e.loadError = '$err';
      plan.unreadable++;
      continue;
    }
    if (e.isDark(settings)) {
      plan.dark++;
      continue; // the app would raise its dark-camera fail-safe and call nothing
    }
    for (final spec in modelsFor(e.modes)) {
      plan.callsNeeded++;
      if (cache.has(cache.keyFor(spec.id, e.info!.key))) {
        plan.callsCached++;
      } else {
        plan.toMakeByModel[spec.id] = (plan.toMakeByModel[spec.id] ?? 0) + 1;
      }
    }
  }
  return plan;
}

/// How many live calls a given photo count would need (nothing cached).
int estimateCalls(Map<String, int> countsPerLabel, ModesOption modes) {
  var total = 0;
  countsPerLabel.forEach((label, n) {
    final spec = kLabels[label];
    if (spec != null) total += n * modelsFor(modesFor(spec, modes)).length;
  });
  return total;
}

String describePlan(Plan p, ModesOption modes, {int resize = 0, bool upright = false}) {
  final b = StringBuffer();
  b.writeln('Images found: ${p.imagesTotal}  (${p.imagesPerLabel.entries.map((e) => '${e.key} ${e.value}').join(', ')})');
  b.writeln('Modes: ${modes.name}   Resize: ${resize > 0 ? 'longest side $resize px' : 'none (sent as-is)'}   '
      'Rotation: ${upright ? 'photos re-encoded upright (--send-upright)' : 'original bytes sent, like the app'}');
  final tagged = p.entries.where((e) => e.info?.sentWithRotationTag ?? false).length;
  if (tagged > 0) {
    b.writeln('  $tagged photo(s) carry an EXIF rotation tag that will be left in the file, as the app does (see the report)');
  }
  if (p.unreadable > 0) b.writeln('  ${p.unreadable} image(s) could not be read and will be listed as errors');
  if (p.dark > 0) b.writeln('  ${p.dark} image(s) are dark enough that the app would raise its camera fail-safe and call no model');
  b.writeln('API calls for this run:');
  b.writeln('  needed in total:        ${p.callsNeeded}');
  b.writeln('  already cached (free):  ${p.callsCached}');
  b.writeln('  NEW live calls:         ${p.callsToMake}');
  for (final e in p.toMakeByModel.entries) {
    b.writeln('      ${e.key}: ${e.value}');
  }
  return b.toString();
}

// ---------------------------------------------------------------------------
// Replaying one image through the real pipeline and policy
// ---------------------------------------------------------------------------

class AlertEvent {
  const AlertEvent({
    required this.frame,
    required this.tier,
    required this.tag,
    required this.name,
    required this.zone,
    required this.proximity,
    required this.distFeet,
    required this.clipped,
    required this.conf,
    required this.yMax,
    required this.speech,
    required this.spoken,
    required this.withheldReason,
    required this.haptic,
  });

  final int frame;
  final AlertTier tier;
  final String tag;
  final String name;
  final String zone;
  final String proximity;
  final double distFeet;
  final bool clipped;
  final double conf;
  final double yMax;
  final String speech;
  final bool spoken;
  final String? withheldReason;
  final String haptic;
}

class ReplayResult {
  const ReplayResult(this.alerts, this.display, this.displayDist, this.rawCount, this.confirmedCount);
  final List<AlertEvent> alerts;
  final Candidate? display;
  final double? displayDist;
  final int rawCount;
  final int confirmedCount;
}

/// Feeds the same detections to a fresh pipeline for [frames] frames, 1 s
/// apart, as the app would see a hazard that stays put. This cannot model
/// flicker, motion or a changing scene.
ReplayResult replay(List<Map<String, dynamic>> detections, DistanceModel dm, {int frames = 3}) {
  final pipeline = DetectionPipeline(distanceModel: dm);
  final policy = AlertPolicy();
  var t = DateTime(2026, 1, 1);
  final alerts = <AlertEvent>[];
  PipelineResult? last;
  for (var f = 1; f <= frames; f++) {
    final r = pipeline.process(detections, t);
    final a = r.alert;
    if (a != null) {
      final out = policy.decide(a, t); // voice assumed idle
      alerts.add(AlertEvent(
        frame: f, tier: a.tier, tag: a.tag, name: a.label, zone: a.zone, proximity: a.proximity.name,
        distFeet: a.distFeet, clipped: a.clipped, conf: a.conf, yMax: a.yMax, speech: out.speech,
        spoken: out.speak, withheldReason: out.suppressedReason, haptic: out.haptic.description,
      ));
    }
    last = r;
    t = t.add(const Duration(seconds: 1));
  }
  return ReplayResult(alerts, last?.display, last?.displayDistFeet, last?.rawCount ?? 0, last?.confirmedCount ?? 0);
}

// ---------------------------------------------------------------------------
// Explaining why a prediction did not become an alert
// ---------------------------------------------------------------------------

enum DropReason { none, lowConfidence, aboveHorizon, outOfRange, offPath, infoTier }

class DropExplanation {
  const DropExplanation(this.reason, this.text);
  final DropReason reason;
  final String text;
}

/// Mirrors the order of checks inside the pipeline, calling the same shared
/// functions, to describe what stopped a prediction. A diagnostic only: the
/// pass/fail outcome always comes from the real pipeline.
DropExplanation explainPrediction(ParsedPrediction p, DistanceModel dm, PipelineConfig cfg) {
  if (p.conf < cfg.minConf) {
    return DropExplanation(DropReason.lowConfidence,
        'confidence ${(p.conf * 100).round()}% is under the app threshold ${(cfg.minConf * 100).round()}%');
  }
  final measured = dm.distanceFeet(p.yMax);
  if (measured == null) {
    return DropExplanation(DropReason.aboveHorizon,
        'box bottom (y=${p.yMax.toStringAsFixed(2)}) is at or above the horizon, so no distance can be computed');
  }
  final clipped = p.yMax >= cfg.clipYMax;
  final dist = clipped ? dm.floorFeet : measured;
  if (!clipped && dist > cfg.maxDistFeet) {
    return DropExplanation(DropReason.outOfRange,
        'estimated ${dist.toStringAsFixed(1)} ft (box bottom y=${p.yMax.toStringAsFixed(2)}) is beyond the ${cfg.maxDistFeet.round()} ft range');
  }
  final xc = (p.box[0] + p.box[2]) / 2.0;
  final zone = xc < 0.33 ? 'left' : xc > 0.66 ? 'right' : 'center';
  final tier = classifyTier(tag: p.tag ?? '', proximity: proximityFor(dist, clipped, cfg), zone: zone);
  if (tier == null) {
    return DropExplanation(DropReason.offPath, 'in the $zone of the frame, off the walking path, so it is dropped');
  }
  if (tier == AlertTier.info) {
    return const DropExplanation(DropReason.infoTier, 'shown on screen but silent by design (tier info)');
  }
  return DropExplanation(DropReason.none, 'passed every filter (tier ${tier.name})');
}

// ---------------------------------------------------------------------------
// One scored result per (image, mode)
// ---------------------------------------------------------------------------

enum Outcome {
  alertedCorrect,
  wrongClass,
  silentByDesign,
  filtered,
  notSeen,
  failsafeDark,
  error,
  clearOk,
  falseAlarm,
}

class EvalRow {
  const EvalRow({
    required this.image,
    required this.label,
    required this.mode,
    required this.outcome,
    this.why = '',
    this.alerts = const [],
    this.preds = const [],
    this.display,
    this.displayDist,
    this.modelSaw = false,
    this.bestExpectedConf,
    this.nameMismatch = false,
    this.extraAlerts = const [],
    this.notes = const [],
    this.luminance,
    this.width,
    this.height,
  });

  final String image;
  final String label;
  final DetectMode mode;
  final Outcome outcome;
  final String why;
  final List<AlertEvent> alerts;
  final List<ParsedPrediction> preds;
  final Candidate? display;
  final double? displayDist;
  final bool modelSaw; // a kept prediction of the expected class at/above the app threshold
  final double? bestExpectedConf;
  final bool nameMismatch; // right hazard type, but spoken under a different name
  final List<AlertEvent> extraAlerts; // alerts for something that was NOT expected
  final List<String> notes;
  final double? luminance;
  final int? width;
  final int? height;

  String get group => '$label/${mode.name}';
  bool get isClear => kLabels[label]!.isClear;

  AlertEvent? get topAlert {
    AlertEvent? best;
    for (final a in alerts) {
      if (best == null || tierPriority(a.tier) > tierPriority(best.tier)) best = a;
    }
    return best;
  }

  /// What the user would actually hear for this photo. A critical alert is
  /// re-spoken every frame by design, so identical neighbours are collapsed
  /// ("Stop. Stairs down. (x3)") rather than listed three times.
  String get spokenText {
    final spoken = alerts.where((a) => a.spoken).map((a) => a.speech).toList();
    if (spoken.isNotEmpty) return _collapseRepeats(spoken);
    if (alerts.isNotEmpty) return '(haptic only) ${alerts.first.speech}';
    switch (outcome) {
      case Outcome.failsafeDark:
        return '(camera dark: fail-safe message)';
      case Outcome.error:
        return '(not tested: error)';
      default:
        return '(silent)';
    }
  }
}

String _collapseRepeats(List<String> sentences) {
  final parts = <String>[];
  var i = 0;
  while (i < sentences.length) {
    var j = i;
    while (j + 1 < sentences.length && sentences[j + 1] == sentences[i]) {
      j++;
    }
    final n = j - i + 1;
    parts.add(n == 1 ? sentences[i] : '${sentences[i]} (x$n)');
    i = j + 1;
  }
  return parts.join(' / ');
}

EvalRow errorRow(ImageEntry e, DetectMode mode, String message) =>
    EvalRow(image: e.rel, label: e.label, mode: mode, outcome: Outcome.error, why: message);

EvalRow buildRow({
  required ImageEntry entry,
  required DetectMode mode,
  required Map<String, CallRecord> calls,
  required AppSettings settings,
}) {
  final info = entry.info!;
  if (entry.isDark(settings)) {
    return EvalRow(
      image: entry.rel, label: entry.label, mode: mode, outcome: Outcome.failsafeDark,
      why: 'brightness ${info.luminance.toStringAsFixed(0)} is under ${settings.darkness.round()}: the app would say its camera-dark fail-safe and call no model',
      luminance: info.luminance, width: info.width, height: info.height,
    );
  }

  final parsed = <ParsedResponse>[];
  final failures = <String>[];
  for (final spec in specsFor(mode)) {
    final rec = calls[spec.id];
    if (rec == null || !rec.ok) {
      failures.add('${spec.label}: ${rec?.error ?? 'no result'}');
      continue;
    }
    try {
      parsed.add(parseResponse(spec, rec.body));
    } catch (e) {
      failures.add('${spec.label}: unexpected response shape ($e)');
    }
  }
  if (parsed.isEmpty) {
    return EvalRow(
      image: entry.rel, label: entry.label, mode: mode, outcome: Outcome.error,
      why: failures.join('; '), luminance: info.luminance, width: info.width, height: info.height,
    );
  }

  final detections = [for (final p in parsed) ...p.detections];
  final preds = [for (final p in parsed) ...p.preds];
  final result = replay(detections, settings.distanceModel);
  const cfg = PipelineConfig();
  final exp = entry.spec;

  List<AlertEvent> extras() => [for (final a in result.alerts) if (!exp.tags.contains(a.tag)) a];
  final base = (
    alerts: result.alerts,
    preds: preds,
    display: result.display,
    displayDist: result.displayDist,
    notes: failures,
  );

  EvalRow row(Outcome o, String why, {bool saw = false, double? conf, bool nameMismatch = false, List<AlertEvent>? extra}) =>
      EvalRow(
        image: entry.rel, label: entry.label, mode: mode, outcome: o, why: why,
        alerts: base.alerts, preds: base.preds, display: base.display, displayDist: base.displayDist,
        modelSaw: saw, bestExpectedConf: conf, nameMismatch: nameMismatch,
        extraAlerts: extra ?? const [], notes: base.notes,
        luminance: info.luminance, width: info.width, height: info.height,
      );

  if (exp.isClear) {
    if (result.alerts.isEmpty) {
      final shown = result.display;
      return row(Outcome.clearOk, shown == null ? 'no alert' : 'no alert (on screen only: ${shown.label}, tier ${shown.tier.name})');
    }
    final a = result.topAlert;
    return row(Outcome.falseAlarm, 'said "${a.speech}" (${a.tier.name}, ${a.name} ${(a.conf * 100).round()}%)', extra: result.alerts);
  }

  final expectedPreds = [
    for (final p in preds) if (p.dropped == null && p.tag != null && exp.tags.contains(p.tag)) p,
  ]..sort((a, b) => b.conf.compareTo(a.conf));
  final saw = expectedPreds.any((p) => p.conf >= cfg.minConf);
  final bestConf = expectedPreds.isEmpty ? null : expectedPreds.first.conf;
  final correct = [for (final a in result.alerts) if (exp.tags.contains(a.tag)) a];

  if (correct.isNotEmpty) {
    final mismatch = exp.names.isNotEmpty && !correct.any((a) => exp.names.contains(a.name));
    final ex = extras();
    final why = mismatch ? 'right hazard type but spoken as "${correct.first.name}" (expected ${exp.names.join('/')})' : 'ok';
    return row(Outcome.alertedCorrect, why, saw: saw, conf: bestConf, nameMismatch: mismatch, extra: ex);
  }
  if (result.alerts.isNotEmpty) {
    final a = result.topAlert;
    return row(Outcome.wrongClass, 'said "${a.speech}" instead (${a.tier.name}, ${a.name} ${(a.conf * 100).round()}%)',
        saw: saw, conf: bestConf, extra: result.alerts);
  }
  if (expectedPreds.isEmpty) {
    final filteredByClass = [
      for (final p in preds) if (p.dropped != null && exp.names.contains(p.rawClass.toLowerCase())) p,
    ];
    if (filteredByClass.isNotEmpty) {
      return row(Outcome.filtered, filteredByClass.first.dropped!, conf: filteredByClass.first.conf);
    }
    final others = [for (final p in preds) if (p.tag != null) '${p.label} ${(p.conf * 100).round()}%'];
    return row(Outcome.notSeen, others.isEmpty ? 'the models returned no detections' : 'the models only returned: ${others.join(', ')}');
  }
  final ex = explainPrediction(expectedPreds.first, settings.distanceModel, cfg);
  return row(
    ex.reason == DropReason.infoTier ? Outcome.silentByDesign : Outcome.filtered,
    ex.text,
    saw: saw,
    conf: bestConf,
  );
}

extension on ReplayResult {
  AlertEvent get topAlert => alerts.reduce((a, b) => tierPriority(b.tier) > tierPriority(a.tier) ? b : a);
}

// ---------------------------------------------------------------------------
// Running everything
// ---------------------------------------------------------------------------

class RunOutput {
  RunOutput(this.rows, this.calls, this.abortReason);
  final List<EvalRow> rows;
  final List<CallRecord> calls; // one per distinct (model, frame)
  final String? abortReason;
}

Future<RunOutput> runEval({
  required Plan plan,
  required AppSettings settings,
  required EvalClient client,
  required int resize,
  bool upright = false,
  void Function(String)? log,
  int abortAfterFailures = 5,
}) async {
  final rows = <EvalRow>[];
  final calls = <String, CallRecord>{};
  String? abort;
  var i = 0;
  for (final e in plan.entries) {
    i++;
    if (e.loadError != null) {
      for (final m in e.modes) {
        rows.add(errorRow(e, m, 'could not read the image: ${e.loadError}'));
      }
      continue;
    }
    if (e.isDark(settings)) {
      for (final m in e.modes) {
        rows.add(buildRow(entry: e, mode: m, calls: const {}, settings: settings));
      }
      continue;
    }

    final frame = prepareImage(File(e.path).readAsBytesSync(),
        jpegQuality: settings.jpegQuality, resizeLongSide: resize, forceUpright: upright);
    final specs = modelsFor(e.modes).toList();
    final liveBefore = client.liveCalls;
    // Like the app, the models for one frame are called concurrently.
    final results = await Future.wait([for (final s in specs) client.call(s, frame)]);
    final byId = <String, CallRecord>{};
    for (var k = 0; k < specs.length; k++) {
      byId[specs[k].id] = results[k];
      calls['${specs[k].id}|${results[k].key}'] = results[k];
    }
    for (final m in e.modes) {
      rows.add(buildRow(entry: e, mode: m, calls: byId, settings: settings));
    }
    log?.call('[$i/${plan.entries.length}] ${e.rel}   live calls this run: ${client.liveCalls} '
        '(+${client.liveCalls - liveBefore} here), cache hits: ${client.cacheHits}, '
        'all-time live calls: ${client.cache.liveCallsEver()}');

    if (client.consecutiveFailures >= abortAfterFailures) {
      abort = '$abortAfterFailures live calls in a row failed; stopped to avoid wasting calls. '
          'Last error: ${client.lastError}';
      break;
    }
  }
  return RunOutput(rows, calls.values.toList(), abort);
}

// ---------------------------------------------------------------------------
// Statistics
// ---------------------------------------------------------------------------

/// 95% Wilson score interval for k successes out of n.
(double, double) wilson(int k, int n, {double z = 1.96}) {
  if (n == 0) return (0.0, 1.0);
  final p = k / n;
  final denom = 1 + z * z / n;
  final centre = p + z * z / (2 * n);
  final margin = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n));
  return (math.max(0.0, (centre - margin) / denom), math.min(1.0, (centre + margin) / denom));
}

/// Nearest-rank percentile of an unsorted list.
int percentile(List<int> values, double pct) {
  if (values.isEmpty) return 0;
  final s = [...values]..sort();
  final rank = (pct / 100 * s.length).ceil().clamp(1, s.length);
  return s[rank - 1];
}

double median(List<int> values) {
  if (values.isEmpty) return 0;
  final s = [...values]..sort();
  final mid = s.length ~/ 2;
  return s.length.isOdd ? s[mid].toDouble() : (s[mid - 1] + s[mid]) / 2.0;
}

class GroupStats {
  GroupStats(this.label, this.mode);
  final String label;
  final DetectMode mode;
  int n = 0;
  int errors = 0;
  int dark = 0;
  int correct = 0;
  int wrong = 0;
  int silent = 0;
  int filtered = 0;
  int notSeen = 0;
  int modelSaw = 0;
  int clearOk = 0;
  int falseAlarm = 0;
  int screenOnly = 0;
  int nameMismatch = 0;
  int withExtra = 0;
  int get tested => n - errors;
  bool get isClear => kLabels[label]!.isClear;
  String get key => '$label/${mode.name}';
}

Map<String, GroupStats> groupStats(List<EvalRow> rows) {
  final out = <String, GroupStats>{};
  for (final r in rows) {
    final g = out.putIfAbsent(r.group, () => GroupStats(r.label, r.mode));
    g.n++;
    switch (r.outcome) {
      case Outcome.error:
        g.errors++;
      case Outcome.failsafeDark:
        g.dark++;
      case Outcome.alertedCorrect:
        g.correct++;
      case Outcome.wrongClass:
        g.wrong++;
      case Outcome.silentByDesign:
        g.silent++;
      case Outcome.filtered:
        g.filtered++;
      case Outcome.notSeen:
        g.notSeen++;
      case Outcome.clearOk:
        g.clearOk++;
        if (r.display != null) g.screenOnly++;
      case Outcome.falseAlarm:
        g.falseAlarm++;
    }
    if (r.modelSaw) g.modelSaw++;
    if (r.nameMismatch) g.nameMismatch++;
    if (r.outcome == Outcome.alertedCorrect && r.extraAlerts.isNotEmpty) g.withExtra++;
  }
  return out;
}

/// Is this (label, mode) one the app is expected to handle? Recall is only
/// computed for those; other combinations (e.g. a chair photo run through
/// street mode) only contribute extra / wrong-class alerts.
bool isApplicable(String label, DetectMode mode) => kLabels[label]!.modes.contains(mode);

class LatencyStats {
  LatencyStats(this.model, this.values, this.failed);
  final String model;
  final List<int> values;
  final int failed;
  int get n => values.length;
  double get med => median(values);
  int get p90 => percentile(values, 90);
  int get max => values.isEmpty ? 0 : values.reduce(math.max);
  int get overAppTimeout => values.where((v) => v > kAppTimeoutMs).length;
}

List<LatencyStats> latencyStats(List<CallRecord> calls) {
  final byModel = <String, List<int>>{};
  final failed = <String, int>{};
  for (final c in calls) {
    if (c.ok) {
      byModel.putIfAbsent(c.model, () => []).add(c.latencyMs);
    } else {
      failed[c.model] = (failed[c.model] ?? 0) + 1;
    }
  }
  final all = [for (final v in byModel.values) ...v];
  return [
    LatencyStats('ALL MODELS', all, failed.values.fold(0, (a, b) => a + b)),
    for (final m in byModel.keys.toList()..sort()) LatencyStats(m, byModel[m]!, failed[m] ?? 0),
  ];
}

/// How bad a failed row is, for ranking the worst ten. Silence that said
/// nothing about a drop-off or a vehicle ranks below saying the WRONG thing,
/// and both rank below a false alarm on a clear path.
int? failureScore(EvalRow r) {
  int sev() => r.isClear ? 0 : (kHazardSeverity[kLabels[r.label]!.tags.first] ?? 1);
  switch (r.outcome) {
    case Outcome.falseAlarm:
      return 100 + 10 * tierPriority(r.topAlert!.tier);
    case Outcome.wrongClass:
      return 80 + 10 * sev();
    case Outcome.notSeen:
    case Outcome.filtered:
      return 60 + 10 * sev();
    case Outcome.silentByDesign:
      return 20 + 10 * sev();
    case Outcome.alertedCorrect:
      if (r.extraAlerts.isEmpty) return null;
      final worst = r.extraAlerts.map((a) => tierPriority(a.tier)).reduce(math.max);
      return 30 + 10 * worst;
    default:
      return null;
  }
}

// ---------------------------------------------------------------------------
// Report
// ---------------------------------------------------------------------------

String _md(String s) => s.replaceAll('|', '\\|').replaceAll('\n', ' ');

String _pct(int k, int n) => n == 0 ? 'n/a' : '${(100 * k / n).round()}%';

String _ci(int k, int n) {
  if (n == 0) return 'n/a';
  final (lo, hi) = wilson(k, n);
  return '${(lo * 100).round()}-${(hi * 100).round()}%';
}

class ReportInput {
  ReportInput({
    required this.generated,
    required this.command,
    required this.rows,
    required this.calls,
    required this.settings,
    required this.modes,
    required this.resize,
    required this.scan,
    required this.client,
    required this.minPerLabel,
    this.upright = false,
    this.entries = const [],
    this.abortReason,
  });

  final DateTime generated;
  final String command;
  final List<EvalRow> rows;
  final List<CallRecord> calls;
  final AppSettings settings;
  final ModesOption modes;
  final int resize;
  final ScanResult scan;
  final EvalClient client;
  final int minPerLabel;
  final bool upright;
  final List<ImageEntry> entries; // for the rotation-tag count
  final String? abortReason;
}

String buildReport(ReportInput r) {
  final b = StringBuffer();
  final groups = groupStats(r.rows);
  final images = {for (final row in r.rows) row.image}.length;
  final lat = latencyStats(r.calls);

  b.writeln('# AHHA detector self-test report');
  b.writeln();
  b.writeln('Generated ${r.generated.toIso8601String()} by `tools/eval/run_eval.dart`.');
  b.writeln('Every number below was computed from this run\'s responses. Nothing is quoted from model providers or from memory.');
  if (r.abortReason != null) {
    b.writeln();
    b.writeln('> **RUN STOPPED EARLY:** ${r.abortReason}');
    b.writeln('> Results below cover only the images processed before it stopped.');
  }
  b.writeln();

  // 1 ---------------------------------------------------------------
  b.writeln('## 1. What was run');
  b.writeln();
  b.writeln('- Command: `${r.command}`');
  b.writeln('- Photos: **$images** (${_perLabelSummary(r.rows)})');
  b.writeln('- Modes: `${r.modes.name}`${r.modes == ModesOption.auto ? ' (each photo is run only in the mode(s) that can find its label; clear photos in both)' : ''}');
  b.writeln('- Photo size: ${r.resize > 0 ? 'resized so the longest side is ${r.resize} px' : 'sent as-is, no resizing'}. '
      'The app\'s real frame size is shown in its debug panel ("Server saw"); if photos are much larger, rerun with `--resize` set to that size.');
  final tagged = r.entries.where((e) => e.info?.sentWithRotationTag ?? false).toList();
  final withTag = r.entries.where((e) => (e.info?.exifOrientation ?? 1) != 1).length;
  if (r.upright) {
    b.writeln('- **Rotation: `--send-upright` was used.** Every photo was re-encoded from its decoded, already-upright pixels, so no EXIF rotation tag reached the server. '
        'This is NOT what the app does today; compare with a run without the flag to see whether it matters.');
  } else if (withTag == 0) {
    b.writeln('- Rotation: no photo carried an EXIF rotation tag, so rotation handling did not affect this run.');
  } else {
    b.writeln('- Rotation: photos are sent exactly as the app sends them: the original bytes. $withTag of ${r.entries.length} photo(s) carry an EXIF rotation tag, '
        'and in ${tagged.length} the tag was left in the file with the pixels in their original (unrotated) layout. '
        'This matches the app today: the image library\'s decoder already applies the rotation and clears the tag, so the app\'s own "bake rotation" step never runs and the server '
        'is left to honour the tag. Whether it does was not measured; rerun with `--send-upright` to find out whether it matters.');
  }
  b.writeln('- Each photo is replayed as **3 identical frames, 1 s apart**, through a fresh `DetectionPipeline` and `AlertPolicy`, '
      'as the app would see a hazard that stays put. This cannot show flicker, motion or a changing scene.');
  b.writeln('- Settings read from `lib/main.dart`: camera height ${r.settings.distanceModel.cameraHeightM} m, '
      'pitch ${r.settings.distanceModel.pitchDeg}\u00b0, vertical FOV ${r.settings.distanceModel.fovVDeg}\u00b0, '
      'dark threshold ${r.settings.darkness.round()}, JPEG quality ${r.settings.jpegQuality}.');
  b.writeln();
  b.writeln('**Reused directly from the app:** `lib/detection_logic.dart` (pipeline, distance model, tiering) and '
      '`lib/alert_policy.dart` (the words spoken).');
  b.writeln('**Ported (copied) from `lib/main.dart`:** model ids and class tables, request format, frame preparation, and the response-to-pipeline glue. '
      'Not reproduced: speech playback state (the voice is treated as idle), haptics, the camera.');
  if (r.settings.notes.isEmpty) {
    b.writeln('Sync check against `lib/main.dart`: no differences found (class lists are checked one way only).');
  } else {
    b.writeln();
    b.writeln('**Sync check warnings** (the harness may no longer match the app):');
    for (final n in r.settings.notes) {
      b.writeln('- ${_md(n)}');
    }
  }
  b.writeln();

  // 2 ---------------------------------------------------------------
  b.writeln('## 2. Results by label');
  b.writeln();
  b.writeln('"Alerted correctly" = the app would have dispatched an alert (not just shown it on screen) for the right kind of hazard. '
      '"Model saw it" = a model returned the right class at or above the app\'s ${(const PipelineConfig().minConf * 100).round()}% threshold, before range / path / tier rules. '
      'Intervals are 95% Wilson intervals. Groups marked * have fewer than ${r.minPerLabel} photos: too few to judge.');
  b.writeln();
  b.writeln('| label / mode | photos | alerted correctly | recall | 95% interval | model saw it | wrong class said | dropped by pipeline | silent by design | model saw nothing | camera-dark fail-safe | errors |');
  b.writeln('|---|---|---|---|---|---|---|---|---|---|---|---|');
  final hazard = groups.values.where((g) => !g.isClear && isApplicable(g.label, g.mode)).toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  for (final g in hazard) {
    final small = g.tested < r.minPerLabel ? '*' : '';
    b.writeln('| ${g.key}$small | ${g.n} | ${g.correct} | ${_pct(g.correct, g.tested)} | ${_ci(g.correct, g.tested)} | '
        '${g.modelSaw}/${g.tested} | ${g.wrong} | ${g.filtered} | ${g.silent} | ${g.notSeen} | ${g.dark} | ${g.errors} |');
  }
  if (hazard.isEmpty) b.writeln('| (no hazard photos in this run) | | | | | | | | | | | |');
  final nameMis = groups.values.fold<int>(0, (a, g) => a + g.nameMismatch);
  final withExtra = groups.values.fold<int>(0, (a, g) => a + g.withExtra);
  if (nameMis > 0) b.writeln('\n$nameMis correct alert(s) named the hazard differently than the label (see the failure list and CSV).');
  if (withExtra > 0) b.writeln('$withExtra hazard photo(s) also produced an alert for something that was not expected (see section 4).');
  b.writeln();

  // 3 ---------------------------------------------------------------
  b.writeln('## 3. Clear photos (false alarms)');
  b.writeln();
  final clears = groups.values.where((g) => g.isClear).toList()..sort((a, b) => a.key.compareTo(b.key));
  if (clears.isEmpty) {
    b.writeln('No photos in `images/clear/` were run, so the false-alarm rate was **not measured**.');
  } else {
    b.writeln('| mode | clear photos | triggered an alert | false-alarm rate | 95% interval | on screen only (silent) | camera-dark | errors |');
    b.writeln('|---|---|---|---|---|---|---|---|');
    for (final g in clears) {
      final small = g.tested < r.minPerLabel ? '*' : '';
      b.writeln('| ${g.mode.name}$small | ${g.n} | ${g.falseAlarm} | ${_pct(g.falseAlarm, g.clearOk + g.falseAlarm)} | '
          '${_ci(g.falseAlarm, g.clearOk + g.falseAlarm)} | ${g.screenOnly} | ${g.dark} | ${g.errors} |');
    }
    final fa = r.rows.where((x) => x.outcome == Outcome.falseAlarm).toList();
    if (fa.isEmpty) {
      b.writeln('\nNo clear photo triggered an alert.');
    } else {
      b.writeln('\nAlerts raised on clear photos:');
      b.writeln();
      b.writeln('| photo | mode | tier | what it said | detected as | confidence |');
      b.writeln('|---|---|---|---|---|---|');
      for (final x in fa) {
        // The same alert fires on each replayed frame; list it once with a count.
        final seen = <String, int>{};
        final first = <String, AlertEvent>{};
        for (final a in x.alerts) {
          final k = '${a.tier.name}|${a.tag}|${a.speech}';
          seen[k] = (seen[k] ?? 0) + 1;
          first.putIfAbsent(k, () => a);
        }
        for (final k in seen.keys) {
          final a = first[k]!;
          final times = seen[k]! > 1 ? ' (x${seen[k]} frames)' : '';
          b.writeln('| ${_md(x.image)} | ${x.mode.name} | ${a.tier.name} | ${_md(a.speech)}$times | ${_md(a.name)} | ${(a.conf * 100).round()}% |');
        }
      }
    }
  }
  b.writeln();

  // 4 ---------------------------------------------------------------
  b.writeln('## 4. Wrong-class confusions');
  b.writeln();
  b.writeln('Rows are the true label; columns are the highest-priority thing the app alerted for. `(no alert)` means silence.');
  b.writeln();
  final confusion = <String, Map<String, int>>{};
  final cols = <String>{};
  for (final x in r.rows) {
    if (x.outcome == Outcome.error) continue;
    final top = x.topAlert;
    final what = x.outcome == Outcome.failsafeDark ? '(camera-dark)' : top == null ? '(no alert)' : '${top.name} [${top.tag}]';
    cols.add(what);
    final row = confusion.putIfAbsent(x.group, () => {});
    row[what] = (row[what] ?? 0) + 1;
  }
  if (confusion.isEmpty) {
    b.writeln('(nothing to tabulate)');
  } else {
    final colList = cols.toList()..sort();
    b.writeln('| true label / mode | ${colList.map(_md).join(' | ')} |');
    b.writeln('|---|${List.filled(colList.length, '---').join('|')}|');
    for (final k in confusion.keys.toList()..sort()) {
      b.writeln('| $k | ${colList.map((c) => '${confusion[k]![c] ?? 0}').join(' | ')} |');
    }
    final wrong = r.rows.where((x) => x.outcome == Outcome.wrongClass).toList();
    if (wrong.isNotEmpty) {
      b.writeln('\nPhotos where the app alerted for the wrong thing and never for the right one:');
      for (final x in wrong) {
        b.writeln('- `${x.image}` (${x.mode.name}): ${_md(x.why)}');
      }
    }
  }
  b.writeln();

  // 5 ---------------------------------------------------------------
  b.writeln('## 5. Latency');
  b.writeln();
  b.writeln('Round-trip time of each hosted model call **from this computer on this network** (not from the phone). '
      'Percentiles use the nearest-rank method. Calls served from cache report the latency recorded when they were first made.');
  b.writeln();
  b.writeln('| model | calls | median ms | 90th percentile ms | max ms | over the app\'s ${kAppTimeoutMs ~/ 1000} s timeout | failed calls |');
  b.writeln('|---|---|---|---|---|---|---|');
  for (final l in lat) {
    if (l.n == 0 && l.failed == 0) continue;
    b.writeln('| ${l.model} | ${l.n} | ${l.n == 0 ? 'n/a' : l.med.round().toString()} | ${l.n == 0 ? 'n/a' : l.p90.toString()} | '
        '${l.n == 0 ? 'n/a' : l.max.toString()} | ${l.overAppTimeout} | ${l.failed} |');
  }
  if (r.calls.isEmpty) b.writeln('| (no model calls were made) | | | | | | |');
  b.writeln();
  b.writeln('Calls over the app\'s timeout are counted but NOT dropped from the results above; in the app they would have counted as a failed call.');
  b.writeln();

  // 6 ---------------------------------------------------------------
  b.writeln('## 6. The 10 worst failures');
  b.writeln();
  final scored = <(int, EvalRow)>[
    for (final x in r.rows)
      if (failureScore(x) != null) (failureScore(x)!, x),
  ]..sort((a, b) {
      final c = b.$1.compareTo(a.$1);
      return c != 0 ? c : a.$2.image.compareTo(b.$2.image);
    });
  if (scored.isEmpty) {
    b.writeln('No failures in this run.');
  } else {
    b.writeln('Ranked: a false alarm on a clear photo, then saying the wrong thing, then a miss of a drop-off or vehicle, then other misses.');
    b.writeln();
    b.writeln('| # | photo | mode | expected | what it said | why |');
    b.writeln('|---|---|---|---|---|---|');
    var rank = 0;
    for (final (_, x) in scored.take(10)) {
      rank++;
      final said = x.alerts.isEmpty ? '(silent)' : x.spokenText;
      final expected = x.isClear ? 'clear (no alert)' : x.label;
      b.writeln('| $rank | ${_md(x.image)} | ${x.mode.name} | $expected | ${_md(said)} | ${_md(x.why)} |');
    }
    final more = scored.length - 10;
    if (more > 0) b.writeln('\n$more further failure(s) are in `results.csv`.');
  }
  b.writeln();

  // 7 ---------------------------------------------------------------
  b.writeln('## 7. What would be spoken, per photo');
  b.writeln();
  b.writeln('Words come from the real `AlertPolicy`. "(haptic only)" = an alert fired but its speech was withheld; "(silent)" = nothing. Also in `results.csv`.');
  b.writeln();
  final byGroup = <String, List<EvalRow>>{};
  for (final x in r.rows) {
    byGroup.putIfAbsent(x.group, () => []).add(x);
  }
  for (final k in byGroup.keys.toList()..sort()) {
    b.writeln('<details><summary>$k (${byGroup[k]!.length})</summary>');
    b.writeln();
    b.writeln('| photo | outcome | spoken | tier | note |');
    b.writeln('|---|---|---|---|---|');
    for (final x in byGroup[k]!) {
      final tier = x.topAlert?.tier.name ?? '-';
      b.writeln('| ${_md(x.image)} | ${x.outcome.name} | ${_md(x.spokenText)} | $tier | ${_md(x.why)} |');
    }
    b.writeln();
    b.writeln('</details>');
    b.writeln();
  }

  // 8 ---------------------------------------------------------------
  b.writeln('## 8. API calls and credits');
  b.writeln();
  b.writeln('- Live calls made this run: **${r.client.liveCalls}** (${r.client.liveFailures} failed)');
  b.writeln('- Served from the on-disk cache (free): **${r.client.cacheHits}**');
  b.writeln('- Live calls ever made through this cache folder (from `cache/_call_log.jsonl`): **${r.client.cache.liveCallsEver()}**');
  final headerSums = <String, double>{};
  final headerCounts = <String, int>{};
  for (final c in r.calls) {
    c.headers.forEach((k, v) {
      final x = double.tryParse(v);
      if (x != null) {
        headerSums[k] = (headerSums[k] ?? 0) + x;
        headerCounts[k] = (headerCounts[k] ?? 0) + 1;
      }
    });
  }
  if (headerSums.isEmpty) {
    b.writeln('- The responses carried no timing or credit headers, so **credits used could not be measured here.**');
  } else {
    for (final k in headerSums.keys) {
      b.writeln('- Response header `$k`: total ${headerSums[k]!.toStringAsFixed(3)} over ${headerCounts[k]} calls (as reported by the server).');
    }
    b.writeln('- Turning those into credits needs Roboflow\'s pricing, which this harness does not assume.');
  }
  b.writeln('- **Credits used are not measured by this harness.** To get the real figure, note your Roboflow usage page before and after a run '
      'and compare it with the live-call count above.');
  b.writeln();

  // 9 ---------------------------------------------------------------
  b.writeln('## 9. Plain-language diagnosis (suggestions, not findings)');
  b.writeln();
  b.writeln('These apply simple rules to the numbers above. The thresholds are this harness\'s own choices: '
      'fewer than $kMinPerLabel photos = too few to judge; recall under ${(kLowRecall * 100).round()}% = low; '
      'more than ${(kHighFalseAlarm * 100).round()}% of clear photos alerting = high; '
      '90th-percentile call latency over $kSlowP90Ms ms, or more than ${(kTimeoutShare * 100).round()}% of calls over ${kAppTimeoutMs ~/ 1000} s = slow.');
  b.writeln();
  for (final line in buildDiagnosis(groups, r.rows, lat, r.minPerLabel, images)) {
    b.writeln('- $line');
  }
  b.writeln();

  // 10 --------------------------------------------------------------
  b.writeln('## 10. What this did NOT test');
  b.writeln();
  b.writeln('- **Real walking**: no user, no pace, no warning time. Whether an alert arrives early enough was not measured.');
  b.writeln('- **A moving camera**: motion blur, shake and a changing scene. Each photo is replayed as an unchanging scene, so frame-to-frame flicker and the 2-of-3-frame confirmation rule are barely exercised.');
  b.writeln('- **Lighting**: only what happens to be in the photos. Night, glare and shadow were not varied on purpose.');
  b.writeln('- **Phone hardware**: the real camera, its resolution and mount height. The distance model assumes an upright phone about ${r.settings.distanceModel.cameraHeightM} m up; photos taken any other way give distances (and range / path decisions) that do not match what the app would compute.');
  b.writeln('- **Phone latency**: timings are from this computer\'s network, not mobile data.');
  b.writeln('- **Speech and haptics**: wording was checked, not how it sounds or feels, and speech is assumed never to be mid-sentence.');
  b.writeln('- **The dark-camera and offline fail-safes** beyond noting which photos would trigger the dark one.');
  b.writeln();

  return b.toString();
}

String _perLabelSummary(List<EvalRow> rows) {
  final per = <String, Set<String>>{};
  for (final r in rows) {
    per.putIfAbsent(r.label, () => {}).add(r.image);
  }
  final keys = per.keys.toList()..sort();
  return keys.map((k) => '$k ${per[k]!.length}').join(', ');
}

List<String> buildDiagnosis(
  Map<String, GroupStats> groups,
  List<EvalRow> rows,
  List<LatencyStats> lat,
  int minPerLabel,
  int totalImages,
) {
  final out = <String>[];
  if (totalImages == 0) {
    return ['No photos were run, so there is nothing to diagnose.'];
  }
  if (totalImages < minPerLabel) {
    out.add('Only $totalImages photo(s) in total. That is too small a sample to tell anything reliable about any label.');
  }

  final smallHazard = <String>[];
  final smallClear = <String>[];
  for (final g in groups.values.where((g) => !g.isClear && isApplicable(g.label, g.mode)).toList()
    ..sort((a, b) => a.key.compareTo(b.key))) {
    if (g.tested == 0) continue;
    if (g.tested < minPerLabel) {
      smallHazard.add('${g.key} (${g.tested})');
      continue;
    }
    final recall = g.correct / g.tested;
    final misses = g.tested - g.correct;
    if (recall >= kLowRecall) {
      out.add('${g.key}: recall ${_pct(g.correct, g.tested)} (95% interval ${_ci(g.correct, g.tested)}); no recall problem seen in this sample.');
      continue;
    }
    final parts = <String>[];
    if (g.notSeen > 0) parts.add('${g.notSeen} not seen by the model');
    if (g.filtered > 0) parts.add('${g.filtered} seen but dropped by the pipeline');
    if (g.wrong > 0) parts.add('${g.wrong} alerted as something else');
    if (g.silent > 0) parts.add('${g.silent} silent by design');
    if (g.dark > 0) parts.add('${g.dark} too dark');
    final detail = 'recall ${_pct(g.correct, g.tested)} ($misses missed: ${parts.join(', ')}).';
    final modelRecall = g.modelSaw / g.tested;
    if (g.notSeen + g.wrong >= g.filtered + g.silent + g.dark && modelRecall < kLowRecall) {
      out.add('${g.key}: $detail Suggestion: the model itself is missing or mislabelling this class, which looks like a data problem '
          '(more or better training examples, ideally from your own phone).');
    } else if (g.filtered + g.silent > g.notSeen + g.wrong) {
      out.add('${g.key}: $detail Suggestion: the model usually found it (it saw it in ${g.modelSaw} of ${g.tested}), '
          'so this looks more like a range, path or threshold problem than a data problem. Check the photos were taken like the app takes them (upright, chest height).');
    } else {
      out.add('${g.key}: $detail Suggestion: recall is low; see the failure list for the mix of causes before deciding between a data fix and a threshold fix.');
    }
  }

  for (final g in groups.values.where((g) => g.isClear).toList()..sort((a, b) => a.key.compareTo(b.key))) {
    final denom = g.clearOk + g.falseAlarm;
    if (denom == 0) continue;
    if (denom < minPerLabel) {
      smallClear.add('clear/${g.mode.name} ($denom)');
      continue;
    }
    final rate = g.falseAlarm / denom;
    if (rate <= kHighFalseAlarm) {
      out.add('clear/${g.mode.name}: false-alarm rate ${_pct(g.falseAlarm, denom)} (95% interval ${_ci(g.falseAlarm, denom)}); not high in this sample.');
      continue;
    }
    final causes = <String, int>{};
    final confs = <double>[];
    for (final x in rows.where((x) => x.outcome == Outcome.falseAlarm && x.mode == g.mode)) {
      for (final a in x.alerts) {
        causes['${a.name} [${a.tag}]'] = (causes['${a.name} [${a.tag}]'] ?? 0) + 1;
        confs.add(a.conf);
      }
    }
    final top = (causes.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).take(3).map((e) => '${e.key} x${e.value}');
    confs.sort();
    out.add('clear/${g.mode.name}: false-alarm rate ${_pct(g.falseAlarm, denom)} (95% interval ${_ci(g.falseAlarm, denom)}). '
        'Most common: ${top.join(', ')}; confidences ${(confs.first * 100).round()}-${(confs.last * 100).round()}%. '
        'Suggestion: this looks like a threshold or class-filter problem (raise the confidence cut-off, or drop the classes that cause it).');
  }

  if (smallHazard.isNotEmpty) {
    out.add('Too few photos to judge recall (aim for $minPerLabel or more each; photos tested in brackets): ${smallHazard.join(', ')}.');
  }
  if (smallClear.isNotEmpty) {
    out.add('Too few clear photos to judge the false-alarm rate (aim for $minPerLabel or more each): ${smallClear.join(', ')}.');
  }

  final all = lat.isEmpty ? null : lat.first;
  if (all == null || all.n == 0) {
    out.add('Latency: no model calls were made, so it was not measured.');
  } else {
    final slow = all.p90 > kSlowP90Ms || all.overAppTimeout / all.n > kTimeoutShare;
    if (slow) {
      out.add('Latency: median ${all.med.round()} ms, 90th percentile ${all.p90} ms, max ${all.max} ms, ${all.overAppTimeout} of ${all.n} calls over ${kAppTimeoutMs ~/ 1000} s. '
          'Suggestion: this looks like a speed problem. The recognition can only help if it arrives while the hazard is still ahead; an on-device model would remove the network round trip. '
          '(Measured from this computer, not the phone.)');
    } else {
      out.add('Latency: median ${all.med.round()} ms, 90th percentile ${all.p90} ms; not the main issue from this computer. Phone latency over mobile data was not measured.');
    }
  }
  return out;
}

String buildNoDataReport({required int minPerLabel}) {
  final b = StringBuffer();
  b.writeln('# AHHA detector self-test report');
  b.writeln();
  b.writeln('**NO RESULTS. No photos were found in `tools/eval/images/<label>/`, so nothing was run and no API calls were made.**');
  b.writeln();
  b.writeln('To get results, add photos (the label is the folder name):');
  b.writeln();
  b.writeln('| folder | what goes in it |');
  b.writeln('|---|---|');
  b.writeln('| `stairs_down/` | stairs going down away from the camera |');
  b.writeln('| `stairs_up/` | stairs going up |');
  b.writeln('| `clear/` | scenes with NO hazard (measures false alarms), both outdoor and indoor |');
  b.writeln('| `car/` | a car, bus or truck in the path |');
  b.writeln('| `person/` | a pedestrian |');
  b.writeln('| `pothole/` | a pothole |');
  b.writeln('| `chair/` | a chair, desk or door (indoor mode) |');
  b.writeln();
  b.writeln('Aim for **at least $minPerLabel photos per folder**, including some taken on your own phone held upright at chest height, '
      'the way the app is used. Fewer than that is too few to say anything reliable.');
  b.writeln();
  b.writeln('Then run `dart tools/eval/run_eval.dart --plan` to see how many API calls it would make, and `dart tools/eval/run_eval.dart` to run it.');
  b.writeln();
  b.writeln('This file is overwritten by every run.');
  return b.toString();
}

String csvEscape(Object? v) {
  final s = v == null ? '' : '$v';
  return (s.contains(',') || s.contains('"') || s.contains('\n')) ? '"${s.replaceAll('"', '""')}"' : s;
}

String buildCsv(List<EvalRow> rows) {
  const header = [
    'photo', 'label', 'mode', 'outcome', 'expected_tags', 'spoken', 'alert_count', 'top_alert_tier', 'top_alert_tag',
    'top_alert_name', 'top_alert_conf', 'model_saw_expected', 'best_expected_conf', 'display_tag', 'display_dist_ft',
    'display_y', 'why', 'notes', 'brightness', 'width', 'height',
  ];
  final lines = <String>[header.join(',')];
  for (final r in rows) {
    final top = r.topAlert;
    lines.add([
      r.image, r.label, r.mode.name, r.outcome.name, kLabels[r.label]!.tags.join('+'), r.spokenText, r.alerts.length,
      top?.tier.name, top?.tag, top?.name, top?.conf.toStringAsFixed(2), r.modelSaw,
      r.bestExpectedConf?.toStringAsFixed(2), r.display?.tag, r.displayDist?.toStringAsFixed(1),
      r.display?.yMax.toStringAsFixed(2), r.why, r.notes.join('; '), r.luminance?.toStringAsFixed(0), r.width, r.height,
    ].map(csvEscape).join(','));
  }
  return lines.join('\n');
}
