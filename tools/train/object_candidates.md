# Candidate datasets for car, person, chair, pothole (requirement C)

**Proposals only. Nothing has been downloaded or merged.** Tell me which to use and I
will add them to `class_map.yaml` for your confirmation, as with the stairs sets.

Everything here comes from Roboflow Universe search listings (name, image count, class
list, license, last update). **I have not looked at any of these datasets' images**, so
viewpoint and label quality are unchecked. The listing shows only the first 20 class names.

I preferred: a permissive license that is actually listed, a viewpoint closer to a
pedestrian than a car dashboard or a CCTV pole, clean class names, and a size that is
worth the download. All are CC BY 4.0 unless stated, which needs attribution.

## car

| # | dataset | images | classes (relevant) | license | updated | notes |
|---|---|---|---|---|---|---|
| 1 | [scottsdale/sidewalk-otzhb](https://universe.roboflow.com/scottsdale/sidewalk-otzhb) | 3,486 | 26, incl. car, bus, truck, motorcycle, bicycle, scooter, person, dog, bench, chair, fire_hydrant, pole | CC BY 4.0 | 2023-05 | "sidewalk" in the name suggests the closest viewpoint to the app; also covers person, chair, dog, bench, hydrant |
| 2 | [fsmvu/street-view-gdogo](https://universe.roboflow.com/fsmvu/street-view-gdogo) | 3,649 | bicycle, bus, car, motorbike, person, truck | CC BY 4.0 | 2023-09 | the most downloaded of these (378 downloads, 10 stars); clean class names; covers car and person |
| 3 | [idd-dataset-uls88/idd_dataset-jhm58](https://universe.roboflow.com/idd-dataset-uls88/idd_dataset-jhm58) | 11,730 | 23, incl. car, bus, truck, motorcycle, rider, person, pothole | CC BY 4.0 | 2025-12 | large; also has pothole and person; **duplicate names differing only in capitals** (Car/car, Bus/bus, Person/person) must be merged; viewpoint not verified |

## person

| # | dataset | images | classes (relevant) | license | updated | notes |
|---|---|---|---|---|---|---|
| 1 | [scottsdale/sidewalk-otzhb](https://universe.roboflow.com/scottsdale/sidewalk-otzhb) | 3,486 | person among 26 | CC BY 4.0 | 2023-05 | same set as above |
| 2 | [rubirubi/pedestrian-yrg5n](https://universe.roboflow.com/rubirubi/pedestrian-yrg5n) | 2,993 | bicycle, bus, car, motorbike, person, pothole, truck, crosswalk, pedestrian signs | CC BY 4.0 | 2025-12 | pedestrian-oriented; also covers car and pothole |
| 3 | [fsmvu/street-view-gdogo](https://universe.roboflow.com/fsmvu/street-view-gdogo) | 3,649 | person among 6 | CC BY 4.0 | 2023-09 | same set as above |

## chair

| # | dataset | images | classes (relevant) | license | updated | notes |
|---|---|---|---|---|---|---|
| 1 | [obstacledetectionforblindpeople/indoor-object-detection-pabhk](https://universe.roboflow.com/obstacledetectionforblindpeople/indoor-object-detection-pabhk) | 9,900 | 14, incl. Chair, Desk, Door, Table | CC BY 4.0 | 2023-05 | workspace name says it was built for blind-user obstacle detection; covers the app's chair/desk/door classes |
| 2 | [yolov5-mgxom/indoor-obstacles-caxcs](https://universe.roboflow.com/yolov5-mgxom/indoor-obstacles-caxcs) | 6,314 | Chair, Door, Person, Stair, Table, Vehicle, objects | CC BY 4.0 | 2025-10 | also has Person and Stair (a single "Stair" class, so no direction) |
| 3 | [myworkspace-6udvv/kadir-has-university-indoor-navigation-dataset](https://universe.roboflow.com/myworkspace-6udvv/kadir-has-university-indoor-navigation-dataset) | 1,687 | 18, incl. chair, door, person, **downstairs, upstairs** | **MIT** | 2026-08 | smaller, but the only one here with direction-labelled stairs; could also add to the stairs data (not proposed for merging yet) |

## pothole

| # | dataset | images | classes | license | updated | notes |
|---|---|---|---|---|---|---|
| 1 | [georgia-institute-of-technology-bwqcc/pothole-detection-mev9q](https://universe.roboflow.com/georgia-institute-of-technology-bwqcc/pothole-detection-mev9q) | 2,742 | pothole | CC BY 4.0 | not listed | the same project as the hosted model the app calls today (`pothole-detection-mev9q/6`), so training on it is not new information for that class |
| 2 | [college-of-science-and-technology-6ve6j/pothole-detection-1ptu6](https://universe.roboflow.com/college-of-science-and-technology-6ve6j/pothole-detection-1ptu6) | 3,061 | Pothole | CC BY 4.0 | not listed | in an earlier live test, its hosted model scored 25% on one pothole photo where #1 scored 99.99% (one image, so only a caution) |
| 3 | [patchsystemworkspace/patch-system-pothole-detection-model-v1](https://universe.roboflow.com/patchsystemworkspace/patch-system-pothole-detection-model-v1) | 1,330 | potholes | **Public Domain** | not listed | smallest; no attribution needed; class name is plural ("potholes") |

IDD (listed under car) also contains a `pothole` class.

## Cautions that apply to all of these

- **Viewpoint:** most road datasets are dashcam or CCTV. The app's camera is a phone at
  chest height. A model can score well on these sets and still do worse on your photos.
  Your own `tools/eval/images/` photos are the only test that counts.
- **Overlap with what you already use:** the current hosted models were trained by others
  on public data, possibly the same data. Adding it again will not add new information.
- **Not proposed:** the COCO listing shows **no license** in Universe, and `final_project`
  (10,311 images) shows none either, so I left both out.
- **Class names differ** between datasets (`motorbike` vs `motorcycle`, `Pothole` vs
  `potholes`); each needs an entry in the class map.
