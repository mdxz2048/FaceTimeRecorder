#!/usr/bin/env python3
"""Create two 6-second stereo 48 kHz PCM WAV files for the offline mux test.

Left/right both carry the same tone:
  remote-440.wav : 440 Hz, amplitude 0.2
  mic-880.wav    : 880 Hz, amplitude 0.2

The 30 ms fade in/out avoids clicks at the boundaries. This is test input for
MediaMuxer, not a recording of a real call.
"""

import argparse
import math
import struct
import wave

SAMPLE_RATE = 48_000
CHANNELS = 2
SECONDS = 6.0
AMPLITUDE = 0.2
FADE_SECONDS = 0.03


def write_tone(path, frequency):
    total = int(SAMPLE_RATE * SECONDS)
    fade = int(SAMPLE_RATE * FADE_SECONDS)
    frames = bytearray()
    for index in range(total):
        gain = 1.0
        if index < fade:
            gain = index / fade
        elif index >= total - fade:
            gain = (total - index) / fade
        value = int(round(
            AMPLITUDE * gain * math.sin(2.0 * math.pi * frequency * index / SAMPLE_RATE)
            * 32767.0
        ))
        sample = struct.pack("<h", value)
        frames += sample + sample

    with wave.open(path, "wb") as handle:
        handle.setnchannels(CHANNELS)
        handle.setsampwidth(2)
        handle.setframerate(SAMPLE_RATE)
        handle.writeframes(bytes(frames))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("directory")
    args = parser.parse_args()

    write_tone(args.directory + "/remote-440.wav", 440.0)
    write_tone(args.directory + "/mic-880.wav", 880.0)
    print("wrote remote-440.wav and mic-880.wav")


if __name__ == "__main__":
    main()
