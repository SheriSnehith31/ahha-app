# Stairs datasets: what is in them (step 1)

**Nothing has been downloaded, exported, forked, merged or trained.** Requirement B
stopped the pipeline before training (see `STATUS.md`). Everything below comes from
read-only calls to Roboflow Universe through your connection (project metadata, image
listings, search) plus a look at 45 sample images. No Roboflow credits were spent
deliberately, and your API key was never read, printed or saved.

How each number was obtained:
- **images / classes / labels per class**: `projects_get` for each dataset. Cross-checked
  against the Universe listing (same workspace, same image count) so a same-named
  project in another workspace could not be mistaken for it.
- **license**: the Universe listing. Where it was missing, that is said.
- **"viewed"**: I downloaded 3 to 4 sample images per class to a scratch folder (not
  into this repo) and looked at them. That is a spot check, not an audit.
- **overlap**: Roboflow image IDs are copied when a project is copied, so the same ID in
  two datasets means the same image. I compared IDs on the first 40 / 12 images each
  listing returned. Real duplicate counts need the perceptual-hash step (step 3).

Flag thresholds are mine: "very few images" = fewer than 300.

## Summary table

| # | dataset | images | classes | labels per class | license | versions | flags |
|---|---|---|---|---|---|---|---|
| 1 | hohyoo/yolo_stairs | 216 (518 in augmented versions) | `stairs` | stairs 780 | CC BY 4.0 | 5 | single class (no up/down); very few images; **labelled objects are kerbs, not stairs** (viewed) |
| 2 | khairul-kadir/stair-detection-wn5rk | 49 | `stair` | stair 49 | CC BY 4.0 | 2 | single class (no up/down); **very few images**; unusual content (viewed) |
| 3 | talov-ricardo/stairs-mkgsj | 200 (train only, no val/test) | `Stairs` | Stairs 200 | CC BY 4.0 | 1 | single class (no up/down); very few images; likely a copy of other 200-image sets |
| 4 | object-detection-7datn/stairs-hnoru-xyslu | 1000 | `stairs` | stairs 1119 | **not listed for this project** | **0** | single class (no up/down); **no clear license**; **no generated version**, so export may not be possible |
| 5 | stairs-blind/stairs_detection-9av4i | 602 | `0` `1` `2` `stairs` `downstair` `upstair` | 0: 84, 1: 133, 2: 103, stairs: 51, downstair: 92, upstair: 146 | MIT | 2 | **four of six class names are not usable as names** (they are upstairs, see below); shares images with #7 |
| 6 | stairs-blind/up_down_stairs_v2 | 387 | `stairs` | stairs 407 | CC BY 4.0 | 2 | **single class that mixes up and down** (viewed), despite the name |
| 7 | stairs-blind/up_down_stairs | 300 | `downstair` `upstair` | downstair 94, upstair 210 | CC BY 4.0 | 1 | shares images with #5 |
| 8 | itlabroom/updown-u2klg | 2000 | `downstairs` `upstairs` | downstairs 2044, upstairs 1212 | CC BY 4.0 | **0** | **no generated version**; contains augmented-looking images (viewed); overlaps #9 and #5 |
| 9 | itlabroom/upstairs-detection-dataset | 1000 (1 unannotated) | `upstairs` | upstairs 1212 | CC BY 4.0 | 1 | single direction (up only); **looks like a subset of #8** |

Total raw images across the nine: 5,754 **before** removing duplicates. Because of the
overlaps below, the real unique count will be clearly lower. It has not been measured.

## What I found that changes the plan

### 1. Four class names in #5 are upstairs
`0`, `1`, `2` and `stairs` in `stairs_detection-9av4i` are not separate categories.
- **Viewed:** 12 of 12 sample images labelled `0` / `1` / `2` / `stairs` show a staircase
  going **up** away from the camera.
- **Cross-check:** `up_down_stairs` (#7) contains the same images (same IDs). On the 40
  images I could line up, every image labelled `0`, `1`, `2` or `stairs` in #5 (17 of 17)
  is labelled `upstair` in #7. The `downstair` images (10) are `downstair` in both.
  `upstair` images (12) are `upstair` in both. One unannotated image in #5 is `upstair` in #7.
- **Why it matters:** this is consistent with the earlier live test, where the model
  built on #5 answered `"1"` / `"2"` for images labelled `upstair`.
- **Caveat:** this rests on #7's labels being right, and on 40 images. It is evidence,
  not proof for all 609 labels. It is proposed in `class_map.yaml` and needs your OK.

### 2. #1's "stairs" are kerbs
In the 3 annotated sample images from `hohyoo/yolo_stairs`, the labelled object is a
road kerb or pavement edge, not a staircase (n = 3, not an audit). Of 12 sampled
images, 5 had no annotation at all. The project says 216 images but the image search
listed 618. I recommend excluding it.

### 3. #6's single class mixes directions
Of 4 sample images, at least one clearly goes up and at least one clearly goes down.
Mapping it to either direction would be a guess, so it is not mapped.

### 4. Heavy overlap, so duplicates are coming
- #7 and #5 share IDs (40 of 40 sampled).
- #9 looks like a subset of #8: 12 of 12 sampled IDs appear in both with the same
  class, and the `upstairs` label count is identical (1,212).
- One #8 `upstairs` image (a staircase with a blue mat and a butterfly picture) appears
  to be the same photo as an image in #5, so #8 also overlaps the stairs-blind family.
- #3 has the same name, class and image count (200) as two datasets from another
  workspace ("Practicas"); likely a copy, not verified.
- Expect step 3 (perceptual-hash de-duplication) to remove a large share. Report the
  real number then.

### 5. #8 contains augmented-looking images
1 of 6 sampled #8 images has black rectangles baked into the pixels (a cut-out
augmentation). If augmented copies of one photo are in the data, a train/validation
split can leak the same photo into both. De-duplicate before splitting.

### 6. Two datasets cannot be exported as they stand
#4 and #8 report no generated version. A YOLOv8 export normally comes from a version.
This is untested; it is what the metadata says. Their license/version state is the
reason they are flagged, not a failed download.

### 7. License notes
- All listed licenses are CC BY 4.0 except #5 (MIT). CC BY 4.0 requires attribution, so
  keep a credits file for every dataset that is used.
- **#4 has no listing of its own**, so its license is not confirmed. A sibling,
  `mari-xbhzc/stairs-hnoru` (same name, annotation group and 1000 images), is listed as
  CC BY 4.0 and is probably the original, but that is a different project, so I have not
  assumed it applies.
- The Universe web pages returned 403 to a plain fetch, so I could not read licenses off the pages.

## Not tested
- Whether each dataset can actually be downloaded through the connection (login,
  permissions, download limits). That needs an export, which I did not start.
- Real duplicate counts, image quality, label correctness beyond the spot checks.
- Anything about how a model trained on these would do on your photos.
