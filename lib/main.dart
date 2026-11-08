import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_tts/flutter_tts.dart';
import 'package:vibration/vibration.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'alert_policy.dart';
import 'config.dart';
import 'detection_logic.dart';
import 'path_blocked.dart';

late List<CameraDescription> cameras;

// STREET runs stairs + general street objects + potholes (3 hosted calls per
// frame); INDOOR runs stairs + indoor obstacles (2). Each call uses Roboflow
// credits, so only the models a mode needs are called.
enum DetectMode { street, indoor }

// One hosted model and how to turn its raw class names into policy tags.
class _ModelSpec {
  const _ModelSpec({
    required this.id,
    required this.label,
    this.tagRename = const {},
    this.only,
    this.ignore = const {},
  });

  final String id;
  final String label; // short name for logs/UI
  final Map<String, String> tagRename;
  final Set<String>? only; // if set, every other class is dropped silently
  final Set<String> ignore; // dropped, but listed in the debug panel
}

// Replaced 2026-09: the original stairs-detection-0vnez/1 returned real test
// confidence of only 7-11% on genuine stairs photos. This model
// (stairs_detection-jaj7e/2, "school-0hlof" on Universe) verified at 32-65%
// confidence across 4 real test images, correct class names on every one.
// It returns "downstair"/"upstair" (singular, verified via live inference).
const _stairsSpec = _ModelSpec(
  id: "stairs_detection-jaj7e/2",
  label: "stairs",
  tagRename: {"downstair": "stairs_down", "upstair": "stairs_up"},
);

// Indoor obstacle class mapping — a deliberate scope decision, not a casing
// fix: Chair/Desk/Door are real collision/path hazards at walking pace.
// Bottle/Mug/Books/Laptop/Shoes pose no meaningful collision risk and are
// dropped — never dispatched, only surfaced in the debug panel — to protect
// the speech budget from clutter that wouldn't improve safety.
const _obstacleSpec = _ModelSpec(
  id: "obstacle-detection-meg7r/19",
  label: "obstacle",
  tagRename: {"Chair": "obstacle_low", "Desk": "obstacle_low", "Door": "obstacle_low"},
  ignore: {"Bottle", "Mug", "Books", "Laptop", "Shoes"},
);

// COCO (coco/50, Microsoft): 80 classes, 123k training images. On real
// photos it also emits junk (dining tables, chairs, a "bird" on a pothole
// photo), so this is an ALLOW-list of things that matter on a street.
// coco/3 was tried and rejected: it missed most of the people and cars that
// coco/50 found in the same photo.
const _streetSpec = _ModelSpec(
  id: "coco/50",
  label: "street",
  only: {"person", "bicycle", "motorcycle", "car", "bus", "truck", "dog", "bench", "fire hydrant"},
  tagRename: {
    "person": "person",
    "bicycle": "two_wheeler",
    "motorcycle": "vehicle",
    "car": "vehicle",
    "bus": "vehicle",
    "truck": "vehicle",
    "dog": "dog",
    "bench": "obstacle_low",
    "fire hydrant": "obstacle_low",
  },
);

// Georgia Tech pothole model (pothole-detection-mev9q/6): 99.99% on 3 of 3
// real pothole photos, and silent on a street photo with cars and people.
// Another pothole model tried (pothole-detection-1ptu6/12) managed only 25%.
const _potholeSpec = _ModelSpec(
  id: "pothole-detection-mev9q/6",
  label: "pothole",
  tagRename: {"pothole": "pothole"},
);

List<_ModelSpec> _specsFor(DetectMode m) =>
    m == DetectMode.street ? [_stairsSpec, _streetSpec, _potholeSpec] : [_stairsSpec, _obstacleSpec];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  cameras = await availableCameras();
  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: HazardAssistantScreen(),
  ));
}

// Top-level function required for compute() isolate offloading. Decodes the
// JPEG once to (a) bake any EXIF rotation into the pixels — CameraX records
// device rotation as a tag instead of rotating the image, and we can't
// assume the inference server honors that tag; a sideways frame would give
// random-looking detections and meaningless box positions — and (b) compute
// a 0-255 brightness proxy (NOT calibrated lux). The original bytes are
// returned untouched when no rotation is needed, to skip a re-encode.
Map<String, Object?> prepareFrameIsolate(Uint8List jpegBytes) {
  final decoded = img.decodeJpg(jpegBytes);
  if (decoded == null) return {'lum': 0.0, 'jpeg': jpegBytes, 'rotated': false, 'plainCb': null, 'plainAll': null};

  final ifd = decoded.exif.imageIfd;
  final needsBake = ifd.hasOrientation && ifd.orientation != null && ifd.orientation != 1;
  final upright = needsBake ? img.bakeOrientation(decoded) : decoded;

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
  // Label-free "plain wall" statistic. Only computed when that check is
  // switched on (it ships off, see lib/path_blocked.dart).
  double? plainCenterBottom;
  double? plainAll;
  if (kLabelFreeWallCheck) {
    final grid = img.copyResize(upright, width: 64, height: 48, interpolation: img.Interpolation.average);
    final gray = List<int>.filled(grid.width * grid.height, 0);
    for (int y = 0; y < grid.height; y++) {
      for (int x = 0; x < grid.width; x++) {
        final p = grid.getPixel(x, y);
        gray[y * grid.width + x] = (0.299 * p.r + 0.587 * p.g + 0.114 * p.b).round();
      }
    }
    final stats = plainStatsFromGray(gray, grid.width, grid.height);
    plainCenterBottom = stats.edgeFractionCenterBottom;
    plainAll = stats.edgeFractionAll;
  }
  return {
    'lum': count == 0 ? 0.0 : total / count,
    'jpeg': needsBake ? Uint8List.fromList(img.encodeJpg(upright, quality: 85)) : jpegBytes,
    'rotated': needsBake,
    'plainCb': plainCenterBottom,
    'plainAll': plainAll,
  };
}

