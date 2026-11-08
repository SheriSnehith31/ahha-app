# AHHA: Acoustic & Haptic Hazard Assistant

AHHA is a phone app, worn at chest height, that gives blind and low-vision travelers early warnings about hazards ahead: stairs down, obstacles, furniture and blocked paths. It uses a short spoken phrase and a vibration whose strength follows urgency, stays quiet when the path is clear, and says so when it cannot see.

Built for **Capital Hacks 5.0 (Fall 2026), Track: Health + Accessibility** by **Team Cadence**, as the project for CSC 238 (Human-Computer Interface Design) at Sacramento State.

**Status: research prototype.** It runs on a real Android phone, but accuracy has not been measured and it has not been tested with blind or low-vision users. See [What is not done yet](#what-is-not-done-yet) and [KNOWN_LIMITS.md](KNOWN_LIMITS.md).

## Team Cadence

- Snehith Sheri
- Himanshu Gawasane
- Afnan Sabir Mohammed

## What it does

- Finds stairs down and up, obstacles, doors, furniture (chair, table, couch, bed) and, in street mode, vehicles, people, dogs, bikes and potholes.
- Says where the hazard is (left, center or right) and how near it is, as a band (very near, near, far) instead of exact feet.
- Speaks short phrases such as "Stop. Stairs down." and "Chair very close ahead.", and vibrates with a strength that follows severity.
- Warns "Path blocked ahead." when a large object fills the middle of the view.
- Fail-safes: "Camera can't see ahead. Stop and check." when the image is too dark or blocked, and "Detection offline. Use your cane." when detection fails.
- Limits how much it talks (a speech budget per minute); vibration still fires if speech is held back.
- The traveler stays in control: pause, haptic on/off and audio on/off at any time.

## How it works

1. The back camera captures a frame.
2. Detection:
   - Hosted Roboflow models, called over the internet with a 3 second timeout.
   - Google MediaPipe Object Detector (EfficientDet-Lite0) running on the phone, for chairs, tables, couches and beds (indoor mode).
3. Boxes with class and confidence are filtered by confidence floors and merged when two models find the same object.
4. A hazard must appear in several recent frames before an alert (stairs down and vehicles: 2 of 3 frames, or at once at 85% confidence; other hazards: 3 of the last 5 frames).
5. The class sets the severity, which sets the spoken phrase and the haptic pattern.

Distance is estimated from the bottom edge of each box with a flat-ground camera model whose camera height and tilt are assumed, not measured. The bands are widened about 1.5x as a safety stopgap. This is not a calibration.

## Tech stack

- Flutter and Dart, Android
- Packages: `camera`, `http`, `flutter_tts`, `vibration`, `image` (see `pubspec.yaml`)
- Roboflow-hosted pretrained models (stairs, obstacles, COCO, potholes)
- Google MediaPipe (EfficientDet-Lite0), bundled in `android/app/src/main/assets`
- Python tools for evaluation sessions and log analysis (`tools/`)

## What is done

- [x] Working Android app with indoor and street modes
- [x] Roboflow-hosted detection for stairs, obstacles, vehicles, people and potholes
- [x] On-phone MediaPipe detection for furniture
- [x] "Path blocked ahead." rule that needs no object label
- [x] Alert policy: severity, frame confirmation, speech budget, repeat timing, haptic patterns
- [x] Fail-safes for dark camera and offline detection
- [x] Distance bands and a stale-audio-line fix
- [x] Automated tests for the detection and alert rules (185 pass, 2 skipped on purpose)
- [x] Evaluation harness and alert-log analyzer in `tools/`
- [x] Training plan and audit of public stairs datasets (`tools/train`)
- [x] Documentation: alert design, research notes, AI use log, known limits
- [x] Tested on a real phone in a few scenes (chair, table, door, stairs down, blocked path)

## What is not done yet

- [ ] Accuracy is not measured (no labeled test set, no precision or recall)
- [ ] Distances are estimates; camera height and tilt are assumed, not measured
- [ ] We did not train our own model; the app uses pretrained models
- [ ] No testing with blind or low-vision users yet
- [ ] On-phone speed and battery use are not measured
- [ ] A plain-wall detection check is built but switched off, because pixels alone cannot tell a wall from a ceiling

## Setup

1. Install Flutter and an Android device (or emulator).
2. Get a Roboflow API key. The key lives in `lib/config.dart`, which is gitignored and is **not** in this repository.
3. Copy `lib/config.example.dart` to `lib/config.dart` and put your own key in it. Never commit `lib/config.dart`.
4. Run:

```bash
flutter pub get
flutter run
```

Hosted inference uses credits from your Roboflow plan (the free Public plan lists 15 credits a month; models called and images sent are on your workspace's usage page).

Tests for the detection and alert rules:

```bash
flutter test
```

## Modes, models and Roboflow usage

The **MODE** button switches what the app looks for. Each mode calls a different set of hosted Roboflow models, one call per model per frame:

| Mode | Models called per frame | Finds |
|---|---|---|
| INDOOR (default) | stairs + indoor obstacles (2 hosted), plus MediaPipe on the phone | stairs, doors, chairs, tables, couches, beds |
| STREET | stairs + COCO + potholes (3 hosted) | the above, plus cars, buses, trucks, motorcycles, bicycles, people, dogs, benches, hydrants, potholes |

STREET makes 50% more hosted calls than INDOOR, so use it on purpose. If calls start failing (no signal, bad key, credits used up), the app says "Detection offline" instead of silently seeing nothing.

## Alert design and evaluation

See [docs/alert_design.md](docs/alert_design.md) for how haptic and audio warnings scale with hazard type and distance, the timing and cognitive-load rules, trust and fail-safe behaviour, and the evaluation plan.

To record a session: tap the info icon, **COPY SESSION LOG**, paste it into a file, then:

```bash
python tools/analyze_alert_log.py session_log.csv
```

### Tier 2 evaluation sessions (tooling only)

`tools/tier2_harness.py` runs a seated Wizard-of-Oz session: it speaks each alert aloud (offline TTS via `pyttsx3`), times the participant's reaction, and logs their interpretation and trust rating to a timestamped CSV.

```bash
pip install pyttsx3
python tools/tier2_harness.py
```

Each run writes `tier2_session_<timestamp>.csv` into the directory you ran it from. After collecting sessions, aggregate them from that same directory:

```bash
python tools/aggregate_results.py
```

This prints, overall and per tier (critical, high, medium, failsafe): mean and median reaction latency, the trust-score (1 to 5) distribution, and a percentage of correct interpretations. That last number is a keyword-overlap heuristic, not rigorous grading; see the docstring in `aggregate_results.py` before citing it. **No sessions with blind or low-vision participants have been run with this version.**

## Research basis

The design comes from three semi-structured remote interviews (anonymous, small, self-reported) and two public videos about cane use and stair descent, plus secondary research (`docs/secondary_research_notes.md`). It is a direction, not proof.

## AI use

Claude Code was used for development help on this project. See `docs/genai_log.md`.

## Safety note

AHHA does not replace a white cane or a guide dog. Photos are sent to Roboflow-hosted models over the internet.
