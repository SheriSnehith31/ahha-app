# AHHA alert design and evaluation

This is the design record for the haptic and audio warnings: what the app does,
why, how it is measured, and what has **not** been validated yet. Every number
here is in code (`lib/detection_logic.dart`, `lib/alert_policy.dart`) and covered
by unit tests, so the document and the app cannot silently drift apart.

The five priorities from the proposal feedback, and where each is handled:

| Priority | Implemented in | Evaluated by |
|---|---|---|
| Haptic/audio warning design | section 3 | Tier 2 sessions (section 8) |
| Timing | section 4 | Session log latency + Tier 2 reaction time |
| Cognitive load | section 5 | Session log: speech per minute, withheld reasons |
| Trust | section 6 | Tier 2 trust ratings, staged false alarms |
| Fail-safe communication | section 7 | Fail-safe events in the session log, Tier 2 phrasing test |

## 1. Constraints that shape the design

These are measured facts or stated assumptions, not preferences. They are the
reason several choices below look conservative.

- **Range is short.** Distance comes from where the bottom of a detection box
  sits in the frame (flat-ground pinhole model). It is only trusted out to
  **10 ft**, and with the phone held upright the camera cannot see the floor
  closer than about **5.7 ft**. Anything closer is reported as "very close",
  never as a made-up number.
- **Warning time is short.** *Assuming* a walking speed of roughly 3 to 4.5 ft/s
  (about 1 to 1.4 m/s; not measured for this project), 10 ft is only about 2 to
  3 s of warning, and 7 ft is 1.5 to 2 s.
- **The pipeline is slow relative to that.** Each hosted model call took
  0.24 to 1.0 s from a PC, and a frame also needs a photo capture and a 0.4 s
  pause. The on-screen "Inference" figure is the real end-to-end number to watch.
  If a frame cycle is about 1.5 s, the user walks roughly 4.5 to 7 ft between a
  hazard first being seen and the app reacting to it.
- **Hazards can move.** The design has no motion or closing-speed estimate, so a
  car approaching at speed is treated the same as a parked one.

Consequence: this is a supplementary aid for **slow walking and cane use**. It
is not a substitute for the cane, and it is not suitable for fast traffic.

## 2. What counts as a hazard

Each detection becomes a policy tag with a **severity**:

| Severity | Tags | Examples |
|---|---|---|
| 3 (worst) | `stairs_down`, `vehicle` | drop-offs, cars, buses, trucks, motorcycles |
| 2 | `stairs_up`, `obstacle_low`, `pothole`, `two_wheeler` | chairs, doors, benches, hydrants, potholes, bicycles |
| 1 | `person`, `dog` | pedestrians, dogs |

**Proximity** has three bands: *very near* (at or under 7 ft, or base out of
frame), *near* (up to 8.5 ft), *far* (up to 10 ft).

**In the walking path** is the centre third of the frame. Things off to the side
are dropped unless they are drops or vehicles and close.

The tier follows from severity, proximity and path:

| | very near | near | far |
|---|---|---|---|
| Severity 3, in path | **critical** | high | medium |
| Severity 2, in path | high | medium | medium |
| Severity 1, in path | medium | info | info |
| Severity 3, off path | high | medium | (dropped) |
| Severity 2 or 1, off path | (dropped) | (dropped) | (dropped) |

`info` means shown on screen but never spoken or vibrated. This is a
cognitive-load decision: on a busy pavement, announcing every person would
produce constant speech, so people only interrupt when nearly touching.

## 3. Haptic and audio design

**Rule: the tier sets the rhythm, proximity sets the strength.** Closer is
always stronger, faster and higher. This is asserted in tests.

### Haptics

| Tier | Rhythm | Strength (0-255) by proximity: very near / near / far |
|---|---|---|
| critical | rapid triple pulse (100 ms, 60 ms gaps) | 255 |
| high | double pulse (300/90 ms very near, 220/110 ms near) | 230 / 173 / 115 |
| medium | single pulse (150 / 120 / 100 ms) | 160 / 120 / 80 |
| info | none | - |

The count of pulses (3, 2, 1) lets a user tell the tier apart by feel alone.
Strength needs a phone with amplitude control; the debug panel says whether the
phone has it. Without it only the rhythm differs, which is a real limitation.

### Voice

Wording is short and puts the thing first. Very near is urgent and gives **no
distance**, because the number is not reliable that close.

| Situation | Says |
|---|---|
| critical, stairs down | "Stop. Stairs down." |
| critical, vehicle | "Stop. Car ahead." |
| very near, in path | "Chair very close ahead." |
| near or far, in path | "Pothole ahead, 8 feet." |
| very near, off path | "Car very close on your left." |
| near, off path | "Car on your left, 8 feet." |

The voice also changes with proximity: very near is faster (rate 0.80), higher
(pitch 1.25) and full volume; far is slower (0.58), lower (0.95) and softer
(0.85). The specific object is named ("chair", "car"), not a generic label.

### Screen

A banner appears for critical and high alerts only, built from the same hazard
data as the speech. It stays up at least 2 s so a flickering detection does not
make it strobe. It is a visual aid for low-vision users and for demo video; it
does not replace audio or haptics.

## 4. Timing

