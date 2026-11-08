"""
Aggregates AHHA Tier 2 evaluation session CSVs (tier2_session_*.csv found in
the current working directory) and prints per-tier and overall summary
statistics: mean/median reaction latency, trust score distribution, and
percentage of correct interpretations.

Run from the same directory the sessions were run in (see README):
    python tools/aggregate_results.py

NOTE on "correct interpretation": tier2_harness.py logs the participant's
interpretation as free text, not a boolean. This script scores it with a
simple keyword-overlap heuristic against the alert's own wording (e.g. does
"stairs" appear in both the alert text and what the participant said) — this
is NOT rigorous NLP grading, just a rough pass to spot trends across many
rows. Spot-check a few rows per session before quoting the percentage in a
report; hand-correct clearly wrong classifications if you're citing this
number directly.
"""

import csv
import glob
import re
import statistics
from collections import defaultdict

STOPWORDS = {
    "stop", "ahead", "feet", "foot", "center", "left", "right", "up", "down",
    "o'clock", "use", "your", "check", "cant", "cannot", "see", "too", "to",
    "detect", "hazards", "the", "a", "an", "at", "on", "twelve", "nine",
    "eight", "four", "six",
}


def keywords(text):
    words = re.findall(r"[a-z']+", (text or "").lower())
    return {w.strip("'") for w in words if w not in STOPWORDS and len(w) > 2}


def is_correct(alert_text, interpretation):
    expected = keywords(alert_text)
    given = keywords(interpretation)
    return bool(expected & given)


def load_rows():
    rows = []
    for path in sorted(glob.glob("tier2_session_*.csv")):
        with open(path, newline="") as f:
            for row in csv.DictReader(f):
                row["_source_file"] = path
                rows.append(row)
    return rows


def summarize(rows, label):
    if not rows:
        print(f"  ({label}: no rows)")
        return

    latencies = []
    for r in rows:
        try:
            latencies.append(float(r["reaction_latency_sec"]))
        except (KeyError, ValueError, TypeError):
            pass

    trust_scores = []
    for r in rows:
        try:
            trust_scores.append(int(r["trust_score_1to5"]))
        except (KeyError, ValueError, TypeError):
            pass

    correct_flags = [
        is_correct(r.get("alert_text", ""), r.get("participant_interpretation", ""))
        for r in rows
    ]

    print(f"  {label}  (n={len(rows)})")
    if latencies:
        print(f"    Reaction latency:  mean={statistics.mean(latencies):.2f}s  "
              f"median={statistics.median(latencies):.2f}s")
    else:
        print("    Reaction latency:  no valid data")

    if trust_scores:
        dist = defaultdict(int)
        for s in trust_scores:
            dist[s] += 1
        dist_str = ", ".join(f"{k}:{dist[k]}" for k in sorted(dist))
        print(f"    Trust score dist:  {dist_str}  "
              f"(mean={statistics.mean(trust_scores):.2f})")
    else:
        print("    Trust score:       no valid data")

    pct_correct = 100 * sum(correct_flags) / len(correct_flags)
    print(f"    Correct interp.:   {pct_correct:.0f}%  "
          f"(heuristic keyword match, see script docstring)")


def main():
    rows = load_rows()
    if not rows:
        print("No tier2_session_*.csv files found in the current directory.")
        return

    files = sorted({r["_source_file"] for r in rows})
    print(f"Loaded {len(rows)} rows from {len(files)} session file(s):")
    for f in files:
        print(f"  - {f}")

    print("\n=== Overall ===")
    summarize(rows, "All tiers")

    print("\n=== By tier ===")
    by_tier = defaultdict(list)
    for r in rows:
        by_tier[r.get("tier", "unknown")].append(r)
    for tier in sorted(by_tier):
        summarize(by_tier[tier], tier)


if __name__ == "__main__":
    main()
