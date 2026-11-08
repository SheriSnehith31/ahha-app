import 'detection_logic.dart';

// "Path blocked ahead." for the cases where nothing has a name: a wall, a dead
// end, or something huge filling the view. Two independent triggers:
//
//  1. BOX RULE (always on): ANY detection, of ANY class (even ones the app
//     otherwise ignores), that fills the walking lane.
//  2. WALL RULE (label-free, behind [kLabelFreeWallCheck]): the centre-bottom
//     of the picture has almost no texture in a frame that is bright enough to
//     see, for several frames in a row.
//
// Design limits, stated plainly:
//  - The wall rule cannot tell a plain wall from a plain ceiling or a bare
//    floor: they are the same pixels. That is why it ships OFF (see
//    KNOWN_LIMITS.md and the tests).
//  - Neither rule can see glass, drop-offs, or things above the camera.

/// Label-free plain-wall trigger. OFF by default: it cannot be made
/// conservative from pixels alone (a plain ceiling looks identical to a plain
/// wall), and no real frames were available to tune it. Flip to true only
/// after testing on real footage, ideally with the phone's tilt as a second
/// signal.
const bool kLabelFreeWallCheck = false;

class PathBlockedConfig {
  const PathBlockedConfig({
    this.laneLeft = 1 / 3,
    this.laneRight = 2 / 3,
    this.minLaneOverlap = 0.60,
    this.minBottomY = 0.90,
    this.minHeight = 0.50,
    this.minConf = 0.40,
    this.boxWindow = 3,
    this.boxNeeded = 2,
    this.wallFrames = 3,
    this.minLuminance = 60.0,
    this.repeat = const Duration(seconds: 5),
  });

  final double laneLeft; // lane = centre third of the frame
  final double laneRight;
  final double minLaneOverlap; // fraction of the lane width the box must cover
  final double minBottomY; // box bottom edge at or below this (0 = top, 1 = bottom)
  final double minHeight; // box height as a fraction of the frame
  final double minConf;
  final int boxWindow; // box rule: seen in boxNeeded of the last boxWindow frames
  final int boxNeeded;
  final int wallFrames; // wall rule: this many consecutive plain frames
  final double minLuminance; // wall rule only runs when the frame is at least this bright (0-255)
  final Duration repeat; // never alert more often than this
}

enum BlockedReason { largeObject, plainWall }

/// How textured the centre-bottom and the whole picture are, as the share of
/// grid cells whose local gradient exceeds a threshold. Near 0 = featureless.
class PlainStats {
  const PlainStats({required this.edgeFractionCenterBottom, required this.edgeFractionAll});
  final double edgeFractionCenterBottom;
  final double edgeFractionAll;
}

/// Share of cells with |dx|+|dy| above [gradient] (0-255 scale), for the
/// centre-bottom region (middle third, lower ~45%) and for the whole grid.
/// [gray] is row-major luminance, w*h values. A single wall/floor boundary
/// line crossing the picture is enough to show up here (it is about 2-4% of
/// cells), which is what keeps a far wall with a visible floor from counting
/// as "plain".
PlainStats plainStatsFromGray(List<int> gray, int w, int h, {double gradient = 12.0}) {
  assert(gray.length == w * h);
  var allCells = 0, allEdge = 0, cbCells = 0, cbEdge = 0;
  final x0 = w ~/ 3, x1 = (2 * w) ~/ 3, y0 = (h * 0.55).floor();
  for (var y = 0; y < h - 1; y++) {
    for (var x = 0; x < w - 1; x++) {
      final p = gray[y * w + x];
      final g = (gray[y * w + x + 1] - p).abs() + (gray[(y + 1) * w + x] - p).abs();
      final isEdge = g > gradient;
      allCells++;
      if (isEdge) allEdge++;
      if (x >= x0 && x < x1 && y >= y0) {
        cbCells++;
        if (isEdge) cbEdge++;
      }
    }
  }
  return PlainStats(
    edgeFractionCenterBottom: cbCells == 0 ? 1 : cbEdge / cbCells,
    edgeFractionAll: allCells == 0 ? 1 : allEdge / allCells,
  );
}

/// The hazard handed to AlertPolicy/_dispatchAlert for a blocked path:
/// severity 2, never critical, centre lane, strong double pulse (the high tier
/// at very-near strength).
Candidate blockedPathCandidate() => const Candidate(
      tag: kPathBlockedTag,
      label: 'path blocked',
      zone: 'center',
      model: 'path',
      distFeet: 0,
      clipped: true,
      proximity: Proximity.veryNear,
      severity: 2,
      tier: AlertTier.high,
      conf: 1.0,
      box: [0.33, 0.0, 0.67, 1.0],
      yMax: 1.0,
    );

class PathBlockedDetector {
  PathBlockedDetector({this.config = const PathBlockedConfig(), bool? wallCheckEnabled})
      : wallCheckEnabled = wallCheckEnabled ?? kLabelFreeWallCheck;

  final PathBlockedConfig config;
  final bool wallCheckEnabled;
  final List<bool> _boxHits = [];
  int _plainStreak = 0;
  DateTime? _lastFired;

  /// Wall-rule threshold: both regions must have under this share of edge cells.
  static const double maxEdgeFraction = 0.01;

  void reset() {
    _boxHits.clear();
    _plainStreak = 0;
    _lastFired = null;
  }

  /// One box is [x1, y1, x2, y2, confidence], normalised 0..1.
  bool blocksLane(List<double> b) {
    if (b.length < 5 || b[4] < config.minConf) return false;
    final laneW = config.laneRight - config.laneLeft;
    final overlap = (b[2] < config.laneRight ? b[2] : config.laneRight) -
        (b[0] > config.laneLeft ? b[0] : config.laneLeft);
    if (overlap <= 0 || overlap / laneW <= config.minLaneOverlap) return false;
    if (b[3] < config.minBottomY) return false;
    return (b[3] - b[1]) > config.minHeight;
  }

  /// Call once per frame that reached the models. Returns why to alert, or
  /// null. History is always updated, even when the alert is held back, so a
  /// blocked path that persists alerts as soon as it is allowed to.
  ///
  /// [criticalActive]: a critical alert (stairs down, vehicle) is being
  /// dispatched this frame; it outranks this one. [laneCoveredByLabel]: a
  /// labelled hazard already covers the centre lane, so saying "path blocked"
  /// as well would be a second speech about the same thing.
  BlockedReason? update({
    required List<List<double>> boxes,
    PlainStats? plain,
    required double luminance,
    required DateTime now,
    bool laneCoveredByLabel = false,
    bool criticalActive = false,
  }) {
    _boxHits.add(boxes.any(blocksLane));
    while (_boxHits.length > config.boxWindow) {
      _boxHits.removeAt(0);
    }

    final plainNow = wallCheckEnabled &&
        plain != null &&
        luminance >= config.minLuminance &&
        plain.edgeFractionCenterBottom < maxEdgeFraction &&
        plain.edgeFractionAll < maxEdgeFraction;
    _plainStreak = plainNow ? _plainStreak + 1 : 0;

    final boxFire = _boxHits.where((h) => h).length >= config.boxNeeded;
    final wallFire = _plainStreak >= config.wallFrames;
    if (!boxFire && !wallFire) return null;

    if (criticalActive || laneCoveredByLabel) return null;
    final last = _lastFired;
    if (last != null && now.difference(last) < config.repeat) return null;
    _lastFired = now;
    return boxFire ? BlockedReason.largeObject : BlockedReason.plainWall;
  }
}
