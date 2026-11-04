#!/usr/bin/env python3
"""Capture Hps2 renderer logs and readable thermal sensors; never invent missing values."""
import argparse
from datetime import datetime
from pathlib import Path
import shutil
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds", type=int, default=120)
    parser.add_argument("--target", help="HDC target; required only when more than one device is connected")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.seconds <= 0:
        parser.error("--seconds must be positive")
    hdc = shutil.which("hdc") or "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc"
    targets = subprocess.run([hdc, "list", "targets"], capture_output=True, text=True, check=True)
    devices = [line.strip() for line in targets.stdout.splitlines() if line.strip() and line.strip() != "[Empty]"]
    if not devices:
        parser.exit(2, "No HDC device connected; no capture started.\n")
    target = args.target or (devices[0] if len(devices) == 1 else None)
    if not target or target not in devices:
        parser.error("select a connected device with --target")
    command = [hdc, "-t", target]
    output = args.output or Path(__file__).resolve().parents[1] / ".diag" / (
        "renderer-" + datetime.now().strftime("%Y%m%d-%H%M%S"))
    output.mkdir(parents=True, exist_ok=True)
    baseline = subprocess.run(command + ["shell", "hilog", "-x", "-T", "HPS2_CORE"],
                              capture_output=True, text=True, timeout=15, check=True)
    old_lines = set(baseline.stdout.splitlines())
    # Raw sensor values retain the kernel's units and labels. Access failure is explicit.
    thermal_command = '''found=0
for z in /sys/class/thermal/thermal_zone*; do
  if [ -r "$z/temp" ]; then
    printf '%s type=' "$z"
    cat "$z/type" 2>/dev/null
    printf 'temp_raw='
    cat "$z/temp"
    found=1
  fi
done
if [ "$found" = 0 ]; then echo 'thermal=unavailable'; fi'''
    with (output / "hilog.txt").open("w") as log, (output / "thermal.txt").open("w") as thermal:
        # Keep existing startup evidence; the live stream then continues for this window.
        process = subprocess.Popen(command + ["shell", "hilog", "-T", "HPS2_CORE"], stdout=log, stderr=log)
        try:
            start = time.monotonic()
            print(f"Capturing for {args.seconds}s into {output}; load the comparison save now.", flush=True)
            while time.monotonic() - start < args.seconds:
                if process.poll() is not None:
                    raise RuntimeError("HDC log stream ended early; inspect hilog.txt")
                thermal.write(f"elapsed_s={time.monotonic() - start:.3f}\n")
                sample = subprocess.run(command + ["shell", thermal_command], capture_output=True, text=True, timeout=10)
                thermal.write(sample.stdout or "thermal=unavailable\n")
                if sample.returncode:
                    thermal.write(f"hdc_exit={sample.returncode}\n{sample.stderr}")
                thermal.flush()
                time.sleep(min(5, max(0, args.seconds - (time.monotonic() - start))))
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
    signals = [line for line in (output / "hilog.txt").read_text(errors="replace").splitlines()
               if line not in old_lines and
               ("RENDERER_DIAG:" in line or "PERF:" in line or "PERF_DIAG:" in line)]
    (output / "signals.txt").write_text("\n".join(signals) + "\n")
    if not any("PERF_DIAG:" in line for line in signals):
        parser.exit(3, "Capture saved, but no PERF_DIAG samples found; do not use as a renderer comparison.\n")
    print(f"Saved {len(signals)} signal lines into {output / 'signals.txt'}")


if __name__ == "__main__":
    main()