// Static reference grid: two dashed vertical lines at the same 0.33/0.66
// fractional x-positions _processDetections uses to bucket left/center/
// right. Purely visual — always rendered, independent of detections.
class _ZoneGridPainter extends CustomPainter {
  const _ZoneGridPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.55)
      ..strokeWidth = 1.5;
    _drawDashedVerticalLine(canvas, size.width * 0.33, size.height, paint);
    _drawDashedVerticalLine(canvas, size.width * 0.66, size.height, paint);
  }

  void _drawDashedVerticalLine(Canvas canvas, double x, double height, Paint paint) {
    const dashHeight = 6.0;
    const dashGap = 5.0;
    double y = 0;
    while (y < height) {
      canvas.drawLine(Offset(x, y), Offset(x, math.min(y + dashHeight, height)), paint);
      y += dashHeight + dashGap;
    }
  }

  @override
  bool shouldRepaint(covariant _ZoneGridPainter oldDelegate) => false;
}

class HazardAssistantScreen extends StatefulWidget {
  const HazardAssistantScreen({super.key});
  @override
  State<HazardAssistantScreen> createState() => _HazardAssistantScreenState();
}

class _HazardAssistantScreenState extends State<HazardAssistantScreen> {
  CameraController? _cameraController;
  late FlutterTts _tts;

  bool _isReady = false;
  bool _isDetecting = false;
  bool _isMounted = true;
  // What each alert feels/sounds like, and which speech is suppressed.
  // speakBands: say "close ahead", never a number of feet - the distance
  // estimate is not trustworthy enough to read out.
  final AlertPolicy _policy = AlertPolicy(speakBands: true, criticalSpeechGap: const Duration(seconds: 3));
  // Evaluation record (copyable from the debug panel) for measuring cognitive
  // load, suppression, latency and fail-safe events after a session.
  final AlertLog _log = AlertLog();
  final PathBlockedDetector _blocked = PathBlockedDetector();
  AlertTier? _currentSpeakingTier;
  bool _inDegradedState = false; // camera dark/blocked
  Timer? _degradedChimeTimer;

  // Starts INDOOR: that's the behavior already field-tested. Switch to
  // STREET for cars, people and potholes.
  DetectMode _mode = DetectMode.indoor;
  bool _hasAmplitude = false;

  // Fail-safe for the worst failure: the app silently seeing nothing because
  // the network dropped or the API quota ran out, which looks exactly like
  // "no hazards". After a few frames where EVERY model call failed, tell the
  // user, then keep reminding by haptic until it recovers.
  int _failStreak = 0;
  bool _inOfflineState = false;
  Timer? _offlineTimer;
  String _lastHttpNote = "-";
  static const int _offlineAfterFrames = 3;
  static const String _offlinePhrase = "Detection offline. Use your cane.";
  static const String _restoredPhrase = "Detection restored.";

  // Control bar toggles (redesign item 5). These gate only the physical
  // output calls (_vibrate / _speak) — detection, tiering, debounce, and
  // interruption logic all keep running identically regardless.
  bool _hapticEnabled = true;
  bool _audioEnabled = true;
  bool _isPaused = false;

  // Secondary debug panel (tap-to-reveal) — inference time/model source/
  // ignored classes only. Raw distance is intentionally NOT here; it stays
  // always-visible in the camera area (see _distanceBadge) per correction:
  // it needs to be watchable continuously during the calibration walk, not
  // hidden behind a toggle.
  bool _showDebugPanel = false;

