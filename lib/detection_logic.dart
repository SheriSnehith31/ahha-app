import 'dart:math' as math;

// Alert Design & Evaluation Plan (docs/alert_design.md).
// `info` = shown on screen but never spoken or vibrated.
enum AlertTier { critical, high, medium, info }

int tierPriority(AlertTier t) => switch (t) {
      AlertTier.critical => 3,
      AlertTier.high => 2,
      AlertTier.medium => 1,
      AlertTier.info => 0,
    };

// How close a hazard is, in the only terms the camera can actually resolve:
// veryNear includes anything whose base is out of frame (closer than the
// camera can see the floor).
enum Proximity { veryNear, near, far }

// How dangerous a hazard type is if you walk into it (3 = worst).
const Map<String, int> kHazardSeverity = {
  'stairs_down': 3, // drop-off
  'vehicle': 3, // car, bus, truck, motorcycle
  'stairs_up': 2,
  'obstacle_low': 2, // chair, desk, door, bench, hydrant
  'pothole': 2,
  'two_wheeler': 2, // bicycle
  'person': 1,
  'dog': 1,
};

// Proximity x severity x "is it in my walking path" -> alert tier.
// null = not worth showing at all (off-path and not dangerous enough).
AlertTier? classifyTier({
  required String tag,
  required Proximity proximity,
  required String zone,
}) {
  final sev = kHazardSeverity[tag] ?? 1;

  if (zone != 'center') {
    // Off the walking path: only drops and vehicles, and only when close.
    if (sev < 3) return null;
    return switch (proximity) {
      Proximity.veryNear => AlertTier.high,
      Proximity.near => AlertTier.medium,
      Proximity.far => null,
    };
  }

  return switch (sev) {
    3 => switch (proximity) {
        Proximity.veryNear => AlertTier.critical,
        Proximity.near => AlertTier.high,
        Proximity.far => AlertTier.medium,
      },
    2 => switch (proximity) {
        Proximity.veryNear => AlertTier.high,
        Proximity.near => AlertTier.medium,
        Proximity.far => AlertTier.medium,
      },
    // People/dogs: only worth interrupting for when nearly touching, or a
    // busy sidewalk turns into constant speech.
    _ => switch (proximity) {
        Proximity.veryNear => AlertTier.medium,
        Proximity.near => AlertTier.info,
        Proximity.far => AlertTier.info,
      },
  };
}

// Flat-ground pinhole model: a point on the floor at horizontal distance d
// sits (atan(H/d)) below the horizon. Image y (0 = top, 1 = bottom) maps
// linearly to that angle around the optical axis, which is tilted pitchDeg
// below horizontal. NOTE pitchDeg and yHorizon are redundant (moving one is
// the same as moving the other) — keep yHorizon at 0.5 and tune pitchDeg.
class DistanceModel {
  const DistanceModel({
    required this.cameraHeightM,
    required this.pitchDeg,
    required this.fovVDeg,
    this.yHorizon = 0.5,
  });

  final double cameraHeightM;
  final double pitchDeg;
  final double fovVDeg;
  final double yHorizon;

  static const double metersToFeet = 3.28084;

  double angleDeg(double yNorm) => pitchDeg + (yNorm - yHorizon) * fovVDeg;

  // Null when the point is at/above the horizon (unbounded distance).
  double? distanceFeet(double yNorm) {
    final a = angleDeg(yNorm);
    if (a <= 0.5) return null;
    return cameraHeightM * metersToFeet / math.tan(math.min(a, 89.0) * math.pi / 180.0);
  }

  // Nearest floor the camera can see: the bottom edge of the frame. Anything
  // closer than this has its base out of frame, so its distance cannot be
  // measured from ground contact — only bounded ("no farther than this").
  double get floorFeet => distanceFeet(1.0) ?? double.infinity;
}

class Candidate {
  const Candidate({
    required this.tag,
    required this.label,
    required this.zone,
    required this.model,
    required this.distFeet,
    required this.clipped,
    required this.proximity,
    required this.severity,
    required this.tier,
    required this.conf,
    required this.box,
    required this.yMax,
  });

  final String tag; // policy tag: stairs_down / vehicle / pothole / person ...
  final String label; // human-readable class: "stairs down", "car", ...
  final String zone;
  final String model;
  final double distFeet; // when clipped, this is an upper bound (the floor)
  final bool clipped;
  final Proximity proximity;
  final int severity;
  final AlertTier tier;
  final double conf;
  final List<double> box; // normalized [x1, y1, x2, y2]
  final double yMax;

  int get priority => tierPriority(tier);
}

