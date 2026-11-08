# Training pipeline status

**Stopped at requirement B. Nothing was trained, merged, downloaded or evaluated.**

## Requirement B: your photos (checked 2026-11-08 00:29)

`tools/eval/images/` has **0 photos in every label folder**. Each of the 7 labels needs
at least 30:

| label | photos now | needed |
|---|---|---|
| stairs_down | 0 | 30 |
| stairs_up | 0 | 30 |
| clear | 0 | 30 |
| car | 0 | 30 |
| person | 0 | 30 |
| pothole | 0 | 30 |
| chair | 0 | 30 |

Include photos from your own phone, held upright at chest height, the way the app is used.
Your photos are the test set and are never used for training or validation.

## What was done (needs no photos, no downloads, no credits)

| item | result | file |
|---|---|---|
| Step 1: dataset tables and flags | done from metadata + 45 spot-check images | `datasets_overview.md` |
| Step 2: class map | drafted, **waiting for your confirmation** | `class_map.yaml` |
| C: candidates for car, person, chair, pothole | 3 per class, with licenses | `object_candidates.md` |

## What was NOT done, and why

| item | why |
|---|---|
| Download / export of the 9 datasets | stopped by B; the class map must be confirmed before any merge anyway. Whether each can be downloaded is **untested** |
| Step 3 merge, de-duplication, caps | needs your class-map confirmation and the downloads |
| A: harness run on the current model (normal and `--send-upright`) | needs your photos; it would also spend API calls |
| Step 5 training / Colab notebook | stopped by B. This machine has only Intel integrated graphics (no NVIDIA GPU), so training would go to Colab; `ultralytics` is not installed here |
| Step 6 TFLite export and size | no model exists |
| Step 7 comparison | no model and no photos. `compare.md` says so |
| D: inference speed | no new model to time. When it exists, a PC timing of the TFLite model is **not** phone speed, and I will not estimate phone speed |
| E: `integration.md` | the plan depends on the trained model's size, input size and results, so writing it now would be guesswork |
| F: 11:00 time limit | not reached (it was 00:29 at the check); moot while B blocks training |

## Recommendation (a suggestion)

**Keep the current setup.** There is no new model and no measured evidence that one would
be better. This is not a verdict on the idea, only on what exists today.

## To go on

1. Add at least 30 photos per label folder in `tools/eval/images/`.
2. Answer the 5 questions at the top of `class_map.yaml`.
3. Pick the object datasets from `object_candidates.md`, or say to skip objects for now.
