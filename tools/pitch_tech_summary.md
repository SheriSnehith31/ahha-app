# AHHA: technical summary for the pitch slide

> **OUT OF DATE after the real-phone fixes (branch `v2-fixes`).** Line numbers below are from
> before those changes, and these facts have changed: confirmation is now 3 of the last 5
> frames below severity 3; distance is shown as bands and the band thresholds are 1.5x (a
> stopgap); alerts add "Path blocked ahead."; the dark-camera message is now "Camera can't see
> ahead. Stop and check."; an on-device furniture detector was added (INDOOR); test counts are
> higher. See `KNOWN_LIMITS.md`. Regenerate this file before using it.

Everything below was read from the code in this repo or measured by running the test
suites on 2026-11-08. Where something is not in the code it says **not found**.
File:line references are to the files as they are today.

---

## 1. Packages that matter (`pubspec.yaml`)

| package | version | what the app uses it for |
|---|---|---|
| `camera` | ^0.12.1 | Back camera (`cameras[0]`), `ResolutionPreset.medium`, JPEG stills via `takePicture()`; no audio (`lib/main.dart:331-336`, `366`) |
| `http` | ^1.6.0 | POSTs each frame to Roboflow hosted models, 3 s timeout (`lib/main.dart:438-445`). Also used by the eval harness (`tools/eval/eval_core.dart:27`) |
| `flutter_tts` | ^4.2.5 | Spoken alerts and fail-safe phrases; rate, pitch and volume set per alert (`lib/main.dart:318-324`, `593-599`) |
| `vibration` | ^3.2.1 | Haptic patterns, with per-pulse strength when the phone supports amplitude control (`lib/main.dart:326`, `345-352`) |
| `image` | ^4.10.0 | Decodes each JPEG in a background isolate to measure brightness and (intended) fix EXIF rotation (`lib/main.dart:113-136`). Also used by the eval harness |
| `flutter` (SDK) | sdk | UI, `compute()` isolate, clipboard for "COPY SESSION LOG" (`lib/main.dart:4-10`, `677`) |
| `cupertino_icons` | ^1.0.8 | Declared in `pubspec.yaml`; **no use found in `lib/`** |
| `flutter_test` (dev) | sdk | Unit tests |
| `flutter_lints` (dev) | ^6.0.0 | Lint rules |

Dart SDK `^3.13.3`. App version `1.0.0+1`. Target platform in practice: Android (Gradle build);
iOS/other targets: **not found** (not tested).

---

## 2. One line per source file

### `lib/`
| file | lines | what it does |
|---|---|---|
| `lib/main.dart` | 1,050 | The app: camera loop, the Roboflow calls, fail-safes, alert dispatch (haptic + speech + banner), and the whole UI including the debug panel |
| `lib/detection_logic.dart` | 359 | Pure Dart: severity table, tier rules, distance model, 2-of-3 confirmation, median smoothing, hold, per-proximity repeat timing |
| `lib/alert_policy.dart` | 329 | Pure Dart: spoken wording, haptic patterns, voice settings, speech budget and suppression rules, plus the session log (`AlertLog`) |
| `lib/config.dart` | 9 | Holds the Roboflow API key constant (value deliberately not shown here) |

### `tools/`
| file | what it does |
|---|---|
| `tools/eval/run_eval.dart` | Command-line runner for the detector self-test (`--init`, `--plan`, then run); writes `report.md` and `results.csv` |
| `tools/eval/eval_core.dart` | Self-test core: runs labelled photos through the same models, class filters, pipeline and alert policy as the app; caching, call log, confidence intervals, diagnosis text |
| `tools/eval/eval_core_test.dart` | Tests for the harness itself, using a fake API and synthetic images |
| `tools/eval/README.md`, `report.md`, `.gitignore` | How to use it; the latest report (no photos, so no results); ignores `cache/` |
| `tools/spatial_engine.py` | Early Python prototype of distance and alert-priority logic (`AlertGovernor`); not used by the app |
| `tools/tier2_harness.py` | Wizard-of-Oz harness for seated user sessions: speaks each alert with offline TTS (`pyttsx3`), times the participant's acknowledgment, logs interpretation and trust rating to CSV |
| `tools/aggregate_results.py` | Summarises the `tier2_session_*.csv` files: latency, trust scores, rough "correct interpretation" keyword score |
| `tools/analyze_alert_log.py` | Summarises a session log copied out of the app: utterances per minute against the 12/min budget, withheld reasons, tier and proximity mix, fail-safe events |
| `tools/train/class_map.yaml` | Draft mapping of dataset classes to ours; awaiting confirmation |
| `tools/train/datasets_overview.md` | Audit of 9 stairs datasets from Roboflow Universe metadata and sample images |
| `tools/train/object_candidates.md` | Three candidate datasets each for car, person, chair, pothole (proposals only) |
| `tools/train/STATUS.md` | Training pipeline status: stopped, 0 photos in every label folder |
| `tools/train/compare.md` | Placeholder: says no comparison was run |
| `tools/pitch_tech_summary.md` | This file |