- **Two-frame confirmation.** A detection must appear in 2 of the last 3 frames
  before it shows or alerts, so a one-frame false positive cannot fire.
- **Fast path.** A severity 3 hazard seen at 85% confidence or more skips the
  wait, because a confirmation frame costs roughly 4 ft of walking. Potholes and
  people never use it. This is a deliberate trust-versus-timeliness trade-off
  and is one of the variables to test (`PipelineConfig.fastPathConf`; set above
  1.0 to switch it off).
- **Repeat interval scales with proximity.** The same hazard re-fires at most
  every 1 s when very near, 2 s when near, 3 s when far, so the haptic
  "heartbeat" speeds up as you approach. Critical is never rate-limited.
- **Smoothing.** The distance shown is the median of the last 3 readings, and the
  last detection is held for 2 empty frames, so the number does not jump. The
  cost is about one frame of lag, so stand still when reading the number.
- **Interruption.** Critical preempts anything being spoken. High preempts a
  medium. Anything else waits, and is not lost: it speaks on a later frame.

## 5. Cognitive load

The budget, from the proposal, is **at most 12 utterances per minute**.

- **Tiered budget.** Medium speech is capped at 9 per rolling minute and high at
  12, so capacity is always left for the alerts that matter. Critical is never
  limited.
- **Speech only on change.** If the hazard type, tier and distance (within 1 ft)
  are unchanged, the app stays quiet and lets the haptic carry "still there".
- **Fewer things to say.** Off-path items are dropped, people are silent until
  very near, and only street-relevant classes are kept from the 80-class model
  (it also produces false chairs and dining tables on a street photo).
- **Withheld speech is tracked** with a reason (`no change`, `budget`, `busy`),
  and deferred speech is not lost.

## 6. Trust

- **Honest about uncertainty.** "Very close" replaces a distance that cannot be
  measured. Confidence and the raw box position are always visible on screen.
- **False positives are the main threat to trust**, so nothing speaks on a single
  weak frame (section 4). The fast-path threshold is the trade-off to study.
- **Known weak spot.** The models are small community datasets. The stairs model
  returned 32 to 65% on four dataset test photos, and the indoor obstacle model
  has not been validated on a street or on live video. Expect misses and false
  alarms.

## 7. Fail-safe communication

The worst failure is the app seeing nothing and saying nothing, which looks
exactly like "no hazards".

| Condition | Detected by | Says (once) | Then |
|---|---|---|---|
| Camera dark or covered | frame brightness below threshold | "Camera can't see. Check your phone." | haptic reminder every 5 s |
| **Detection offline** (no signal, bad key, quota used up) | every model call failed for 3 frames in a row | "Detection offline. Use your cane." | haptic reminder every 5 s |
| Recovered | a model answers again | "Detection restored." (offline only) | reminders stop |

The top bar turns red in both states. A partial failure (one model down while
others work) is not announced; it shows in the debug panel's Network line.

The dark-camera phrase has alternatives for A/B testing in `_failSafePhrasings`.

## 8. Evaluation

### Automated (done)

Unit tests assert every rule above: the tier matrix, proximity bands, that
closer is stronger and faster, the speech budget, suppression and deferral,
repeat intervals, confirmation and the fast path, and the log. Run `flutter test`.

### Instrumented sessions (built, not yet run)

Debug panel (info icon), **COPY SESSION LOG**, paste into a file, then run
`python tools/analyze_alert_log.py <file>`. The log records, per alert: time,
tier, tag, zone, proximity, distance, clipped, confidence, spoken or withheld
and why, and the exact wording. It also records fail-safe transitions and
frame latency. It yields:

- peak and average utterances per minute against the 12 budget
- withheld speech by reason
- median end-to-end latency
- fail-safe events and how long each lasted

### Human evaluation (not yet done)

Nothing about real users has been measured. Suggested variables, using the
existing `tools/tier2_harness.py` (reaction latency, interpretation, trust 1-5,
staged false alarm):

1. Distance-scaled voice and haptics **on vs. off** (does "sounds very near" help?)
2. Very-near wording: "very close" vs. a distance vs. a bare "Stop."
3. Fast path on vs. off (timeliness vs. false alarms and trust)
4. Left/right vs. clock-position wording for off-path hazards
5. The three dark-camera phrasings, and the offline phrasing
6. Effect of a staged false alarm on trust in later alerts

Report trust, comprehension and workload first; engineering numbers support them.

## 9. Not validated yet

- **Distance calibration** is fitted from two field points and an assumed 1.3 m
  camera height. A clean single-object retest (3, 6, 8, 10 ft) is pending.
- **Street models** were checked on a handful of dataset photos, not on real
  walking video. Cars and people are strong in COCO; potholes were only tested
  on close-up pothole photos and may fire on other road damage or shadows.
- **No closing-speed estimate**, so approaching and parked hazards look the same.
- **Cloud latency** limits usefulness for fast walking, and needs a signal.
- **Priorities are design judgement**, not findings: e.g. treating a bicycle as
  severity 2 and a person as 1. Those are the first things to revisit after
  user testing.
- **No non-speech sound cues** (e.g. a beep whose rate rises with proximity).
  That would strengthen the "sounds very near" idea and is a natural next step.
