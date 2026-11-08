# GenAI Use Log — AHHA

Tool: Claude Code (Sonnet 5). Log covers actual sessions working in this
repo; entries are reconstructed from the real prompt/change record, not
summarized from memory.

## Session — 2026-09-13

**Prompt**: Verify two bibliography entries pasted from a prior AI session
(Wickens 2002 MRT paper; Wiener/Welsh/Blasch 2010 *Foundations of
Orientation and Mobility*) — the prior session had already flagged and
corrected a "chimera citation" (grafting a 2008 Human Factors publication
year onto the 2002 Taylor & Francis article).

**What was done**: Independently re-verified both citations against
publisher/catalog sources (Taylor & Francis DOI resolution, bookseller/
library listings) rather than trusting the prior session's self-declared
"verified" status. Both checked out. Wrote [`REFERENCES.md`](../REFERENCES.md)
tying each citation to the specific code constants it justifies
(`debounce_sec`, the 5 ft/10 ft distance tiers in `spatial_engine.py`).

**Prompt**: Apply four concrete code changes:
1. `lib/main.dart` — `_pitch` calibration constant, 5.0° → 12.0° (explicitly
   a placeholder estimate, not a final calibrated value).
2. `lib/main.dart` — replace deprecated `.withOpacity()` with
   `.withValues(alpha:)`.
3. `tools/spatial_engine.py` — fix the `__main__` test block, whose comments
   claimed distances/tier outcomes that didn't match what the code actually
   computed.
4. Re-verify via `flutter analyze`, `python tools/spatial_engine.py`, and
   `flutter build apk --debug`.

**What was done**: All three edits applied. `flutter analyze` required
`flutter pub get` first (packages hadn't been fetched). Ran the *original*
test block in a scratch copy to capture the real "before" output
(`None, None, None` for all three frames — confirming the bug: the old
comments claimed Frame 0 fired, but the actual y_max value put it over the
10 ft cutoff) versus the corrected block's output (fires → filtered →
debounce-suppressed → fires again after 3.5s), matching spec exactly.
`flutter build apk --debug` failed for an unrelated reason (see next entry).

**Prompt**: Fix a Gradle/JDK mismatch blocking the debug build (Gradle
invoking JVM 8 despite `JAVA_HOME` pointing to JDK 17); find the real JDK
path rather than guessing one.

**What was done**: Confirmed `JAVA_HOME=C:\Program Files\Java\jdk-17` via
`echo`/`where java`, verified that path actually runs `java -version` as
17.0.12 before writing it anywhere. Added
`org.gradle.java.home=C:/Program Files/Java/jdk-17` to
[`android/gradle.properties`](../android/gradle.properties). Re-ran
`flutter build apk --debug` — succeeded (`app-debug.apk` built).

## Session — 2026-09-16

**Prompt**: Given the submitted proposal recap and the "Alert Design &
Evaluation Plan" doc (Tier 1 Critical/High/Medium wording+timing table,
trust/cognitive-load evaluation protocol, 3 fail-safe phrasing candidates),
implement what's actionable now versus flag what requires the user's own
action (human evaluation sessions, physical calibration, real API
credentials, video/deck production).

**What was done**:
- Implemented the Critical/High/Medium tier table into
  `_processDetections`/`_dispatchAlert` in `lib/main.dart`: imperative
  "Stop. Stairs down." with no distance for Critical (bypasses debounce,
  preempts any currently-speaking utterance); "[Object] ahead, [distance]."
  for High (preempts a playing/queued Medium utterance only); "[Object]
  [zone], [distance]." for Medium (queued, respects the 3s debounce).
  Added a distinct fast-triple-pulse haptic pattern for Critical.
  **Judgment call**: applied the "speech only re-fires on real change"
  rule to High/Medium only, not Critical — a hazard this urgent should
  always announce in full even if distance is unchanged frame-to-frame;
  flagging this so it can be revisited if the Tier 2 session suggests
  otherwise.
- Added the 3 fail-safe phrasings as a swappable indexed list
  (`_failSafePhrasings` / `_activeFailSafeIndex`) so switching which one
  fires during a Tier 2 A/B run is a one-line change instead of editing
  the alert logic.
- Re-verified with `flutter analyze` (clean) and `flutter build apk --debug`
  (succeeded) after the rewrite.
- Ran a web research pass on public statements from Molly Burke, Tommy
  Edison, and Lucy Edwards, plus academic/industry sources on
  clock-position vs. left/right navigational phrasing, to inform (not
  replace) the Tier 2 session's question design — written up in
  [`secondary_research_notes.md`](secondary_research_notes.md), including an
  explicit caveat that it's a hypothesis generator, not a citable finding.
