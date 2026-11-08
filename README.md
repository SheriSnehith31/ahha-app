# ahha_app

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## Tier 2 evaluation sessions

`tools/tier2_harness.py` runs a seated Wizard-of-Oz session: it speaks each
alert aloud (offline TTS via `pyttsx3`), times the participant's reaction,
and logs their interpretation and trust rating to a timestamped CSV.

```bash
pip install pyttsx3
python tools/tier2_harness.py
```

Each run writes `tier2_session_<timestamp>.csv` into the directory you ran
it from. Run one session per participant.

After collecting sessions from multiple participants, aggregate them from
that same directory:

```bash
python tools/aggregate_results.py
```

This reads every `tier2_session_*.csv` file present and prints, overall and
broken down per tier (critical/high/medium/failsafe): mean and median
reaction latency, the trust-score (1–5) distribution, and a percentage of
correct interpretations. That last number is a keyword-overlap heuristic,
not rigorous grading — see the docstring in `aggregate_results.py` before
citing it directly in a report.

## Modes, models and Roboflow usage

The **MODE** button switches what the app looks for. Each mode calls a
different set of hosted Roboflow models, one call per model per frame:

| Mode | Models called per frame | Finds |
|---|---|---|
| INDOOR (default) | stairs + indoor obstacles (2) | stairs, chairs, desks, doors |
| STREET | stairs + COCO + potholes (3) | above, plus cars, buses, trucks, motorcycles, bicycles, people, dogs, benches, hydrants, potholes |

The Roboflow key lives in `lib/config.dart`, which is gitignored. Hosted
inference uses credits from your Roboflow plan (the free Public plan lists
15 credits a month; models called and images sent are on your workspace's
usage page). STREET makes 50% more calls than INDOOR, so use it on purpose.
If calls start failing (no signal, bad key, credits used up), the app says
"Detection offline" instead of silently seeing nothing.

## Alert design and evaluation

See [docs/alert_design.md](docs/alert_design.md) for how haptic and audio
warnings scale with hazard type and distance, the timing and cognitive-load
rules, trust and fail-safe behaviour, and the evaluation plan.

To record a session: tap the info icon, **COPY SESSION LOG**, paste it into a
file, then:

```bash
python tools/analyze_alert_log.py session_log.csv
```

Tests for the detection and alert rules: `flutter test`.
