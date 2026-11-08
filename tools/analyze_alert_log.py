"""
Summarize an AHHA session log copied out of the app
(debug panel -> COPY SESSION LOG, then paste into a text file).

    python tools/analyze_alert_log.py session_log.csv

Reports the cognitive-load and fail-safe numbers described in
docs/alert_design.md: utterances per minute against the 12/min budget, why
speech was withheld, the mix of tiers and proximities, and fail-safe events.
"""

import csv
import statistics
import sys
from collections import Counter

BUDGET_PER_MIN = 12


def load(path):
    # utf-8-sig: Windows editors (Notepad) often save a hidden byte-order mark
    # that would otherwise corrupt the first column name.
    with open(path, newline="", encoding="utf-8-sig") as f:
        return list(csv.DictReader(f))


def peak_in_window(times_ms, window_ms=60_000):
    peak, lo = 0, 0
    for hi in range(len(times_ms)):
        while times_ms[hi] - times_ms[lo] > window_ms:
            lo += 1
        peak = max(peak, hi - lo + 1)
    return peak


def main(path):
    rows = load(path)
    if not rows:
        print("No events in the log.")
        return

    alerts = [r for r in rows if r["kind"] == "alert"]
    spoken = [r for r in alerts if r["spoken"] == "true"]
    withheld = [r for r in alerts if r["spoken"] != "true"]
    duration_s = max(int(r["tMs"]) for r in rows) / 1000.0

    print(f"Session: {duration_s / 60:.1f} min, {len(alerts)} alerts "
          f"({len(spoken)} spoken, {len(withheld)} haptic-only)")

    times = sorted(int(r["tMs"]) for r in spoken)
    if times and duration_s > 0:
        avg = len(spoken) / (duration_s / 60)
        peak = peak_in_window(times)
        verdict = "OVER budget" if peak > BUDGET_PER_MIN else "within budget"
        print(f"\nSpeech load: average {avg:.1f}/min, peak {peak} in any 60 s "
              f"(budget {BUDGET_PER_MIN}) -> {verdict}")
        if len(times) > 1:
            gaps = [(b - a) / 1000 for a, b in zip(times, times[1:])]
            print(f"Gap between spoken alerts: median {statistics.median(gaps):.1f} s, "
                  f"shortest {min(gaps):.1f} s")

    print("\nBy tier (all alerts):    ", dict(Counter(r["tier"] for r in alerts)))
    print("By proximity:            ", dict(Counter(r["proximity"] for r in alerts)))
    print("By hazard:               ", dict(Counter(r["label"] for r in alerts)))
    clipped = sum(1 for r in alerts if r["clipped"] == "true")
    if alerts:
        print(f"Too close to measure:     {clipped}/{len(alerts)} alerts")

    if withheld:
        print("\nSpeech withheld, by reason:", dict(Counter(r["reason"] for r in withheld)))

    events = [r for r in rows if r["kind"].startswith("failsafe")]
    if events:
        print("\nFail-safe events:")
        opened = {}
        for r in events:
            t = int(r["tMs"]) / 1000
            name = r["reason"]
            if r["kind"] == "failsafe_on":
                opened[name] = t
                print(f"  {t:7.1f} s  {name} ON")
            else:
                dur = t - opened.pop(name, t)
                print(f"  {t:7.1f} s  {name} off (lasted {dur:.1f} s)")
        for name, t in opened.items():
            print(f"  {name} still ON at end of log (since {t:.1f} s)")
    else:
        print("\nNo fail-safe events.")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
