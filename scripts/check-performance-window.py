#!/usr/bin/env python3
"""Check a captured Hps2 PERF window against a full-speed acceptance threshold."""

import argparse
import json
import statistics
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path, help="capture.py summary.json")
    parser.add_argument("--min-speed", type=float, default=95.0)
    parser.add_argument("--min-internal-fps", type=float,
                        help="Also require valid internal FPS on every point; VPS alone never satisfies this gate")
    args = parser.parse_args()
    capture = json.loads(args.capture.read_text())
    rows = capture["rows"]
    if len(rows) < 20:
        parser.error("At least 20 real PERF records are required")
    median = {key: statistics.median(row[key] for row in rows)
              for key in ("fps", "speed", "ee_ms", "gs_ms", "fr_avg")}
    passed = all(row["speed"] >= args.min_speed for row in rows)
    internal_valid = all(row.get("ifps_valid") == 1 and row.get("ifps", -1) >= 0 for row in rows)
    if internal_valid:
        median["internal_fps"] = statistics.median(row["ifps"] for row in rows)
    if args.min_internal_fps is not None:
        if args.min_internal_fps <= 0:
            parser.error("--min-internal-fps must be positive")
        passed = passed and internal_valid and all(row["ifps"] >= args.min_internal_fps for row in rows)
    print(json.dumps({"pass": passed, "points": len(rows), "medians": median,
                      "min_speed": min(row["speed"] for row in rows),
                      "required_speed": args.min_speed,
                      "internal_fps_valid": internal_valid,
                      "required_internal_fps": args.min_internal_fps}, ensure_ascii=False))
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