- Declined to do, and explicitly flagged back to the user: running the
  actual Tier 2 seated evaluation, the physical calibration walk, sourcing
  a real Roboflow API key, and producing the demo video/deck — none of
  these can be done without the user's physical presence or credentials.

## Sessions 2026-09-16 to 2026-09-18 (per-item dates approximate)

Reconstructed from the conversation record. Kept to what was asked, what was
done, and where the assistant pushed back or could not verify.

- **Debug overlay, Tier 2 harness, aggregator.** Added an on-screen debug
  overlay; placed `tools/tier2_harness.py` verbatim from a script the user
  pasted (the assistant had first pointed out that no such script existed in the
  conversation, rather than inventing one); wrote `aggregate_results.py`, whose
  "correct interpretation" figure is a keyword heuristic and is documented as
  such.
- **Roboflow integration.** Wired in two hosted models called concurrently with
  Bearer-header auth. The user pasted a live API key into the chat; the
  assistant recommended rotating it, and it was rotated through the Roboflow
  MCP connection (old key revoked). A scoped, inference-only key was not
  possible on the free plan, so the replacement is full-access. An attempt by
  the assistant to pipe a login token into the Roboflow CLI was blocked by the
  safety classifier as credential materialization; the assistant did not work
  around it and asked the user to log in themselves.
- **Stairs model swap.** One candidate dataset had no trained model at all;
  a second scored 88-97% but predicted meaningless numeric classes for
  upstairs, so it was rejected; a third was integrated after real test calls.
- **Corrected false premises.** A "grid overlay" the user believed had
  regressed had never been built; the assistant said so and built it. A visual
  check of the redesigned screen was attempted in the browser pane but the app
  never rendered there, and the assistant reported that instead of claiming
  the layout was confirmed.
- **Full UI redesign** (top bar, zone grid, bounding box, banner, status lines,
  HAPTIC/AUDIO/PAUSE controls) and a fail-safe fix (speak once, then haptic
  reminders only).
- **Distance errors from a physical test.** Diagnosed a 5.7 ft floor in the
  calibration constants and refit them from two usable field points (assuming
  an unmeasured 1.3 m camera height). Added a "too close to measure" fallback,
  multi-frame confirmation, median smoothing and frame-orientation baking;
  extracted the logic into `lib/detection_logic.dart` with unit tests and fixed
  a smoothing warm-up gap the tests exposed. The 2 ft ceiling test was skipped
  by the user's decision to keep the upright posture.
- **Not verified on a device:** none of this was run on a phone by the
  assistant. Distance calibration remains a fit from two points.

## Session 2026-09-20

**Prompt**: Improve the alerts for street use (cars, people, potholes); make very
near hazards sound and feel very near; say distance when something is in the
way; and, per the professor's feedback, prioritise design and evaluation of
haptic/audio warnings, timing, cognitive load, trust and fail-safe
communication. Also asked what resources were needed and whether they were free.

**What was done**:
- Checked Roboflow Universe and tested candidate models on real photos before
  choosing any. COCO `coco/50` chosen over `coco/3` (which missed most of the
  people and cars); a Georgia Tech pothole model chosen over another that scored
  25%. Confirmed the new model IDs work with the app's exact request format.
  **No model was trained and no credits were deliberately spent beyond a few
  test calls.**
- Cost: the free Public plan lists 15 credits/month (roboflow.com/pricing). The
  per-call price for object detection could **not** be confirmed from the
  documentation pages that could be read, so no usage estimate is given. The
  user was told to check their usage page.
- Added STREET/INDOOR modes, hazard severity x proximity x path tiering,
  distance-scaled haptics and voice, a tiered speech budget, a "detection
  offline" fail-safe, and a copyable session log. Wrote
  [`alert_design.md`](alert_design.md) mapping each of the professor's
  priorities to the implementation and evaluation plan.
- Unit tests: 79 passing, 2 skipped by design.
- Fixed a byte-order-mark bug found while testing `analyze_alert_log.py`.

**Limits stated in the design document**: nothing was tested with real users
or on a phone; severity and threshold choices are design judgement; the
pipeline's latency limits it to slow walking; street models were checked on a
handful of dataset photos, not on walking video.

## Note on this log itself

This file was drafted by Claude Code from its own actual tool-call/edit
history in this repo, at the user's request, rather than from the user's
memory of what happened — cross-check dates/details against your own
memory before submitting if this log itself is a graded artifact.