class PipelineConfig {
  const PipelineConfig({
    this.minConf = 0.40,
    this.maxDistFeet = 10.0,
    // Proximity bands. At ~3-4.5 ft/s walking speed, 7 ft is only ~1.5-2 s
    // of warning, so "very near" is deliberately generous.
    this.veryNearFeet = 7.0,
    this.nearFeet = 8.5,
    this.clipYMax = 0.985,
    this.confirmWindow = 3,
    this.confirmNeeded = 2,
    // Severity-3 hazards (drops, vehicles) seen this confidently skip the
    // 2-frame wait: at ~1 frame/s a confirmation delay costs ~4 ft of
    // walking. Set above 1.0 to disable (trust vs. timeliness lever).
    this.fastPathConf = 0.85,
    this.holdFrames = 2,
    this.smoothWindow = 3,
    // Minimum gap between dispatches of the same hazard type. Shorter when
    // closer, so the haptic "heartbeat" speeds up as you approach.
    this.debounceVeryNear = const Duration(seconds: 1),
    this.debounceNear = const Duration(seconds: 2),
    this.debounceFar = const Duration(seconds: 3),
    // Stricter confirmation for hazards below severity 3 (chairs, desks,
    // stairs up, people ...). Severity-3 hazards (stairs down, vehicles) always
    // use confirmWindow/confirmNeeded and the fast path above, so they are
    // never made slower by this.
    this.lowSevConfirmWindow = 3,
    this.lowSevConfirmNeeded = 2,
    // Per-hazard confidence floors, applied on top of minConf (the higher wins).
    this.minConfByTag = const {},
    this.minConfByLabel = const {},
  });

  final double minConf;
  final double maxDistFeet;
  final double veryNearFeet;
  final double nearFeet;
  final double clipYMax; // box bottom at/below this = base is out of frame
  final int confirmWindow; // look at this many recent frames...
  final int confirmNeeded; // ...and require the tag in this many of them
  final double fastPathConf;
  final int holdFrames; // keep showing the last detection this many empty frames
  final int smoothWindow; // median over this many distance readings
  final Duration debounceVeryNear;
  final Duration debounceNear;
  final Duration debounceFar;
  final int lowSevConfirmWindow;
  final int lowSevConfirmNeeded;
  final Map<String, double> minConfByTag;
  final Map<String, double> minConfByLabel;

  Duration debounceFor(Proximity p) => switch (p) {
        Proximity.veryNear => debounceVeryNear,
        Proximity.near => debounceNear,
        Proximity.far => debounceFar,
      };

  double minConfFor(String tag, String label) {
    var m = minConf;
    final t = minConfByTag[tag];
    if (t != null && t > m) m = t;
    final l = minConfByLabel[label];
    if (l != null && l > m) m = l;
    return m;
  }
}

/// The configuration the app actually runs with. Everything tunable from real
/// phone testing is here, in one place. [PipelineConfig]'s own defaults are the
/// original (pre-phone-test) values, kept so the older unit tests still pin the
/// original behaviour.
const PipelineConfig kFieldPipelineConfig = PipelineConfig(
  // Chairs, desks, stairs up, people: 3 of the last 5 frames. Stairs down and
  // vehicles keep 2 of 3 and the 0.85 fast path (fastPathConf above).
  lowSevConfirmWindow: 5,
  lowSevConfirmNeeded: 3,
  // Seen on a real phone: "DESK 74%" and "STAIRS UP 45%" on plain floor.
  // Stairs-up floor sits above the 45% false alarm; the stairs model's correct
  // detections were verified at 32-65% (lib/main.dart, _stairsSpec), so this
  // will also drop some genuine up-stairs below 55%. Stairs up is severity 2,
  // not a drop, so that trade is accepted. Desk floor sits above the 74% false
  // alarm. Both are single observations: weak evidence, see KNOWN_LIMITS.md.
  minConfByTag: {'stairs_up': 0.55},
  minConfByLabel: {'desk': 0.80},
);

Proximity proximityFor(double distFeet, bool clipped, PipelineConfig c) {
  if (clipped || distFeet <= c.veryNearFeet) return Proximity.veryNear;
  if (distFeet <= c.nearFeet) return Proximity.near;
  return Proximity.far;
}

class PipelineResult {
  const PipelineResult({
    this.display,
    this.displayDistFeet,
    this.alert,
    required this.rawCount,
    required this.confirmedCount,
  });

  final Candidate? display; // what the on-screen readout shows
  final double? displayDistFeet; // median-smoothed distance for the readout
  final Candidate? alert; // hazard to dispatch this frame, if any
  final int rawCount; // detections that passed the filters
  final int confirmedCount; // ...of which persisted across frames
}

// Everything between "raw model detections" and "what to show/alert":
// filtering, distance, tiering, multi-frame confirmation, debounce, and a
// stable choice of which detection the readout follows. Pure Dart so it can
// be unit-tested without a camera or network.
class DetectionPipeline {
  DetectionPipeline({required this.distanceModel, this.config = const PipelineConfig()});

  final DistanceModel distanceModel;
  final PipelineConfig config;

  final List<Set<String>> _history = [];
  final Map<String, DateTime> _lastFired = {};
  // Recent distance readings per tag. Filled for EVERY frame a tag is seen,
  // including the unconfirmed first one, so the median already has history
  // by the time the tag is confirmed and one outlier can't skew it.
  final Map<String, List<double>> _distBufs = {};
  Candidate? _lastDisplay;
  double? _lastDisplayDist;
  int _missedFrames = 0;

