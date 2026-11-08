import 'dart:async';

import 'package:flutter/services.dart'; // also provides Uint8List

// On-device furniture detector (Google MediaPipe Object Detector,
// EfficientDet-Lite0, COCO labels) running next to the Roboflow models. It runs
// in Kotlin (android/.../MainActivity.kt) behind a MethodChannel; everything
// that decides what its output MEANS lives here in Dart so it can be tested
// with a fake source.
//
// It is strictly additive: any failure, timeout or missing platform just means
// "no extra detections this frame". It never raises an alert about itself.

/// Name of the source in a detection's `model` key (see PipelineConfig.minConfByModel).
const String kDeviceModelName = 'device';

/// Minimum confidence for the furniture classes (everything else in the app
/// keeps PipelineConfig.minConf = 0.40).
const double kFurnitureMinConf = 0.30;

/// COCO label -> (policy tag, spoken label). Only these are kept. All are
/// `obstacle_low`, i.e. severity 2 with the existing distance and haptic rules.
const Map<String, ({String tag, String label})> kFurnitureLabels = {
  'chair': (tag: 'obstacle_low', label: 'chair'),
  'dining table': (tag: 'obstacle_low', label: 'table'),
  'couch': (tag: 'obstacle_low', label: 'couch'),
  'bed': (tag: 'obstacle_low', label: 'bed'),
  'tv': (tag: 'obstacle_low', label: 'tv'),
  'potted plant': (tag: 'obstacle_low', label: 'plant'),
};

/// One raw detection from the platform side, normalised 0..1, top-left origin.
class DeviceBox {
  const DeviceBox({
    required this.label,
    required this.score,
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
  });

  final String label;
  final double score;
  final double x1, y1, x2, y2;

  factory DeviceBox.fromMap(Map<dynamic, dynamic> m) => DeviceBox(
        label: (m['label'] as String).toLowerCase(),
        score: (m['score'] as num).toDouble(),
        x1: (m['x1'] as num).toDouble(),
        y1: (m['y1'] as num).toDouble(),
        x2: (m['x2'] as num).toDouble(),
        y2: (m['y2'] as num).toDouble(),
      );
}

/// Where raw detections come from. The real one is [PlatformFurnitureSource];
/// tests use a fake.
abstract class FurnitureSource {
  Future<List<DeviceBox>> detect(Uint8List jpeg);
}

class PlatformFurnitureSource implements FurnitureSource {
  static const MethodChannel _channel = MethodChannel('ahha/furniture');

  @override
  Future<List<DeviceBox>> detect(Uint8List jpeg) async {
    final raw = await _channel.invokeMethod<List<dynamic>>('detect', {'jpeg': jpeg});
    return [for (final m in raw ?? const []) DeviceBox.fromMap(m as Map)];
  }
}

/// Keeps only the furniture classes at >= 0.30 and converts them to the map
/// format DetectionPipeline takes (same shape the Roboflow code produces).
List<Map<String, dynamic>> furnitureDetections(List<DeviceBox> boxes) {
  final out = <Map<String, dynamic>>[];
  for (final b in boxes) {
    final k = kFurnitureLabels[b.label];
    if (k == null || b.score < kFurnitureMinConf) continue;
    out.add({
      'box': [b.x1, b.y1, b.x2, b.y2, b.score],
      'tag': k.tag,
      'label': k.label,
      'model': kDeviceModelName,
    });
  }
  return out;
}

/// Intersection over union of two [x1, y1, x2, y2, ...] boxes.
double iou(List<double> a, List<double> b) {
  final ix = (a[2] < b[2] ? a[2] : b[2]) - (a[0] > b[0] ? a[0] : b[0]);
  final iy = (a[3] < b[3] ? a[3] : b[3]) - (a[1] > b[1] ? a[1] : b[1]);
  if (ix <= 0 || iy <= 0) return 0;
  final inter = ix * iy;
  final union = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter;
  return union <= 0 ? 0 : inter / union;
}

/// Merges on-device detections into the Roboflow ones. A pair counts as the
/// same object when it has the same policy tag and IoU > [iouThreshold]; the
/// one with the higher confidence is kept. Everything else is kept as is.
List<Map<String, dynamic>> mergeDetections(
  List<Map<String, dynamic>> roboflow,
  List<Map<String, dynamic>> device, {
  double iouThreshold = 0.5,
}) {
  List<double> boxOf(Map<String, dynamic> d) => [for (final v in d['box'] as List) (v as num).toDouble()];
  final merged = [...roboflow];
  for (final d in device) {
    final db = boxOf(d);
    var duplicateOf = -1;
    for (var i = 0; i < merged.length; i++) {
      if (merged[i]['tag'] != d['tag']) continue;
      if (iou(boxOf(merged[i]), db) > iouThreshold) {
        duplicateOf = i;
        break;
      }
    }
    if (duplicateOf < 0) {
      merged.add(d);
    } else if (db[4] > boxOf(merged[duplicateOf])[4]) {
      merged[duplicateOf] = d;
    }
  }
  return merged;
}

/// Wraps a [FurnitureSource] so it can never hurt the app: errors, a missing
/// platform side and slow answers all become "no detections" (null), and after
/// [maxConsecutiveFailures] failures in a row it stops being called at all
/// until [reset]. Nothing here speaks or vibrates.
class GuardedFurnitureDetector {
  GuardedFurnitureDetector(
    this.source, {
    this.timeout = const Duration(milliseconds: 1500),
    this.maxConsecutiveFailures = 3,
  });

  final FurnitureSource source;
  final Duration timeout;
  final int maxConsecutiveFailures;

  int _failures = 0;
  bool _inFlight = false; // a timed-out call may still be running on the platform side
  int skippedBusy = 0; // frames skipped because the previous call had not finished
  int? lastMs; // how long the last successful call took (shown in the debug panel)

  bool get disabled => _failures >= maxConsecutiveFailures;

  String get status => disabled
      ? 'off (failed $_failures x)'
      : lastMs != null
          ? 'ok $lastMs ms'
          : (_failures > 0 ? 'retrying ($_failures failed)' : 'waiting');

  void reset() {
    _failures = 0;
    lastMs = null;
    skippedBusy = 0;
  }

  /// Merge-ready detections, or null when unavailable this frame.
  Future<List<Map<String, dynamic>>?> detect(Uint8List jpeg) async {
    if (disabled) return null;
    if (_inFlight) {
      // Do not stack requests behind a slow one; just carry on without it.
      skippedBusy++;
      return null;
    }
    _inFlight = true;
    final started = DateTime.now();
    final call = Future<List<DeviceBox>>.sync(() => source.detect(jpeg)); // a synchronous throw becomes a failed future
    // Whatever happens to the caller's timeout, the call is "in flight" until
    // the platform side really finishes.
    unawaited(call.then((_) {}, onError: (_) {}).whenComplete(() => _inFlight = false));
    try {
      final boxes = await call.timeout(timeout);
      lastMs = DateTime.now().difference(started).inMilliseconds;
      _failures = 0;
      return furnitureDetections(boxes);
    } catch (_) {
      // TimeoutException, PlatformException, MissingPluginException, bad data...
      _failures++;
      return null;
    }
  }
}
