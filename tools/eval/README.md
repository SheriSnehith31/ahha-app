# Detector self-test

Measures how well the app's *current* detection and alert pipeline works on
labelled photos, before anything new is trained. It reports what it measured
and nothing else; it never quotes accuracy from memory or from a model
provider.

It adds files only under `tools/eval/`. It does not change the app,
`detection_logic.dart`, `alert_policy.dart`, or `tier2_harness.py`.

## 1. Add photos

Put photos in `tools/eval/images/<label>/`. The folder name is the ground truth.
Create the standard folders with:

```bash
dart tools/eval/run_eval.dart --init
```

| folder | what goes in it |
|---|---|
| `stairs_down/` | stairs going down |
| `stairs_up/` | stairs going up |
| `clear/` | scenes with **no** hazard (this is what measures false alarms), indoor and outdoor |
| `car/` | a car, bus or truck in the path |
| `person/` | a pedestrian |
| `pothole/` | a pothole |
| `chair/` | a chair (indoor mode) |

Also supported: `bus`, `truck`, `motorcycle`, `bicycle`, `dog`, `bench`,
`fire_hydrant`, `desk`, `door`.

**How many:** at least **30 per folder**. Below that the report says "too few to
judge" instead of giving a verdict. Include photos from your own phone, held
upright at chest height the way the app is used. Photos taken any other way
give distances that do not match what the app would compute.

## 2. See the cost, then run

```bash
dart tools/eval/run_eval.dart --plan     # counts API calls, makes none
dart tools/eval/run_eval.dart            # shows the plan, asks you to type "yes"
```

For the recommended 30 photos in each of the 7 standard folders, a first run
needs about **690 live API calls**. (Stairs and clear photos run in both street
and indoor mode; the rest run only in the mode that can find them.) Every
response is cached in `tools/eval/cache/`, so reruns make no new calls. **Keep
that folder**; deleting it means paying for the calls again. A failed call is
not cached, so it is retried next time.

Credits are **not measured** by this tool; it counts calls. To get the real
credit figure, note your Roboflow usage page before and after a run.

The key is read from `ROBOFLOW_API_KEY` if set, otherwise from `lib/config.dart`
(the same key the app uses). It is never printed.

## Options

| option | meaning |
|---|---|
| `--plan` | count calls, make none |
| `--yes` | skip the "type yes" confirmation |
| `--modes auto\|street\|indoor\|both` | `auto` (default) runs each photo only in the mode(s) that can find its label |
| `--resize N` | shrink photos so the longest side is N px. The app sends a much smaller frame than a phone photo; its debug panel shows the real size ("Server saw") |
| `--send-upright` | see "Photo rotation" below |
| `--max-calls N` | refuse to run if more than N new calls are needed |
| `--min-per-label N` | photos needed before judging a label (default 30) |

A run stops by itself after 5 live calls in a row fail (bad key, no signal, quota),
instead of burning calls.

## Output

- `report.md`: results by label, false alarms on clear photos, confusions,
  latency, the 10 worst failures, the words that would be spoken for every
  photo, calls used, a plain-language diagnosis, and what was **not** tested.
- `results.csv`: one row per photo and mode, including the spoken text.

The diagnosis is labelled as suggestions. Its thresholds (30 photos, 70% recall,
10% false alarms, 1 s latency) are this tool's own choices and are printed in
the report.

## How it matches the app

**Reused directly (imported):** `lib/detection_logic.dart` and
`lib/alert_policy.dart`.

**Copied from `lib/main.dart`** (it needs Flutter, so a plain Dart script cannot
import it): model ids and class tables, the request format, frame preparation,
and the response-to-pipeline glue. At every run the tool reads `main.dart` and
warns if the models, request headers, timeout, distance settings or JPEG quality
have changed. It cannot detect a class added to an allow-list.

Each photo is replayed as 3 identical frames, 1 s apart, through a fresh
pipeline, as the app would see a hazard that stays put. It cannot show flicker,
motion or a changing scene.

## Photo rotation (a finding)

The image library's decoder already rotates a photo according to its EXIF tag
and then clears the tag. The app's own "bake rotation" step looks for that tag
after decoding, so it never runs, and the app sends the **original bytes**: the
unrotated pixels plus the tag. This tool reproduces that. If any of your photos
carry a rotation tag, the report says how many. Whether the server honours the
tag was not measured; run once with `--send-upright` (re-encodes from upright
pixels, so no tag is sent) and compare. That costs new calls because the bytes differ.

## Tests for the tool itself

```bash
flutter test tools/eval/eval_core_test.dart
```

These use a fake API and synthetic images in a temp folder. They check the
tool's own bookkeeping (parsing, caching, scoring, the diagnosis rules) and say
nothing about how good the real models are. Nothing from them is ever written
to `report.md`.
