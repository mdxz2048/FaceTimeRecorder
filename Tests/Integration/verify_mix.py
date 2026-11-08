#!/usr/bin/env python3
"""Verify FaceTime Recorder mux outputs without a GUI or TCC.

Checks:
  * MP4 has exactly one audio track (the default-playback mix).
  * MKV audio track order/titles are Mix, Remote, Microphone (when a mic track
    is expected).
  * Named synthetic tones are present at a reasonable level in the tracks that
    should contain them, and absent from the tracks that should not.

This is an offline file-level check. It does not prove that live capture or a
real FaceTime call produced the audio.

Usage:
  verify_mix.py --mp4 FaceTime.mp4 --mkv FaceTime.mkv \
      --remote-hz 440 --mic-hz 880 [--expect-mic] [--require-video]

Exit codes: 0 pass, 1 failed check, 2 usage/environment error.
"""

import argparse
import json
import math
import os
import shutil
import struct
import subprocess
import sys
import tempfile

SAMPLE_RATE = 48_000


def find_tool(name, override):
    if override:
        return override
    found = shutil.which(name)
    if found:
        return found
    for candidate in ("/opt/homebrew/bin/" + name, "/usr/local/bin/" + name):
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    raise SystemExit("cannot find %s; pass --%s PATH" % (name, name))


def probe(path, ffprobe):
    output = subprocess.check_output(
        [ffprobe, "-v", "error", "-show_streams", "-show_format", "-of", "json", path],
        text=True,
    )
    return json.loads(output)


def audio_streams(probed):
    return [stream for stream in probed.get("streams", [])
            if stream.get("codec_type") == "audio"]


def video_streams(probed):
    return [stream for stream in probed.get("streams", [])
            if stream.get("codec_type") == "video"]


def tag(stream, *names):
    tags = stream.get("tags") or {}
    for name in names:
        if name in tags:
            return tags[name]
        for key, value in tags.items():
            if key.lower() == name.lower():
                return value
    return None


