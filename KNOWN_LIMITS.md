# Known limits of AHHA

**This app is a prototype aid. It is not safe, complete or a substitute for a cane, a
guide dog or orientation-and-mobility skills.** It can miss hazards and it can raise false
alarms. Nothing here or in the app should be read as a safety claim.

Last updated after the real-phone fixes (branch `v2-fixes`). Where something was never
tested, it says so.

## Hazards the app cannot reliably see

| gap | why |
|---|---|
| **Glass doors, windows, mirrors** | A camera sees through or past them. No model here is trained on glass. A "path blocked" or "door" alert will usually not appear. |
| **Drop-offs other than stairs down** | Kerbs, platform edges, ledges, holes, escalators and open hatches have no detector. Only a model class named "stairs down" and the pothole model look for drops. |
| **Overhead obstacles** | Branches, signs, open cupboard doors and low beams above the lens are outside a forward, chest-height view. |
| **Moving people, bikes, vehicles** | Each frame is judged alone and the app sees about one frame a second, so a fast mover can go from far to close between frames. There is no motion or speed estimate. |
| **Glare, strong backlight, rain on the lens** | Overexposed or washed-out frames give unpredictable detections. Only a very dark frame triggers a fail-safe; a glare-white frame does not. |
| **Plain walls and dead ends, bright** | The label-free wall check is built but **switched off** (see below). A bright plain wall with no detection on it gives no warning. |
| **Small, thin or low things** | Cables, poles, kerb edges, bags on the floor and small steps are not in the models' classes or are too small to find. |
| **Objects the models were not trained on** | Anything outside the model class lists is invisible. The indoor obstacle model's full class list was **not verified**. |

## Things the app does that can mislead

- **Distance is an estimate, not a measurement.** It assumes a camera height (1.3 m) that
  was never measured and a phone held upright at chest height. It was fitted from two points
  and was seen to over-read by roughly 1.5x (a chair at about 4-5 ft read 6.5-7.4 ft).
  Tilting the phone changes it. The screen now shows bands (very near / near / far), and the
  bands are widened 1.5x as a **stopgap, not a calibration**.
- **The 3-of-5 confirmation adds delay.** At about one frame a second, a chair, desk or
  stairs up needs about three sightings before an alert: roughly 3 s, which is several feet
  of walking. Stairs down and vehicles are not delayed.
- **The stairs-up confidence floor (0.55) will drop some real up-stairs.** The stairs model's
  correct detections were seen at 32-65%.
- **"Path blocked ahead" from the large-box rule can also fire for large *labelled* things
  that are not blocking** (for example a big stairs box filling the lane) before the labelled
  alert has been confirmed.
- **Critical speech is repeated at most every 3 s** (haptic every frame). This is a judgment
  call made to stop runaway repetition, and it has not been tested with users.
- **Needs the network.** Roboflow calls time out after 3 s. If every call fails three frames
  in a row the app says so, but between failures it can be slow or blind.
- **Roboflow credit and key.** The API key is in `lib/config.dart`; running out of credit looks
  like a network failure.

## Switched off or unverified

| item | status |
|---|---|
| **Label-free "plain wall" check** | Built, tested on synthetic images, **ships OFF** (`kLabelFreeWallCheck = false` in `lib/path_blocked.dart`). From pixels alone a plain ceiling or bare floor looks identical to a plain wall, so it cannot be made safe to turn on without another signal (for example the phone's tilt) and real footage. A test records this limitation. |
| **On-device furniture detector (MediaPipe)** | Built, and the APK builds. **Never run on a phone** (no device was attached). Its accuracy, speed and battery cost are unmeasured. INDOOR mode only. |
| **Depth model (Part C)** | Not attempted: see the report. No depth model is in the app. |
| **Real-world accuracy** | Not measured anywhere. `tools/eval/images/` has no photos, so there are no recall or false-alarm figures. |
| **Thresholds** | Every threshold added in this round (confidence floors, 3-of-5, lane rules, 1.5x bands, 0.30 furniture floor) was checked on **fewer than 5 real scenes, mostly zero**. Treat all as **weak evidence**. |
| **EXIF rotation** | The app's own rotation fix never runs (the image library has already rotated and cleared the tag). Roboflow receives the original bytes. Not changed. |
| **Vibration strength** | Depends on the phone supporting amplitude control. |
| **Platforms** | Android only, debug build only. iOS and release builds are untested. |

## Not studied

No participants with blindness or low vision have used this version. Alert wording, timing,
cognitive load and trust are design hypotheses, not findings.
