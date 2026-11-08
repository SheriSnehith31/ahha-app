// test/distance_calibration_test.dart
//
// Manual verification tests for the distance/detection pipeline, built to
// catch exactly the three bugs found in the last session:
// 1. Distance ceiling (near objects all reading the same wrong distance)
// 2. Frame-to-frame flicker (no smoothing between detections)
// 3. Orientation-dependent recognition (rotation not baked into pixels)
//
// (Bug 3 is not covered here: rotation baking lives in main.dart's
// prepareFrameIsolate, which needs the camera plugin's image types and is
// not reachable from a pure-Dart test.)
//
// API ADAPTERS: the real distance model is DistanceModel.distanceFeet() in
// lib/detection_logic.dart (camera height in METRES, returns null at/above
// the horizon), and there is no standalone smoother — smoothing is the
// median buffer inside DetectionPipeline. calculateDistanceFeet() and
// DetectionSmoother below are thin adapters onto those real classes so the
// test bodies read the way they were written.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:ahha_app/detection_logic.dart';

// Constants under test. Must mirror main.dart's _distanceModel by hand —
// nothing enforces that, so re-check this block whenever main.dart changes.
// (The original draft had 4.3 ft / 12 deg / 45 deg / 0.45, the old
// placeholders that caused the ceiling bug, not what the app ships.)
const double _hCamFt = 1.3 * DistanceModel.metersToFeet; // main.dart: 1.3 m
const double _pitchDeg = 5.5;
const double _fovVDeg = 63.0;
const double _yHorizon = 0.5;

/// Adapter: feet in, feet out; "at/above the horizon" becomes infinity.
double calculateDistanceFeet(
  double yMax, {
  required double hCam,
  required double pitchDeg,
  required double fovVDeg,
  required double yHorizon,
}) {
  final model = DistanceModel(
    cameraHeightM: hCam / DistanceModel.metersToFeet,
    pitchDeg: pitchDeg,
    fovVDeg: fovVDeg,
    yHorizon: yHorizon,
  );
  return model.distanceFeet(yMax) ?? double.infinity;
}

/// Adapter onto the real DetectionPipeline: builds a synthetic detection
/// whose box bottom (yMax) produces the requested raw distance, feeds it one
/// frame (1 s) at a time, and returns the pipeline's smoothed readout.
/// Returns null while the 2-of-3-frame confirmation gate hasn't opened yet.
class DetectionSmoother {
  DetectionSmoother()
      : _pipeline = DetectionPipeline(
          distanceModel: DistanceModel(
            cameraHeightM: _hCamFt / DistanceModel.metersToFeet,
            pitchDeg: _pitchDeg,
            fovVDeg: _fovVDeg,
            yHorizon: _yHorizon,
          ),
        );

  final DetectionPipeline _pipeline;
  DateTime _t = DateTime(2026, 1, 1);

  double? smooth(double rawFeet) {
    final angleDeg = math.atan(_hCamFt / rawFeet) * 180.0 / math.pi;
    final yMax = _yHorizon + (angleDeg - _pitchDeg) / _fovVDeg;
    final result = _pipeline.process([
      {
        'box': [0.3, 0.2, 0.7, yMax, 0.9],
        'tag': 'obstacle_low',
        'label': 'chair',
        'model': 'test',
      }
    ], _t);
    _t = _t.add(const Duration(seconds: 1));
    return result.displayDistFeet;
  }
}

