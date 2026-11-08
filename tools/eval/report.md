# AHHA detector self-test report

**NO RESULTS. No photos were found in `tools/eval/images/<label>/`, so nothing was run and no API calls were made.**

To get results, add photos (the label is the folder name):

| folder | what goes in it |
|---|---|
| `stairs_down/` | stairs going down away from the camera |
| `stairs_up/` | stairs going up |
| `clear/` | scenes with NO hazard (measures false alarms), both outdoor and indoor |
| `car/` | a car, bus or truck in the path |
| `person/` | a pedestrian |
| `pothole/` | a pothole |
| `chair/` | a chair, desk or door (indoor mode) |

Aim for **at least 30 photos per folder**, including some taken on your own phone held upright at chest height, the way the app is used. Fewer than that is too few to say anything reliable.

Then run `dart tools/eval/run_eval.dart --plan` to see how many API calls it would make, and `dart tools/eval/run_eval.dart` to run it.

This file is overwritten by every run.
