#!/usr/bin/env python3
"""Check a session diagnostics.json for monitor routing safety.

Rules:
  * The capture/tap device and the monitor output must be different devices.
    In particular the HomePod Flow virtual sink must never be used as the
    monitor output.
  * When an AudioProbe `list` capture is supplied, the monitor UID must exist,
    have output channels, and must not have transport "Virtual".
  * The monitor output sample rate must be positive and there must be no
    "cannot set monitor output" warning.
  * With --expect-takeover, diagnostics.outputTakeOver must be true (the app
    took over the system default output and still monitored on a physical
    device).

This checks configuration and diagnostics only. It cannot prove that the user
actually heard audio; that remains a manual listening check.

Usage:
  verify_monitor_route.py --diagnostics diagnostics.json \
      [--audioprobe-list audioprobe-list.txt] [--expect-takeover]
"""

import argparse
import json
import re
import sys


def parse_devices(text):
    """Parse the human-readable `AudioProbe list` output into UID -> fields."""
    devices = {}
    current = None
    for line in text.splitlines():
        match = re.match(r"^\[(\d+)\]\s+(.*)$", line)
        if match:
            current = {"id": int(match.group(1)), "name": match.group(2)}
            devices[current["id"]] = current
            continue
        if current is None:
            continue
        match = re.match(r"^\s*UID\s*:\s*(\S+)\s*$", line)
        if match:
            current["uid"] = match.group(1)
            continue
        match = re.match(r"^\s*transport\s*:\s*(.*?)\s*\(", line)
        if match:
            current["transport"] = match.group(1).strip()
            continue
        match = re.match(r"^\s*direction\s*:\s*in=(\d+)ch\s*/\s*out=(\d+)ch", line)
        if match:
            current["in"] = int(match.group(1))
            current["out"] = int(match.group(2))
            continue
    return {device.get("uid"): device for device in devices.values() if device.get("uid")}


def add(checks, name, passed, detail):
    checks.append({"name": name, "pass": bool(passed), "detail": detail})


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--diagnostics", required=True)
    parser.add_argument("--audioprobe-list")
    parser.add_argument("--expect-takeover", action="store_true")
    parser.add_argument("--json-out")
    args = parser.parse_args(argv)

    with open(args.diagnostics, encoding="utf-8") as handle:
        diagnostics = json.load(handle)

    tap_uid = (diagnostics.get("tap") or {}).get("deviceUID")
    monitor = diagnostics.get("monitor") or {}
    monitor_uid = monitor.get("outputDeviceUID")
    checks = []
    add(checks, "diagnostics has tap UID", bool(tap_uid), "tap.deviceUID=%s" % tap_uid)
    add(checks, "diagnostics has monitor output UID", bool(monitor_uid),
        "monitor.outputDeviceUID=%s" % monitor_uid)
    add(checks, "monitor output differs from capture device",
        bool(tap_uid and monitor_uid and tap_uid != monitor_uid),
        "tap=%s monitor=%s" % (tap_uid, monitor_uid))
    add(checks, "monitor output sample rate is positive",
        float(monitor.get("outputSampleRate") or 0) > 0,
        "outputSampleRate=%s" % monitor.get("outputSampleRate"))
    warnings = monitor.get("warnings") or []
    add(checks, "no monitor output setup warning",
        not any("无法设置监听输出设备" in warning for warning in warnings),
        "warnings=%s" % warnings)

    if args.audioprobe_list:
        with open(args.audioprobe_list, encoding="utf-8") as handle:
            devices = parse_devices(handle.read())
        device = devices.get(monitor_uid)
        add(checks, "monitor UID is a known device", device is not None,
            "uid=%s" % monitor_uid)
        if device:
            add(checks, "monitor device has output channels",
                int(device.get("out", 0)) > 0,
                "direction out=%s" % device.get("out"))
            add(checks, "monitor device is not virtual",
                "Virtual" not in (device.get("transport") or ""),
                "transport=%s" % device.get("transport"))

    if args.expect_takeover:
        add(checks, "system output takeover was active",
            bool(diagnostics.get("outputTakeOver")),
            "outputTakeOver=%s" % diagnostics.get("outputTakeOver"))

    report = {
        "tool": "verify_monitor_route.py",
        "diagnostics": args.diagnostics,
        "tapUID": tap_uid,
        "monitorUID": monitor_uid,
        "outputTakeOver": diagnostics.get("outputTakeOver"),
        "checks": checks,
        "pass": all(check["pass"] for check in checks),
    }
    text = json.dumps(report, ensure_ascii=False, indent=2)
    if args.json_out:
        with open(args.json_out, "w", encoding="utf-8") as handle:
            handle.write(text + "\n")
    print(text)
    return 0 if report["pass"] else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