void main() {
  group('Distance formula — no ceiling / monotonicity', () {
    // These constants are PLACEHOLDERS. Once real calibrated values exist,
    // update these to match main.dart's actual _hCam/_pitch/_fovV/_yHorizon.
    const hCam = _hCamFt; // ft — MUST match real measured camera height
    const pitchDeg = _pitchDeg;
    const fovVDeg = _fovVDeg;
    const yHorizon = _yHorizon;

    test('distance strictly decreases as yMax increases from 0.5 to 1.0', () {
      // This is the core regression test for the "ceiling" bug: if two
      // different yMax values ever produce the same or an *increasing*
      // distance, the formula is broken for that constant set.
      double? previousDistance;
      for (double yMax = 0.50; yMax <= 1.0; yMax += 0.01) {
        final dist = calculateDistanceFeet(
          yMax,
          hCam: hCam,
          pitchDeg: pitchDeg,
          fovVDeg: fovVDeg,
          yHorizon: yHorizon,
        );
        if (previousDistance != null) {
          expect(
            dist,
            lessThan(previousDistance),
            reason: 'Distance did not decrease at yMax=$yMax '
                '(prev=$previousDistance, now=$dist) — ceiling bug present',
          );
        }
        previousDistance = dist;
      }
    });

    test('formula can represent distances down to at least 2 ft',
        // SKIPPED BY DECISION, not fixed: reaching 2 ft needs the phone tilted
        // ~33 deg down, and the design keeps the upright chest-mount posture.
        // The nearest measurable floor is therefore ~5.7 ft; anything closer
        // is handled by the "clipped" fallback (Immediate tier, shown as
        // "closer than camera can see"), covered in detection_logic_test.dart.
        // Delete the `skip:` argument to re-enable if that decision changes.
        skip: 'upright posture accepted: floor ~5.7 ft, closer = clipped fallback', () {
      // At yMax = 1.0 (bottom edge of frame), the formula's max achievable
      // angle must be steep enough to represent a genuinely close object.
      // This directly targets the "can never read closer than ~5.7ft" bug.
      final closestPossible = calculateDistanceFeet(
        1.0,
        hCam: hCam,
        pitchDeg: pitchDeg,
        fovVDeg: fovVDeg,
        yHorizon: yHorizon,
      );
      expect(
        closestPossible,
        lessThan(2.0),
        reason: 'At yMax=1.0 the formula floors at $closestPossible ft — '
            'constants cannot represent a genuinely close object. '
            'Increase pitchDeg and/or fovVDeg.',
      );
    });

    test('yMax=0 (top of frame) reads as far/background', () {
      final farDistance = calculateDistanceFeet(
        0.0,
        hCam: hCam,
        pitchDeg: pitchDeg,
        fovVDeg: fovVDeg,
        yHorizon: yHorizon,
      );
      expect(farDistance, greaterThan(15.0));
    });
  });

  group('Real field data sanity check (single-object dataset ONLY)', () {
    // IMPORTANT: only fill this in with SAME-OBJECT measurements (e.g. the
    // chair, at every distance). Do not mix chair/door readings here — see
    // the calibration discussion; mixed-object data will not validate
    // correctly against a single yMax->distance formula.
    //
    // Fill in real yMax values Claude Code can read from the same
    // detection log/debug output that produced your field readings, paired
    // with the real tape-measured ground truth distance.
    //
    // LEFT EMPTY ON PURPOSE: no log recorded yMax for the earlier readings
    // (the old overlay didn't show it and nothing wrote logs to disk), and
    // the only numbers recoverable are back-calculated from the on-screen
    // distances — from mixed objects, and the 3 ft point was clipped at the
    // frame edge. Refill after a clean single-object retest using the y=
    // value now shown under the distance badge.
    final realDataPoints = <({double yMax, double groundTruthFt})>[
      // (yMax: 0.XX, groundTruthFt: 3.0),
      // (yMax: 0.XX, groundTruthFt: 6.0),
      // (yMax: 0.XX, groundTruthFt: 8.0),
      // (yMax: 0.XX, groundTruthFt: 10.0),
    ];

    const hCam = _hCamFt;
    const pitchDeg = _pitchDeg;
    const fovVDeg = _fovVDeg;
    const yHorizon = _yHorizon;

    test('solved constants predict real measurements within tolerance', () {
      if (realDataPoints.isEmpty) {
        markTestSkipped(
          'No real single-object data points filled in yet — '
          'populate realDataPoints with actual chair-only measurements '
          'before trusting solved constants.',
        );
        return;
      }
      const toleranceFt = 1.5; // generous — tighten once constants are solved
      for (final point in realDataPoints) {
        final predicted = calculateDistanceFeet(
          point.yMax,
          hCam: hCam,
          pitchDeg: pitchDeg,
          fovVDeg: fovVDeg,
          yHorizon: yHorizon,
        );
        expect(
          (predicted - point.groundTruthFt).abs(),
          lessThan(toleranceFt),
          reason: 'At yMax=${point.yMax}, predicted $predicted ft but '
              'real measured distance was ${point.groundTruthFt} ft',
        );
      }
    });
  });

  group('Smoothing — no single-frame flicker', () {
    test('smoothed distance does not jump more than 2ft between consecutive frames '
        'when underlying raw readings are noisy but converging', () {
      final smoother = DetectionSmoother();
      final rawSequence = [6.0, 5.8, 9.5, 6.1, 5.9, 6.0]; // simulate one flicker outlier
      final outputs = <double>[];
      for (final raw in rawSequence) {
        // The pipeline shows nothing until a detection is confirmed in 2 of
        // 3 frames, so the first frame yields no output — skip nulls.
        final out = smoother.smooth(raw);
        if (out != null) outputs.add(out);
      }
      // Guard against passing vacuously if the pipeline produced no output.
      expect(outputs.length, greaterThan(1), reason: 'pipeline produced no smoothed output');
      for (int i = 1; i < outputs.length; i++) {
        final jump = (outputs[i] - outputs[i - 1]).abs();
        expect(
          jump,
          lessThan(2.0),
          reason: 'Smoothed output jumped by $jump ft between frame '
              '${i - 1} and $i — flicker not being suppressed',
        );
      }
    });
  });
}