No model was trained. Nothing under `tools/train/` runs in the app.

---

## 3. Models and endpoints the app calls

**Endpoint pattern** (`lib/main.dart:310`, `438-445`): `POST https://serverless.roboflow.com/<model_id>`
- Body: base64-encoded JPEG. Header `Content-Type: application/x-www-form-urlencoded`.
- Auth: `Authorization: Bearer <key from lib/config.dart>`.
- No confidence parameter is sent. The app filters on confidence itself (see section 4).
- Timeout 3 s per call. All models for a frame are called at the same time (`Future.wait`, `lib/main.dart:396-405`).
- No other endpoint or service is called. Nothing else is sent over the network: **not found**.

| mode | models called per frame | defined at |
|---|---|---|
| **INDOOR** (the default, `lib/main.dart:191`) | `stairs_detection-jaj7e/2`, `obstacle-detection-meg7r/19` (2 calls) | `lib/main.dart:94-95` |
| **STREET** | `stairs_detection-jaj7e/2`, `coco/50`, `pothole-detection-mev9q/6` (3 calls) | `lib/main.dart:94-95` |

What each model contributes (`lib/main.dart:45-92`):

| model | classes kept → app tag |
|---|---|
| `stairs_detection-jaj7e/2` (both modes) | `downstair` → `stairs_down`, `upstair` → `stairs_up` |
| `obstacle-detection-meg7r/19` (INDOOR) | `Chair`, `Desk`, `Door` → `obstacle_low`. Dropped but shown in the debug panel: Bottle, Mug, Books, Laptop, Shoes |
| `coco/50` (STREET) | allow-list only: person → `person`; bicycle → `two_wheeler`; motorcycle, car, bus, truck → `vehicle`; dog → `dog`; bench, fire hydrant → `obstacle_low`. Every other COCO class is silently dropped |
| `pothole-detection-mev9q/6` (STREET) | `pothole` → `pothole` |

The mode is switched by a button (`_toggleMode`, `lib/main.dart:656-673`), which also resets the pipeline and policy history.

---

## 4. Alert rules

### Severity (how bad it is to walk into it): `lib/detection_logic.dart:20-29`
| tag | severity |
|---|---|
| `stairs_down`, `vehicle` | 3 |
| `stairs_up`, `obstacle_low`, `pothole`, `two_wheeler` | 2 |
| `person`, `dog` | 1 (also the default for an unknown tag, line 38) |

### Tier order: `lib/detection_logic.dart:5-12`
`critical` (3) > `high` (2) > `medium` (1) > `info` (0). `info` is shown on screen but never spoken or vibrated.
Candidates are sorted by tier priority, then by confidence (`lib/detection_logic.dart:234-237`).

### Tier matrix: `classifyTier`, `lib/detection_logic.dart:33-69`
In the centre zone:

| severity | very near | near | far |
|---|---|---|---|
| 3 (stairs down, vehicle) | critical | high | medium |
| 2 | high | medium | medium |
| 1 (person, dog) | medium | info | info |

Off the walking path (left or right zone), lines 40-48: severity below 3 gives nothing at all; severity 3 gives high if very near, medium if near, nothing if far.

### Thresholds: `PipelineConfig`, `lib/detection_logic.dart:138-181`
| rule | value | line |
|---|---|---|
| Minimum model confidence | 0.40 | 140, applied at 322 |
| Maximum distance considered | 10 ft (not applied to "clipped" boxes) | 141, applied at 332 |
| Very near | ≤ 7.0 ft, or clipped | 144, `proximityFor` 183-187 |
| Near | ≤ 8.5 ft | 145 |
| Far | anything else under 10 ft | 187 |
| Clipped (box bottom out of frame) | box bottom ≥ 0.985 of frame height; distance set to the nearest visible floor | 146, applied at 330-331 |
| Zones | left if box centre x < 0.33, right if > 0.66, else centre | 326 |
| Confirmation | tag must appear in 2 of the last 3 frames | 147-148, 239-242, 252-253 |
| Fast path | severity-3 hazard at confidence ≥ 0.85 skips the wait | 152, 240 |
| Hold | last detection stays on screen for 2 empty frames | 153, 284 |
| Distance smoothing | median of the last 3 readings per tag | 154, 263-266, 354-358 |

