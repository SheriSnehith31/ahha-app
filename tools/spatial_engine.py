import time
import math

class AlertGovernor:
    def __init__(self, debounce_sec=3.0):
        self.debounce_sec = debounce_sec
        self.last_alerts = {}
        self.class_priority = {
            "stairs_down": 3, "stairs_up": 2, "obstacle_low": 2,
            "door": 1, "person": 1
        }
        self.h_cam = 1.3
        self.theta_pitch = math.radians(5.0)
        self.fov_v = math.radians(45.0)
        self.y_horizon = 0.45

    def calculate_distance(self, y_max):
        if y_max <= self.y_horizon:
            return 99.0
        angle = self.theta_pitch + (y_max - self.y_horizon) * self.fov_v
        return self.h_cam / math.tan(angle)

    def process_frame_detections(self, detections, current_time=None):
        current_time = current_time or time.time()
        candidates = []
        for det in detections:
            x1, y1, x2, y2, conf = det['box']
            tag = det['tag']
            if conf < 0.40:
                continue
            x_center = (x1 + x2) / 2.0
            y_max = y2
            zone = "left" if x_center < 0.33 else "right" if x_center > 0.66 else "center"
            dist_ft = self.calculate_distance(y_max) * 3.28084
            if dist_ft > 10.0:
                continue
            tier = "immediate" if dist_ft < 5.0 else "warning"
            if zone != "center" and tag != "stairs_down":
                continue
            prio = self.class_priority.get(tag, 1)
            if tier == "immediate" and zone == "center":
                prio += 1
            last_fired = self.last_alerts.get(tag, 0.0)
            debounced_ok = (current_time - last_fired) > self.debounce_sec
            if debounced_ok or (prio >= 3 and tier == "immediate"):
                candidates.append({"tag": tag, "zone": zone, "dist_ft": dist_ft,
                                    "tier": tier, "priority": prio})
        if not candidates:
            return None
        candidates.sort(key=lambda c: (c['priority'], -c['dist_ft']), reverse=True)
        winner = candidates[0]
        self.last_alerts[winner['tag']] = current_time
        return winner


if __name__ == "__main__":
    gov = AlertGovernor()

    # NOTE: with the current placeholder constants, the maximum
    # achievable y_max=1.0 still only computes to ~7.46 ft at pitch=5°.
    # These test frames demonstrate the warning-tier path and normal
    # debounce suppression/clearing, not the immediate (<5ft) tier,
    # which requires real calibration to become reachable.

    test_frames = [
        # Frame 0: stairs_down at y_max=0.95 -> fires, warning tier
        [{"box": [0.4, 0.3, 0.6, 0.95, 0.91], "tag": "stairs_down"}],
        # Frame 1: peripheral person, left zone, non-stairs -> filtered out (silent)
        [{"box": [0.1, 0.3, 0.2, 0.85, 0.70], "tag": "person"}],
        # Frame 2: same stairs_down 0.5s later -> suppressed by 3s debounce -> None
        [{"box": [0.4, 0.3, 0.6, 0.95, 0.91], "tag": "stairs_down"}],
        # Frame 3: same stairs_down 3.5s after Frame 0 -> debounce cleared -> fires again
        [{"box": [0.4, 0.3, 0.6, 0.95, 0.91], "tag": "stairs_down"}],
    ]

    base_time = time.time()
    offsets = [0, 0.5, 0.5, 3.5]
    elapsed = 0
    for i, (frame, offset) in enumerate(zip(test_frames, offsets)):
        elapsed += offset
        result = gov.process_frame_detections(frame, current_time=base_time + elapsed)
        print(f"Frame {i} (t={elapsed}s): {result}")