  // Live per-frame detection state — updated every frame regardless of
  // debounce/tier suppression, independent of whether an alert actually
  // dispatches. Drives the always-visible distance badge, the bounding-box
  // overlay, and (behind the tap toggle) the inference/model/ignored panel.
  String _dbgTag = "no detection";
  String _dbgLabel = "-";
  String _dbgTier = "-";
  String _dbgModel = "-";
  double? _dbgDistFt; // median-smoothed, UNRELIABLE: shown in the debug panel only
  Proximity? _dbgProximity; // the band that is shown on screen instead of a number
  bool _dbgClipped = false; // base out of frame: distance is "no farther than"
  double? _dbgConfidence;
  double? _dbgYMax; // raw box-bottom position — needed to recalibrate
  List<double>? _dbgBox; // normalized [x1, y1, x2, y2], 0..1
  int? _dbgInferenceMs;
  List<String> _dbgIgnored = [];
  List<int> _dbgFrameDims = []; // [w, h] the inference server actually saw
  bool _frameRotated = false; // an EXIF rotation had to be baked in
  int _dbgRawCount = 0;
  int _dbgConfirmedCount = 0;

  // Live status readout (redesign item 4) — always reflects the most recent
  // dispatch attempt, any tier, independent of the banner's critical/high
  // gating below.
  String _lastHapticDescription = "-";
  // The "Audio:" line. Only written when speech is really issued (alerts and
  // fail-safes alike), so it can never show stale or never-spoken text.
  final SpokenLine _spokenLine = SpokenLine();

  // High-priority visual hazard banner — data-driven from the same hazard
  // map _dispatchAlert built, not a separately-typed wording path. Timer
  // keeps it visible for a minimum window so it doesn't flicker with the
  // underlying detection.
  bool _bannerVisible = false;
  String _bannerLabel = "";
  String _bannerZone = "";
  int _bannerDist = 0;
  bool _bannerClipped = false;
  AlertTier? _bannerTier;
  Proximity _bannerProximity = Proximity.far;
  Timer? _bannerHideTimer;