### Timing
| rule | value | where |
|---|---|---|
| Repeat interval, same hazard tag | 1 s very near, 2 s near, 3 s far | `lib/detection_logic.dart:157-159`, applied 296-297 |
| Critical alerts | ignore the repeat interval | `lib/detection_logic.dart:298` |
| Gap between camera captures | 400 ms after each frame finishes, so frame rate = (capture + upload + inference time) + 400 ms | `lib/main.dart:377` |
| Network timeout | 3 s per model call | `lib/main.dart:445` |
| Hazard banner on screen | 2 s | `lib/main.dart:276` |
| Fail-safe reminder buzz | every 5 s | `lib/main.dart:514`, `538` |

Measured frame rate on a phone: **not found**. A code comment assumes "~1 frame/s" (`lib/detection_logic.dart:150-151`); it was not measured.

### Speech budget and suppression: `AlertPolicy`, `lib/alert_policy.dart:53-192`
- Budget per rolling 60 s: **9 medium, 12 high** (`:54`, window at `:72-75`, check at `:171-172`). **Critical is never limited** (`:163`).
- Speech is withheld, but the haptic still fires, for these reasons (`:162-174`):
  - `busy`: the voice is mid-sentence on something at least as important.
  - `no change`: same tag, same tier, rounded distance changed by less than 1 ft.
  - `budget`: the minute's limit is used up.
- Interruption (`lib/main.dart:608-616`, `648`): critical preempts anything speaking; high preempts a medium; everything else waits. A busy alert is not counted as spoken, so it speaks on a later frame.

### Haptics: `hapticFor`, `lib/alert_policy.dart:100-138`
| tier | pattern | strength |
|---|---|---|
| critical | 3 pulses × 100 ms, 60 ms gaps | 255 (max) always |
| high | 2 pulses × 300 ms (very near) or 220 ms (otherwise), gap 90/110 ms | 230 × (1.0 / 0.75 / 0.5 for very near / near / far) |
| medium | 1 pulse of 150 / 120 / 100 ms | 160 × (1.0 / 0.75 / 0.5) |
| info | none | none |

On phones without amplitude control only the rhythm differs (`lib/main.dart:345-352`).

### Voice: `ttsFor`, `lib/alert_policy.dart:141-148`
| case | rate | pitch | volume |
|---|---|---|---|
| critical, or very near | 0.80 | 1.25 | 1.0 |
| near | 0.68 | 1.05 | 1.0 |
| far | 0.58 | 0.95 | 0.85 |

### Wording: `speechFor`, `lib/alert_policy.dart:81-96`
- Critical: "Stop. Stairs down." or "Stop. <Label> ahead."
- Very near: "<Label> very close ahead." (or "... on your left/right"), no number.
- Otherwise: "<Label> ahead, N feet." (or "on your left/right, N feet").

### Fail-safes (`lib/main.dart`)
| fail-safe | trigger | what happens |
|---|---|---|
| Camera dark | average brightness < 40 on a 0-255 scale (`:306`, `:386`) | Speaks "Camera can't see. Check your phone." once (`:283-288`), buzz now and every 5 s (`:503-518`); logged |
| Detection offline | every model call failed in 3 frames in a row (`:202`, `:413-418`) | Speaks "Detection offline. Use your cane." once, buzz every 5 s (`:530-542`); on recovery speaks "Detection restored." (`:544-552`) |

The two alternative camera-dark phrasings (`:285-286`) are for A/B testing; the active one is index 0 (`:288`).

### Distance model: `lib/main.dart:299-304`, `lib/detection_logic.dart:76-104`
Flat-ground pinhole model. Camera height 1.3 m, pitch 5.5°, vertical field of view 63°, horizon at 0.5. Nearest visible floor ≈ 5.7 ft (comment at `lib/main.dart:295`). **The 1.3 m height is assumed, not measured** (comment at `:291-293`). Calibration is a fit to two field points, marked "NOT FINAL" in the code.

---

## 5. One camera frame to one alert, step by step