  void reset() {
    _history.clear();
    _lastFired.clear();
    _distBufs.clear();
    _lastDisplay = null;
    _lastDisplayDist = null;
    _missedFrames = 0;
  }

  static int _byPriorityThenConf(Candidate a, Candidate b) {
    final p = b.priority.compareTo(a.priority);
    return p != 0 ? p : b.conf.compareTo(a.conf);
  }

  int get _historySize => math.max(config.confirmWindow, config.lowSevConfirmWindow);

  bool _isConfirmed(Candidate c) {
    final severe = c.severity >= 3;
    if (severe && c.conf >= config.fastPathConf) return true;
    final window = severe ? config.confirmWindow : config.lowSevConfirmWindow;
    final needed = severe ? config.confirmNeeded : config.lowSevConfirmNeeded;
    final recent = _history.length > window ? _history.sublist(_history.length - window) : _history;
    return recent.where((s) => s.contains(c.tag)).length >= needed;
  }

  PipelineResult process(List<Map<String, dynamic>> detections, DateTime now) {
    final cands = <Candidate>[];
    for (final det in detections) {
      final c = _toCandidate(det);
      if (c != null) cands.add(c);
    }
    cands.sort(_byPriorityThenConf);

    _history.add(cands.map((c) => c.tag).toSet());
    while (_history.length > _historySize) {
      _history.removeAt(0);
    }

    // Buffer this frame's best reading for each tag (cands is sorted, so the
    // first per tag is the highest-priority/most confident). Buffers for tags
    // that have dropped out of the confirmation window are discarded.
    final buffered = <String>{};
    for (final c in cands) {
      if (!buffered.add(c.tag)) continue;
      final buf = _distBufs.putIfAbsent(c.tag, () => []);
      buf.add(c.distFeet);
      while (buf.length > config.smoothWindow) {
        buf.removeAt(0);
      }
    }
    _distBufs.removeWhere((tag, _) => !_history.any((s) => s.contains(tag)));

    // A one-frame blip is not a hazard: require the tag in N of the last M
    // frames before it can drive the readout or an alert.
    final confirmed = cands.where(_isConfirmed).toList();

    Candidate? display;
    double? displayDist;
    if (confirmed.isNotEmpty) {
      final top = confirmed.first;
      display = top;
      displayDist = _median(_distBufs[top.tag]!);
      _lastDisplay = display;
      _lastDisplayDist = displayDist;
      _missedFrames = 0;
    } else {
      _missedFrames++;
      if (_missedFrames <= config.holdFrames && _lastDisplay != null) {
        display = _lastDisplay;
        displayDist = _lastDisplayDist;
      } else {
        _lastDisplay = null;
        _lastDisplayDist = null;
      }
    }

    Candidate? alert;
    for (final c in confirmed) {
      if (c.tier == AlertTier.info) continue; // shown, never dispatched
      final last = _lastFired[c.tag];
      final due = last == null || now.difference(last) >= config.debounceFor(c.proximity);
      if (due || c.tier == AlertTier.critical) {
        alert = c;
        break;
      }
    }
    if (alert != null) _lastFired[alert.tag] = now;

    return PipelineResult(
      display: display,
      displayDistFeet: displayDist,
      alert: alert,
      rawCount: cands.length,
      confirmedCount: confirmed.length,
    );
  }

  Candidate? _toCandidate(Map<String, dynamic> det) {
    // Defensive numeric casting — jsonDecode can return int for whole numbers.
    final box = (det['box'] as List).map((v) => (v as num).toDouble()).toList();
    final tag = det['tag'] as String;
    final label = (det['label'] as String?) ?? tag.replaceAll('_', ' ');
    final model = det['model'] as String? ?? '-';

    final conf = box[4];
    if (conf < config.minConfFor(tag, label)) return null;

    final xCenter = (box[0] + box[2]) / 2.0;
    final yMax = box[3];
    final zone = xCenter < 0.33 ? 'left' : xCenter > 0.66 ? 'right' : 'center';

    final measured = distanceModel.distanceFeet(yMax);
    if (measured == null) return null;
    final clipped = yMax >= config.clipYMax;
    final dist = clipped ? distanceModel.floorFeet : measured;
    if (!clipped && dist > config.maxDistFeet) return null;

    final proximity = proximityFor(dist, clipped, config);
    final tier = classifyTier(tag: tag, proximity: proximity, zone: zone);
    if (tier == null) return null;

    return Candidate(
      tag: tag,
      label: label,
      zone: zone,
      model: model,
      distFeet: dist,
      clipped: clipped,
      proximity: proximity,
      severity: kHazardSeverity[tag] ?? 1,
      tier: tier,
      conf: conf,
      box: box.sublist(0, 4),
      yMax: yMax,
    );
  }

  static double _median(List<double> values) {
    final s = [...values]..sort();
    final mid = s.length ~/ 2;
    return s.length.isOdd ? s[mid] : (s[mid - 1] + s[mid]) / 2.0;
  }
}