  void _showHazardBanner({
    required String label,
    required String zone,
    required int dist,
    required bool clipped,
    required AlertTier tier,
    required Proximity proximity,
  }) {
    _bannerHideTimer?.cancel();
    if (mounted) {
      setState(() {
        _bannerVisible = true;
        _bannerLabel = label;
        _bannerZone = zone;
        _bannerDist = dist;
        _bannerClipped = clipped;
        _bannerTier = tier;
        _bannerProximity = proximity;
      });
    }
    _bannerHideTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _bannerVisible = false);
    });
  }

  // Fail-safe phrasing candidates for Tier 2 A/B testing — change the
  // index to switch which one fires during a session.
  // Index 0 is the live one. A black wall right against the lens looks the
  // same as a covered camera, so the wording works as a warning too: stop.
  static const List<String> _failSafePhrasings = [
    "Camera can't see ahead. Stop and check.",
    "Too dark to detect hazards. Use your cane.",
    "Vision degraded, check camera.",
  ];
  static const int _activeFailSafeIndex = 0;

  // Calibration — FIT FROM FIELD DATA, NOT FINAL. Two usable points (a 6 ft
  // door and a 10 ft object, phone held upright), assuming a 1.3 m camera
  // height that has not actually been measured, gave FOV ~63 deg and pitch
  // ~5.7 deg. The old 45 deg FOV / 12 deg pitch could not see the floor
  // closer than ~5.7 ft, so a 3 ft chair and a 6 ft door read identically.
  // With these values the closest visible floor is ~5.7 ft; anything closer
  // is reported as "clipped" (no farther than that) instead of a fake number.
  // yHorizon is left at 0.5 because it is redundant with pitch.
  // To refine: read yMax off the on-screen readout at taped marks and refit.
  static const DistanceModel _distanceModel = DistanceModel(
    cameraHeightM: 1.3,
    pitchDeg: 5.5,
    fovVDeg: 63.0,
    yHorizon: 0.5,
  );
  // kFieldPipelineConfig (lib/detection_logic.dart) holds every threshold
  // tuned from real phone testing, in one place.
  final DetectionPipeline _pipeline = DetectionPipeline(distanceModel: _distanceModel, config: kFieldPipelineConfig);
  final double _darknessThreshold = 40.0;

  // Models are called concurrently, one hosted call each. The API key lives
  // in config.dart (gitignored), not here.
  static const String _roboflowBaseUrl = "https://serverless.roboflow.com";

  @override
  void initState() {
    super.initState();
    _initEngine();
  }

  Future<void> _initEngine() async {
    _tts = FlutterTts();
    await _tts.setLanguage("en-US");
    await _tts.setSpeechRate(0.65);
    await _tts.setVolume(1.0);
    _tts.setCompletionHandler(() => _currentSpeakingTier = null);
    _tts.setCancelHandler(() => _currentSpeakingTier = null);
    try {
      _hasAmplitude = await Vibration.hasAmplitudeControl();
    } catch (_) {
      _hasAmplitude = false;
    }

    _cameraController = CameraController(
      cameras[0],
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
    await _cameraController!.initialize();
    setState(() => _isReady = true);
    _captureLoop();
  }

  // Gate for the physical vibration call — HAPTIC toggle only affects this.
  // Strength varies with proximity where the phone supports amplitude control;
  // otherwise only the rhythm can differ.
  void _vibrate(List<int> pattern, [List<int>? amplitudes]) {
    if (!_hapticEnabled || pattern.isEmpty) return;
    if (_hasAmplitude && amplitudes != null && amplitudes.length == pattern.length) {
      Vibration.vibrate(pattern: pattern, intensities: amplitudes);
    } else {
      Vibration.vibrate(pattern: pattern);
    }
  }

  // Self-scheduling loop instead of Timer.periodic — ensures a new
  // takePicture() call never fires before the previous one has fully
  // completed, avoiding shutter/I-O queueing and camera session crashes.
  Future<void> _captureLoop() async {
    while (_isMounted) {
      if (_isPaused || _isDetecting || _cameraController == null || !_cameraController!.value.isInitialized) {
        await Future.delayed(const Duration(milliseconds: 200));
        continue;
      }
      _isDetecting = true;
      final captureStart = DateTime.now();
      try {
        final shot = await _cameraController!.takePicture();
        final bytes = await shot.readAsBytes();
        await _runInference(bytes);
      } catch (e) {
        debugPrint("Frame capture error: $e");
      } finally {
        final elapsedMs = DateTime.now().difference(captureStart).inMilliseconds;
        _log.latency(elapsedMs);
        if (mounted) setState(() => _dbgInferenceMs = elapsedMs);
        _isDetecting = false;
      }
      await Future.delayed(const Duration(milliseconds: 400));
    }
  }

  Future<void> _runInference(Uint8List jpegBytes) async {
    final frame = await compute(prepareFrameIsolate, jpegBytes);
    final avgLuminance = frame['lum'] as double;
    final uprightJpeg = frame['jpeg'] as Uint8List;
    _frameRotated = frame['rotated'] as bool;
    if (avgLuminance < _darknessThreshold) {
      _enterDegradedState();
      return;
    }
    _exitDegradedStateIfNeeded();

    final ignored = <String>[];
    final frameDims = <int>[];
    final notes = <String>[];
    final rawBoxes = <List<double>>[]; // every detection of every class, for the path-blocked check
    final specs = _specsFor(_mode);
    final results = await Future.wait([
      for (final spec in specs)
        _fetchModelDetections(
          spec: spec,
          jpegBytes: uprightJpeg,
          ignoredOut: ignored,
          frameDimsOut: frameDims,
          noteOut: notes,
          rawBoxesOut: rawBoxes,
        ),
    ]);

    _lastHttpNote = notes.isEmpty ? "ok" : notes.join(", ");
    _dbgIgnored = ignored;
    _dbgFrameDims = frameDims;

    // Every call failing looks identical to "nothing in the way" — never let
    // that pass silently. A frame where at least one model answered is fine.
    final allFailed = results.every((r) => r == null);
    if (allFailed) {
      _failStreak++;
      if (_failStreak >= _offlineAfterFrames) _enterOfflineState();
      return; // don't feed the pipeline a fake "empty" frame
    }
    _failStreak = 0;
    _exitOfflineStateIfNeeded();

    final plainCb = frame['plainCb'] as double?;
    final plainAll = frame['plainAll'] as double?;
    _processDetections(
      [for (final r in results) ...?r],
      rawBoxes: rawBoxes,
      luminance: avgLuminance,
      plain: (plainCb != null && plainAll != null)
          ? PlainStats(edgeFractionCenterBottom: plainCb, edgeFractionAll: plainAll)
          : null,
    );
  }

  // One model call. Returns null when the call FAILED (network, timeout,
  // HTTP error) and an empty list when it succeeded and saw nothing — the
  // difference matters for the offline fail-safe. Errors are caught here so
  // one model being down never blocks the others in Future.wait.
  Future<List<Map<String, dynamic>>?> _fetchModelDetections({
    required _ModelSpec spec,
    required Uint8List jpegBytes,
    required List<String> ignoredOut,
    required List<int> frameDimsOut,
    required List<String> noteOut,
    required List<List<double>> rawBoxesOut,
  }) async {
    final modelLabel = spec.label;
    try {
      final response = await http.post(
        Uri.parse("$_roboflowBaseUrl/${spec.id}"),
        headers: {
          "Content-Type": "application/x-www-form-urlencoded",
          "Authorization": "Bearer $roboflowApiKey",
        },
        body: base64Encode(jpegBytes),
      ).timeout(const Duration(seconds: 3));

      if (response.statusCode != 200) {
        debugPrint("$modelLabel model HTTP ${response.statusCode}");
        // 401/402/403/429 are how a bad key or exhausted quota shows up.
        noteOut.add("$modelLabel HTTP ${response.statusCode}");
        return null;
      }
      final data = jsonDecode(response.body);
      final predictions = (data["predictions"] as List?) ?? [];
      final frameWidth = (data["image"]?["width"] as num?)?.toDouble() ?? 640.0;
      final frameHeight = (data["image"]?["height"] as num?)?.toDouble() ?? 480.0;
      frameDimsOut
        ..clear()
        ..addAll([frameWidth.round(), frameHeight.round()]);

      final out = <Map<String, dynamic>>[];
      for (final p in predictions) {
        final rawClass = p["class"] as String;
        // Class-agnostic copy for the path-blocked check: taken BEFORE the
        // allow/ignore lists, because a huge box of anything blocks the path.
        {
          final bx = (p["x"] as num).toDouble(), by = (p["y"] as num).toDouble();
          final bw = (p["width"] as num).toDouble(), bh = (p["height"] as num).toDouble();
          rawBoxesOut.add([
            (bx - bw / 2) / frameWidth,
            (by - bh / 2) / frameHeight,
            (bx + bw / 2) / frameWidth,
            (by + bh / 2) / frameHeight,
            (p["confidence"] as num).toDouble(),
          ]);
        }
        if (spec.only != null && !spec.only!.contains(rawClass)) continue;
        if (spec.ignore.contains(rawClass)) {
          ignoredOut.add(rawClass);
          continue;
        }
        final tag = spec.tagRename[rawClass] ?? rawClass;
        // Keep the specific class for display/speech ("chair", "car", not
        // the generic policy tag); stairs use their policy name.
        final label = modelLabel == "stairs" ? tag.replaceAll("_", " ") : rawClass.toLowerCase();
        final x = (p["x"] as num).toDouble();
        final y = (p["y"] as num).toDouble();
        final w = (p["width"] as num).toDouble();
        final h = (p["height"] as num).toDouble();
        out.add({
          "box": [
            (x - w / 2) / frameWidth,
            (y - h / 2) / frameHeight,
            (x + w / 2) / frameWidth,
            (y + h / 2) / frameHeight,
            (p["confidence"] as num).toDouble(),
          ],
          "tag": tag,
          "label": label,
          "model": modelLabel,
        });
      }
      return out;
    } catch (e) {
      debugPrint("$modelLabel model request failed: $e");
      noteOut.add("$modelLabel failed");
      return null;
    }
  }

  // BUG FIX: previously re-spoke the full fail-safe phrase every 3s for as
  // long as the degraded state persisted. Now: speak the full phrase once
  // on entry, then only a haptic "still degraded" reminder every 5s. The
  // full phrase speaks again only on a fresh degraded event (state must
  // clear via _exitDegradedStateIfNeeded first).
  void _enterDegradedState() {
    if (_inDegradedState) return;
    _inDegradedState = true;
    _log.failsafe("camera_dark", on: true, now: DateTime.now());

    _vibrate([0, 200, 150, 200]);
    _lastHapticDescription = "DEGRADED VISION PULSE";
    final phrase = _failSafePhrasings[_activeFailSafeIndex];
    _spokenLine.record(phrase, audible: _audioEnabled);
    _policy.forgetAnnounced(); // the fail-safe spoke in between: re-announce hazards
    _speak(phrase);

    _degradedChimeTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _vibrate([0, 200, 150, 200]);
    });
    if (mounted) setState(() {});
  }

  void _exitDegradedStateIfNeeded() {
    if (!_inDegradedState) return;
    _inDegradedState = false;
    _log.failsafe("camera_dark", on: false, now: DateTime.now());
    _degradedChimeTimer?.cancel();
    if (mounted) setState(() {});
  }

  // Same shape as the dark-camera fail-safe: say it once in full, then only a
  // quiet haptic reminder every 5 s, and announce recovery once.
  void _enterOfflineState() {
    if (_inOfflineState) return;
    _inOfflineState = true;
    _log.failsafe("detection_offline", on: true, now: DateTime.now());
    _vibrate([0, 200, 150, 200]);
    _lastHapticDescription = "OFFLINE REMINDER PULSE";
    _spokenLine.record(_offlinePhrase, audible: _audioEnabled);
    _policy.forgetAnnounced();
    _speak(_offlinePhrase);
    _offlineTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _vibrate([0, 200, 150, 200]);
    });
    if (mounted) setState(() {});
  }

  void _exitOfflineStateIfNeeded() {
    if (!_inOfflineState) return;
    _inOfflineState = false;
    _log.failsafe("detection_offline", on: false, now: DateTime.now());
    _offlineTimer?.cancel();
    _spokenLine.record(_restoredPhrase, audible: _audioEnabled);
    _policy.forgetAnnounced();
    _speak(_restoredPhrase);
    if (mounted) setState(() {});
  }

  // All the filtering, distance, tiering, multi-frame confirmation and
  // debounce lives in DetectionPipeline (lib/detection_logic.dart, unit
  // tested). This just applies its result to the UI and dispatches alerts.
  void _processDetections(
    List<Map<String, dynamic>> results, {
    List<List<double>> rawBoxes = const [],
    double luminance = 255,
    PlainStats? plain,
  }) {
    final now = DateTime.now();
    final r = _pipeline.process(results, now);

    // Priority: critical hazard (stairs down / vehicle) > path blocked >
    // everything else. Only one thing is dispatched per frame, so only one
    // speech starts. Path blocked stays quiet when a critical alert is going
    // out, or when a labelled hazard already covers the walking lane.
    final critical = r.alert?.tier == AlertTier.critical;
    final blocked = _blocked.update(
      boxes: rawBoxes,
      plain: plain,
      luminance: luminance,
      now: now,
      laneCoveredByLabel: r.centerCovered,
      criticalActive: critical,
    );
    if (blocked != null) {
      _dispatchAlert(blockedPathCandidate());
    } else if (r.alert != null) {
      _dispatchAlert(r.alert!);
    }

    final d = r.display;
    _dbgRawCount = r.rawCount;
    _dbgConfirmedCount = r.confirmedCount;
    if (d != null) {
      _dbgTag = d.tag;
      _dbgLabel = d.label;
      _dbgTier = d.tier.name;
      _dbgDistFt = r.displayDistFeet;
      _dbgProximity = d.proximity;
      _dbgClipped = d.clipped;
      _dbgConfidence = d.conf;
      _dbgYMax = d.yMax;
      _dbgBox = d.box;
      _dbgModel = d.model;
    } else {
      _dbgTag = "no detection";
      _dbgLabel = "-";
      _dbgTier = "-";
      _dbgDistFt = null;
      _dbgProximity = null;
      _dbgClipped = false;
      _dbgConfidence = null;
      _dbgYMax = null;
      _dbgBox = null;
      _dbgModel = "-";
    }
  }

  static const TtsSpec _neutralVoice = TtsSpec(rate: 0.65, pitch: 1.0, volume: 1.0);

  // Gate for the physical TTS call — AUDIO toggle only affects this. Voice
  // (rate/pitch/volume) scales with proximity: closer sounds faster, higher
  // and louder. Fail-safe phrases use the neutral voice.
  Future<void> _speak(String text, [TtsSpec voice = _neutralVoice]) async {
    if (!_audioEnabled) return;
    await _tts.setSpeechRate(voice.rate);
    await _tts.setPitch(voice.pitch);
    await _tts.setVolume(voice.volume);
    await _tts.speak(text);
  }

  // What to do for one dispatched hazard is decided by AlertPolicy (wording,
  // haptic strength, voice, and which speech to withhold for cognitive load);
  // this just carries it out on the phone.
  Future<void> _dispatchAlert(Candidate hazard) async {
    final now = DateTime.now();
    final tier = hazard.tier;

    // Interruption rules: critical preempts everything currently speaking;
    // high preempts a playing medium; anything else waits its turn (its
    // haptic still fires, and it speaks on a later frame).
    final currentTier = _currentSpeakingTier;
    final preempts = tier == AlertTier.critical || (tier == AlertTier.high && currentTier == AlertTier.medium);
    final busy = _audioEnabled &&
        !preempts &&
        currentTier != null &&
        tierPriority(currentTier) >= tierPriority(tier);

    final out = _policy.decide(hazard, now, ttsBusy: busy);

    // Haptics always fire — they are the quiet "still there" channel.
    _vibrate(out.haptic.pattern, out.haptic.amplitudes);
    _lastHapticDescription = out.haptic.description;
    _log.alert(out, now, hapticFired: _hapticEnabled);

    // Visual banner: built from the same hazard, not a second wording path.
    if (tier == AlertTier.critical || tier == AlertTier.high) {
      _showHazardBanner(
        label: hazard.label,
        zone: hazard.zone,
        dist: hazard.distFeet.round(),
        clipped: hazard.clipped,
        tier: tier,
        proximity: hazard.proximity,
      );
    }

    if (!out.speak) {
      debugPrint("ALERT [$tier] speech withheld (${out.suppressedReason}): ${out.speech}");
      if (mounted) setState(() {});
      return;
    }

    // Status readout shows the latest utterance; with AUDIO off it is marked
    // "(audio off)" so it is never mistaken for something actually said.
    _spokenLine.record(out.speech, audible: _audioEnabled);
    if (mounted) setState(() {});
    if (!_audioEnabled) return;

    if (preempts && currentTier != null) await _tts.stop();
    _currentSpeakingTier = tier;
    await _speak(out.speech, out.tts);
    debugPrint("ALERT [$tier]: ${out.speech}");
  }

  // Switching mode changes which hosted models are called, so drop all the
  // per-hazard history that belonged to the old ones.
  void _toggleMode() {
    setState(() {
      _mode = _mode == DetectMode.street ? DetectMode.indoor : DetectMode.street;
      _pipeline.reset();
      _blocked.reset();
      _policy.reset();
      _dbgTag = "no detection";
      _dbgLabel = "-";
      _dbgTier = "-";
      _dbgDistFt = null;
      _dbgBox = null;
      _dbgConfidence = null;
      _dbgYMax = null;
      _dbgModel = "-";
      _dbgClipped = false;
      _lastHapticDescription = "-";
      _spokenLine.clear();
    });
  }

  Future<void> _copyLog() async {
    final csv = _log.toCsv();
    await Clipboard.setData(ClipboardData(text: csv));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("Copied ${_log.events.length} log events. Paste them into a note or message.")),
    );
  }

  void _showSettingsDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Settings"),
        content: const Text("Settings coming soon."),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text("OK")),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _isMounted = false;
    _cameraController?.dispose();
    _tts.stop();
    _degradedChimeTimer?.cancel();
    _offlineTimer?.cancel();
    _bannerHideTimer?.cancel();
    super.dispose();
  }

  Widget _topBar() {
    return Container(
      width: double.infinity,
      color: (_inDegradedState || _inOfflineState) ? Colors.red.shade900 : Colors.black,
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        children: [
          const Text(
            "AHHA",
            style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold, letterSpacing: 3),
          ),
          const SizedBox(height: 2),
          Text(
            _inOfflineState
                ? "DETECTION OFFLINE"
                : _inDegradedState
                    ? "VISION DEGRADED"
                    : "HAZARD DETECTION ACTIVE - ${_mode.name.toUpperCase()}",
            style: TextStyle(
              color: (_inDegradedState || _inOfflineState) ? Colors.red.shade100 : Colors.greenAccent,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
            ),
          ),
        ],
      ),
    );
  }

  Widget _zoneLabel(String text) {
    return Text(
      text,
      style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1),
    );
  }

  static String _bandName(Proximity? p) => switch (p) {
        Proximity.veryNear => 'VERY NEAR',
        Proximity.near => 'NEAR',
        Proximity.far => 'FAR',
        null => '-',
      };

  // Always visible. Shows a BAND (very near / near / far), not a number: the
  // estimate was seen over-reading by ~1.5x, so a precise figure would be
  // false precision. The one exception is a box touching the bottom of the
  // frame, where the honest statement is "no farther than X ft". The raw
  // estimate and y stay in the debug panel for recalibration.
  Widget _distanceBadge() {
    final d = _dbgDistFt;
    final distText = d == null
        ? '-'
        : _dbgClipped
            ? '≤ ${d.toStringAsFixed(1)} ft (closer than camera can see)'
            : _bandName(_dbgProximity);
    final detail = d == null
        ? 'no detection'
        : '${_dbgLabel.toUpperCase()}  ${_dbgConfidence != null ? (_dbgConfidence! * 100).round() : 0}%'
            '  y=${_dbgYMax?.toStringAsFixed(2) ?? '-'}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.55), borderRadius: BorderRadius.circular(4)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            "Distance: $distText",
            style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
          ),
          Text(detail, style: const TextStyle(color: Colors.white70, fontSize: 11)),
        ],
      ),
    );
  }

  // Positions a labeled box at the current best detection's actual location.
  // NOTE: this maps normalized box coordinates directly onto the displayed
  // Stack area — a reasonable approximation, not a pixel-exact transform,
  // since it doesn't account for CameraPreview's own aspect-ratio fit
  // against the sensor's actual output size.
  Widget _boundingBoxOverlay(double areaWidth, double areaHeight) {
    final box = _dbgBox!;
    final left = box[0] * areaWidth;
    final top = box[1] * areaHeight;
    final w = ((box[2] - box[0]) * areaWidth).clamp(0.0, areaWidth);
    final h = ((box[3] - box[1]) * areaHeight).clamp(0.0, areaHeight);
    final confPct = _dbgConfidence != null ? (_dbgConfidence! * 100).round() : 0;
    return Positioned(
      left: left,
      top: top,
      width: w,
      height: h,
      child: Container(
        decoration: BoxDecoration(border: Border.all(color: Colors.redAccent, width: 2)),
        child: Align(
          alignment: Alignment.topLeft,
          child: Container(
            color: Colors.redAccent,
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Text(
              "${_dbgLabel.toUpperCase()}\nConfidence $confPct%",
              style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
            ),
          ),
        ),
      ),
    );
  }

  Widget _cameraArea() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        return Stack(
          fit: StackFit.expand,
          children: [
            CameraPreview(_cameraController!),
            const Positioned.fill(child: CustomPaint(painter: _ZoneGridPainter())),
            Positioned(
              top: 8,
              left: 0,
              right: 0,
              child: Row(
                children: [
                  Expanded(child: Center(child: _zoneLabel("LEFT"))),
                  Expanded(child: Center(child: _zoneLabel("CENTER"))),
                  Expanded(child: Center(child: _zoneLabel("RIGHT"))),
                ],
              ),
            ),
            Positioned(top: 34, left: 8, child: _distanceBadge()),
            if (_dbgBox != null) _boundingBoxOverlay(w, h),
          ],
        );
      },
    );
  }

  Widget _hazardBanner() {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: _bannerTier == AlertTier.critical ? Colors.red.shade900 : Colors.amber.shade800,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 36),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _bannerLabel.toUpperCase(),
                  style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                ),
                Text(
                  _bannerDist <= 0
                      ? _bannerZone.toUpperCase() // path blocked: no distance
                      : _bannerClipped
                          ? "${_bannerZone.toUpperCase()} - UNDER $_bannerDist FT"
                          : "${_bannerZone.toUpperCase()} - ${_bandName(_bannerProximity)}",
                  style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                const Text(
                  "IMMEDIATE WARNING",
                  style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold, letterSpacing: 1),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusLines() {
    return Container(
      width: double.infinity,
      color: Colors.grey.shade900,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "Haptic Pattern: $_lastHapticDescription",
            style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            'Audio: "${_spokenLine.text}"',
            style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  Widget _controlButton({
    required String label,
    required bool active,
    required VoidCallback onTap,
    bool fullWidth = false,
  }) {
    final button = OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        backgroundColor: active ? Colors.green.shade800 : Colors.grey.shade800,
        side: BorderSide(color: active ? Colors.greenAccent : Colors.grey),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      ),
      child: Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
    );
    return fullWidth ? SizedBox(width: double.infinity, child: button) : button;
  }

  Widget _controlBar() {
    return Container(
      width: double.infinity,
      color: Colors.black,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _controlButton(
                label: _hapticEnabled ? "HAPTIC ON" : "HAPTIC OFF",
                active: _hapticEnabled,
                onTap: () => setState(() => _hapticEnabled = !_hapticEnabled),
              ),
              _controlButton(
                label: _audioEnabled ? "AUDIO ON" : "AUDIO OFF",
                active: _audioEnabled,
                onTap: () => setState(() => _audioEnabled = !_audioEnabled),
              ),
              _controlButton(
                label: _isPaused ? "RESUME" : "PAUSE",
                active: !_isPaused,
                onTap: () => setState(() {
                  _isPaused = !_isPaused;
                  // Stale multi-frame history must not carry across a pause.
                  if (!_isPaused) {
                    _pipeline.reset();
                    _blocked.reset();
                  }
                }),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _controlButton(
                label: _mode == DetectMode.street ? "MODE: STREET" : "MODE: INDOOR",
                active: true,
                onTap: _toggleMode,
              ),
              _controlButton(label: "SETTINGS", active: true, onTap: _showSettingsDialog),
            ],
          ),
        ],
      ),
    );
  }

  Widget _debugPanel() {
    final now = DateTime.now();
    final median = _log.medianLatencyMs();
    final suppressed = _log.suppressionCounts();
    return Positioned(
      top: 40,
      right: 6,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.75), borderRadius: BorderRadius.circular(6)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              "Mode: ${_mode.name}  (${_specsFor(_mode).map((s) => s.label).join(' + ')})\n"
              "Speech: ${_policy.utterancesLastMinute(now)}/min now, peak ${_log.peakUtterancesPerMinute()} (budget 12)\n"
              "Withheld: ${suppressed.isEmpty ? '-' : suppressed.entries.map((e) => '${e.key} ${e.value}').join(', ')}\n"
              "Inference: ${_dbgInferenceMs != null ? '$_dbgInferenceMs ms' : '-'}"
              "${median != null ? ' (median $median ms)' : ''}\n"
              "Network: $_lastHttpNote${_failStreak > 0 ? ' (fail streak $_failStreak)' : ''}\n"
              "Vibration strength control: ${_hasAmplitude ? 'yes' : 'NO (rhythm only)'}\n"
              "Model: $_dbgModel\n"
              "Tag/Tier: $_dbgTag ($_dbgTier)\n"
              "Est. distance: ${_dbgDistFt != null ? '${_dbgDistFt!.toStringAsFixed(1)} ft (unreliable)' : '-'}"
              "  y=${_dbgYMax?.toStringAsFixed(2) ?? '-'}\n"
              "Candidates: $_dbgRawCount seen / $_dbgConfirmedCount confirmed\n"
              "Server saw: ${_dbgFrameDims.length == 2 ? '${_dbgFrameDims[0]}x${_dbgFrameDims[1]}' : '-'}"
              "${_frameRotated ? ' (rotation fixed)' : ''}\n"
              "Ignored: ${_dbgIgnored.isEmpty ? '-' : _dbgIgnored.join(', ')}",
              style: const TextStyle(color: Colors.white, fontSize: 11),
            ),
            const SizedBox(height: 6),
            OutlinedButton(
              onPressed: _copyLog,
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.white54),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                minimumSize: Size.zero,
              ),
              child: const Text("COPY SESSION LOG", style: TextStyle(color: Colors.white, fontSize: 11)),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_isReady || _cameraController == null) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator(color: Colors.white)),
      );
    }
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                _topBar(),
                Expanded(child: _cameraArea()),
                if (_bannerVisible) _hazardBanner(),
                _statusLines(),
                _controlBar(),
              ],
            ),
            Positioned(
              top: 4,
              right: 4,
              child: IconButton(
                icon: const Icon(Icons.info_outline, color: Colors.white70),
                onPressed: () => setState(() => _showDebugPanel = !_showDebugPanel),
              ),
            ),
            if (_showDebugPanel) _debugPanel(),
          ],
        ),
      ),
    );
  }
}