1. **Capture loop** (`lib/main.dart:357-379`): if not paused and no frame in flight, `takePicture()` and read the JPEG bytes. Wait 400 ms after the frame finishes, then repeat.
2. **Prepare frame** (`:381-390`, `113-136`): decode the JPEG in a background isolate, compute average brightness from a 32×24 copy.
3. **Dark check** (`:386-389`): brightness < 40 → camera-dark fail-safe, stop here for this frame. Otherwise clear that fail-safe.
4. **Call the models** (`:392-405`, `429-496`): INDOOR 2 calls, STREET 3 calls, at the same time, 3 s timeout each. Each response is filtered by the model's allow/ignore lists, renamed to an app tag, and converted to a normalised box plus confidence.
5. **Offline check** (`:413-420`): if every call failed, count it; 3 in a row → offline fail-safe. The frame is not passed on (a failed call is not treated as "nothing there").
6. **Pipeline** (`:557-558`, `lib/detection_logic.dart:244-312`), per detection:
   1. drop if confidence < 0.40 (`:322`);
   2. zone from box centre x (`:326`);
   3. distance from the bottom edge of the box (`:328-331`); drop if at or above the horizon or beyond 10 ft; if the bottom is cut off, use the nearest-floor distance and mark "clipped";
   4. proximity: very near / near / far (`:334`);
   5. tier from severity × proximity × zone (`:335`); drop if none.
7. **Confirm** (`:239-242`, `:271`): the tag must be in 2 of the last 3 frames, or be severity 3 at confidence ≥ 0.85.
8. **Smooth and hold** (`:255-291`): median of the last 3 distance readings for the on-screen number; keep the last detection for 2 empty frames.
9. **Pick one alert** (`:293-303`): walk the confirmed list in priority order, skip `info`, take the first that is past its repeat interval (1/2/3 s by proximity) or is critical. Only one alert per frame.
10. **Dispatch** (`lib/main.dart:604-652`): decide whether the voice is busy or can be preempted; ask `AlertPolicy.decide` for wording, haptic, voice, and whether to speak (`lib/alert_policy.dart:157-191`).
11. **Output**: always the haptic (if the HAPTIC toggle is on); a banner for critical and high (2 s); speech unless withheld (`busy`, `no change`, `budget`) or the AUDIO toggle is off. The event is written to the session log either way (`lib/main.dart:623`).

---

## 6. Tests

Run on 2026-11-08 with `flutter test`:

| suite | file | result |
|---|---|---|
| Alert policy (wording, haptics, voice, budget, suppression, log) | `test/alert_policy_test.dart` | 32 passed |
| Detection logic (tiers, distance, confirmation, smoothing, hold, repeat timing) | `test/detection_logic_test.dart` | 44 passed |
| Distance calibration | `test/distance_calibration_test.dart` | 3 passed, **2 skipped** (skip reason in the file at `:125-126`: upright posture accepted, floor ~5.7 ft, closer = clipped fallback) |
| **App total** | `test/` | **79 passed, 2 skipped, 0 failed** |
| Self-test harness (fake API, synthetic images) | `tools/eval/eval_core_test.dart` | **58 passed** |

Total: 137 passing. The harness tests check the harness's own bookkeeping only; they say nothing about model quality.

### What is not tested
- **Real-world accuracy: not measured.** `tools/eval/images/` has 0 photos in every label folder (only `.gitkeep` files), so the self-test has produced no results. No recall, no false-alarm rate, no per-class accuracy.
- **Detection models:** no test calls the real Roboflow models. Every test uses synthetic input.
- **`lib/main.dart` has no tests:** camera capture, HTTP calls and error handling, class filtering/renaming, the capture loop, fail-safe timers and phrases, preemption in `_dispatchAlert`, the banner, the mode toggle, and all UI. No widget or integration tests exist.
- **Real haptics and speech on a phone:** the tests check the patterns and settings as data, not what the phone actually does. Vibration strength control depends on the phone (`_hasAmplitude`).
- **Distance accuracy:** the constants are not validated against a tape-measured set (1.3 m height unmeasured; fit from two points). The two skipped calibration tests are the ones about the nearest-floor ceiling.
- **Latency on a phone:** not measured. The debug panel shows a live number, but no recorded results exist.
- **Python tools** (`tools/*.py`): no tests found.
- **User studies:** the Tier 2 harness exists, but no collected session data is in the repo (no `tier2_session_*.csv` found).
- **iOS / non-Android:** not found.

### Known issue (found by a test during this project, not documented in the app code)
`prepareFrameIsolate` is written to fix EXIF rotation (`lib/main.dart:118-119`). The `image` package's `decodeJpg` already applies the rotation and clears the tag, so `needsBake` never becomes true and the original bytes are sent unchanged. The app code was not changed. The harness has a `--send-upright` option to test that case. No photos exist yet to measure whether it matters.
