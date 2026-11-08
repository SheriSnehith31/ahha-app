# Design Rationale & References

Empirical basis for the alerting parameters in [`tools/spatial_engine.py`](tools/spatial_engine.py).

## Auditory workload / alert debounce (`debounce_sec = 3.0`)

Repeated auditory alerts compete with the primary auditory channel a blind or
low-vision user relies on for navigation. `AlertGovernor` debounces same-tag
alerts to limit that load.

> Wickens, C. D. (2002). Multiple resources and performance prediction.
> *Theoretical Issues in Ergonomics Science*, 3(2), 159–177.
> https://doi.org/10.1080/14639220210123806

Note: do not conflate this with Wickens, C. D. (2008). Multiple resources and
mental workload. *Human Factors*, 50(3), 449–455
(https://doi.org/10.1518/001872008X288394) — a different paper, different
year, different journal. The two are easy to cross-contaminate into a single
fabricated citation (same author, same recurring topic) and must be kept
separate.

## Alert distance tiers (`immediate < 5 ft`, ignored `> 10 ft`)

The long-cane preview radius — the distance ahead at which a cane sweep
detects an obstacle in time to adjust gait — is the baseline for how far out
a supplementary alert needs to fire to be useful rather than redundant or
alarmist.

> Wiener, W. R., Welsh, R. L., & Blasch, B. B. (Eds.). (2010). *Foundations
> of Orientation and Mobility* (3rd ed., Vols. 1–2). AFB Press.

The canonical long-cane preview radius baseline is ~3–4 ft (1.0–1.2 m).
`spatial_engine.py`'s current `immediate` cutoff (5 ft) sits above that
baseline by design margin, not by matching it exactly — worth keeping in
mind if these thresholds are tuned later, since 5 ft is a deliberate
over-preview relative to the cited baseline, not a direct citation of it.

## Verification note

Both entries above were independently re-verified against the publisher
listing (Taylor & Francis) and bookseller/library catalog records before
being added here, rather than taken on trust from a prior session's
self-declared "verified" status.