def decode_mono(path, audio_ordinal, ffmpeg, destination):
    subprocess.check_call(
        [ffmpeg, "-v", "error", "-y", "-i", path,
         "-map", "0:a:%d" % audio_ordinal,
         "-ac", "1", "-ar", str(SAMPLE_RATE), "-f", "s16le", destination],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    with open(destination, "rb") as handle:
        raw = handle.read()
    count = len(raw) // 2
    samples = struct.unpack("<%dh" % count, raw[:count * 2])
    return samples


def goertzel(samples, frequency):
    """Return the raw Goertzel magnitude for one bin."""
    count = len(samples)
    if count == 0:
        return 0.0
    k = int(0.5 + count * frequency / SAMPLE_RATE)
    omega = 2.0 * math.pi * k / count
    coefficient = 2.0 * math.cos(omega)
    s1 = 0.0
    s2 = 0.0
    for value in samples:
        s0 = value + coefficient * s1 - s2
        s2 = s1
        s1 = s0
    squared = s1 * s1 + s2 * s2 - coefficient * s1 * s2
    return math.sqrt(max(0.0, squared)) / count


def measure(samples, frequencies):
    """Peak amplitude estimate per frequency (0..1 full scale) and RMS."""
    if not samples:
        return {"rms": 0.0, "amplitudes": {str(f): 0.0 for f in frequencies}}
    rms = math.sqrt(sum((value / 32768.0) ** 2 for value in samples) / len(samples))
    amplitudes = {}
    for frequency in frequencies:
        # A full-scale sine of amplitude A produces a Goertzel magnitude of
        # A * 32768 / 2.
        amplitudes[str(frequency)] = 2.0 * goertzel(samples, frequency) / 32768.0
    return {"rms": rms, "amplitudes": amplitudes}


def add_check(checks, name, passed, detail):
    checks.append({"name": name, "pass": bool(passed), "detail": detail})


def frequency_checks(checks, prefix, measured, expected, absent, controls,
                     minimum_amplitude, minimum_ratio, maximum_absent_amplitude):
    amplitudes = measured["amplitudes"]
    control_max = max([amplitudes.get(str(f), 0.0) for f in controls] or [0.0])
    for frequency in expected:
        amplitude = amplitudes.get(str(frequency), 0.0)
        ratio = amplitude / max(control_max, 1e-9)
        add_check(
            checks,
            "%s %d Hz present" % (prefix, frequency),
            amplitude >= minimum_amplitude and ratio >= minimum_ratio,
            "amplitude=%.6f ratio_to_control=%.1f (need >= %.6f and >= %.1f)"
            % (amplitude, ratio, minimum_amplitude, minimum_ratio),
        )
    for frequency in absent:
        amplitude = amplitudes.get(str(frequency), 0.0)
        ratio = amplitude / max(control_max, 1e-9)
        add_check(
            checks,
            "%s %d Hz absent" % (prefix, frequency),
            amplitude <= maximum_absent_amplitude and ratio <= 5.0,
            "amplitude=%.6f ratio_to_control=%.1f (need <= %.6f and <= 5.0)"
            % (amplitude, ratio, maximum_absent_amplitude),
        )


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--mp4")
    parser.add_argument("--mkv")
    parser.add_argument("--remote-hz", type=int, default=440)
    parser.add_argument("--mic-hz", type=int, default=880)
    parser.add_argument("--expect-mic", action="store_true",
                        help="expect a Microphone track and both tones in the mix")
    parser.add_argument("--require-video", action="store_true")
    parser.add_argument("--min-duration", type=float, default=5.0)
    parser.add_argument("--allow-bleed", action="store_true",
                        help="do not fail when the other tone appears in a track")
    parser.add_argument("--ffmpeg")
    parser.add_argument("--ffprobe")
    parser.add_argument("--json-out")
    args = parser.parse_args(argv)

    if not args.mp4 and not args.mkv:
        parser.error("at least one of --mp4 or --mkv is required")

    ffmpeg = find_tool("ffmpeg", args.ffmpeg)
    ffprobe = find_tool("ffprobe", args.ffprobe)
    controls = [frequency for frequency in (660, 1000, 1320)
                if frequency not in (args.remote_hz, args.mic_hz)]

    report = {
        "tool": "verify_mix.py",
        "remoteHz": args.remote_hz,
        "micHz": args.mic_hz,
        "expectMic": args.expect_mic,
        "ffmpeg": ffmpeg,
        "ffprobe": ffprobe,
        "mp4": None,
        "mkv": None,
        "checks": [],
    }
    checks = report["checks"]

    with tempfile.TemporaryDirectory(prefix="fr-mix-verify-") as work:
        if args.mp4:
            probed = probe(args.mp4, ffprobe)
            audio = audio_streams(probed)
            video = video_streams(probed)
            duration = float(probed.get("format", {}).get("duration", 0.0))
            add_check(checks, "MP4 has exactly one audio track", len(audio) == 1,
                      "audio_tracks=%d" % len(audio))
            if args.require_video:
                add_check(checks, "MP4 has video", len(video) >= 1,
                          "video_tracks=%d" % len(video))
            add_check(checks, "MP4 duration", duration >= args.min_duration,
                      "duration=%.3f s (need >= %.3f)" % (duration, args.min_duration))

            mp4_tracks = []
            if audio:
                destination = os.path.join(work, "mp4-audio.s16")
                samples = decode_mono(args.mp4, 0, ffmpeg, destination)
                measured = measure(samples,
                                   [args.remote_hz, args.mic_hz] + controls)
                expected = [args.remote_hz] + ([args.mic_hz] if args.expect_mic else [])
                absent = [] if args.allow_bleed else (
                    [] if args.expect_mic else [args.mic_hz])
                frequency_checks(checks, "MP4 mix", measured, expected, absent,
                                 controls, 0.002, 20.0, 0.001)
                mp4_tracks.append({
                    "ordinal": 0,
                    "handler": tag(audio[0], "handler_name"),
                    "title": tag(audio[0], "title"),
                    "rms": measured["rms"],
                    "amplitudes": measured["amplitudes"],
                })
            report["mp4"] = {
                "path": os.path.abspath(args.mp4),
                "audioTracks": len(audio),
                "videoTracks": len(video),
                "durationSeconds": duration,
                "tracks": mp4_tracks,
            }

        if args.mkv:
            probed = probe(args.mkv, ffprobe)
            audio = audio_streams(probed)
            duration = float(probed.get("format", {}).get("duration", 0.0))
            expected_titles = ["Mix (Remote + Mic)", "Remote"]
            if args.expect_mic:
                expected_titles.append("Microphone")
            actual_titles = [tag(stream, "title") for stream in audio]
            add_check(checks, "MKV audio track count", len(audio) == len(expected_titles),
                      "tracks=%d expected=%d" % (len(audio), len(expected_titles)))
            add_check(checks, "MKV audio track titles and order",
                      actual_titles == expected_titles,
                      "actual=%s expected=%s" % (actual_titles, expected_titles))
            add_check(checks, "MKV duration", duration >= args.min_duration,
                      "duration=%.3f s (need >= %.3f)" % (duration, args.min_duration))

            mkv_tracks = []
            for ordinal, stream in enumerate(audio):
                title = tag(stream, "title") or ("track-%d" % ordinal)
                destination = os.path.join(work, "mkv-%d.s16" % ordinal)
                samples = decode_mono(args.mkv, ordinal, ffmpeg, destination)
                measured = measure(samples,
                                   [args.remote_hz, args.mic_hz] + controls)
                if title.startswith("Mix"):
                    expected = [args.remote_hz] + ([args.mic_hz] if args.expect_mic else [])
                    absent = [] if args.allow_bleed else (
                        [] if args.expect_mic else [args.mic_hz])
                elif title == "Remote":
                    expected = [args.remote_hz]
                    absent = [] if args.allow_bleed else [args.mic_hz]
                elif title == "Microphone":
                    expected = [args.mic_hz]
                    absent = [] if args.allow_bleed else [args.remote_hz]
                else:
                    expected = []
                    absent = []
                if expected or absent:
                    frequency_checks(checks, "MKV %s" % title, measured,
                                     expected, absent, controls, 0.002, 20.0, 0.001)
                mkv_tracks.append({
                    "ordinal": ordinal,
                    "title": title,
                    "handler": tag(stream, "handler_name"),
                    "rms": measured["rms"],
                    "amplitudes": measured["amplitudes"],
                })
            report["mkv"] = {
                "path": os.path.abspath(args.mkv),
                "audioTracks": len(audio),
                "durationSeconds": duration,
                "tracks": mkv_tracks,
            }

    report["pass"] = all(check["pass"] for check in checks)
    text = json.dumps(report, ensure_ascii=False, indent=2)
    if args.json_out:
        with open(args.json_out, "w", encoding="utf-8") as handle:
            handle.write(text + "\n")
    print(text)
    return 0 if report["pass"] else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
