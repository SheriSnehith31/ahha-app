"""
AHHA Alert Evaluation Harness (Wizard-of-Oz)
Run this during a seated Tier 2 session. It speaks each alert aloud via
offline TTS, times the participant's acknowledgment, and logs their
interpretation + trust rating to a CSV for later analysis.

Install once: pip install pyttsx3
"""

import pyttsx3
import time
import csv
from datetime import datetime

engine = pyttsx3.init()
engine.setProperty('rate', 165)  # adjust to a natural pace

# --- Test sequence: mix of tiers, wording variants, and a staged false positive ---
# Edit this list freely per session; order matters (keep unpredictable, like real use).
ALERT_SEQUENCE = [
    {"id": "A1", "tier": "critical", "text": "Stop. Stairs down.", "false_positive": False},
    {"id": "A2", "tier": "medium",   "text": "Person center, eight feet.", "false_positive": False},
    {"id": "A3", "tier": "high",     "text": "Obstacle ahead, four feet.", "false_positive": False},
    {"id": "A4", "tier": "medium",   "text": "Stairs down, twelve o'clock, nine feet.", "false_positive": False},
    {"id": "A5", "tier": "critical", "text": "Stop. Stairs down.", "false_positive": True},  # staged false alarm
    {"id": "A6", "tier": "failsafe", "text": "Camera can't see. Check your phone.", "false_positive": False},
    {"id": "A7", "tier": "failsafe", "text": "Too dark to detect hazards. Use your cane.", "false_positive": False},
    {"id": "A8", "tier": "medium",   "text": "Door left, six feet.", "false_positive": False},
]

LOG_FILE = f"tier2_session_{datetime.now().strftime('%Y%m%d_%H%M%S')}.csv"


def run_session(participant_id: str):
    with open(LOG_FILE, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow([
            "participant_id", "alert_id", "tier", "alert_text", "was_false_positive",
            "reaction_latency_sec", "participant_interpretation", "trust_score_1to5",
            "confidence_impact_note"
        ])

        print(f"\n=== Session for participant {participant_id} ===")
        print(f"Logging to {LOG_FILE}\n")

        for alert in ALERT_SEQUENCE:
            input(f"\n[Facilitator] Press Enter to play alert {alert['id']} ({alert['tier']})...")

            start = time.time()
            engine.say(alert["text"])
            engine.runAndWait()

            input("  Waiting for participant reaction — press Enter the moment they respond...")
            latency = round(time.time() - start, 2)

            interpretation = input("  What did the participant say the alert meant? ")
            trust = input("  Trust rating 1-5 ('I would act on this without double-checking'): ")

            confidence_note = ""
            if alert["false_positive"]:
                confidence_note = input(
                    "  This was a STAGED FALSE ALARM. After revealing that, ask: "
                    "did/would this change your confidence in later alerts? Note response: "
                )

            writer.writerow([
                participant_id, alert["id"], alert["tier"], alert["text"],
                alert["false_positive"], latency, interpretation, trust, confidence_note
            ])

        print(f"\nSession complete. Data saved to {LOG_FILE}")


if __name__ == "__main__":
    pid = input("Participant ID (e.g., P1): ")
    run_session(pid)
