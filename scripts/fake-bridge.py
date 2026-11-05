#!/usr/bin/env python3
"""Stands in for the now-playing bridge in debug builds, to test the UI and lyrics without a player.

Run: LYPS_BRIDGE="python3 scripts/fake-bridge.py" .build/out/Products/Debug/Lyps
Timeline, as Telegram behaves: plays, seeks, pauses, resumes, then a voice message interrupts
(no island, nothing sent to LRCLIB), then the music resumes with its title wiped (island returns).
"""
import base64, json, struct, sys, time, zlib

TELEGRAM = "com.tdesktop.Telegram"


def artwork():
    """A small two-color PNG, so the artwork and tint code run for real."""
    size = 64
    rows = b"".join(
        b"\x00" + bytes(c for x in range(size) for c in (150 + x, 40 + y, 200 - x))
        for y in range(size)
    )
    chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))
    png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))
    return base64.b64encode(png).decode()


def emit(payload):
    print(json.dumps(dict(type="data", diff=False, payload=payload)), flush=True)


def send(elapsed, playing=True, title="Blinding Lights", artist="The Weeknd", album="After Hours",
         duration=200, art=True):
    payload = dict(bundleIdentifier=TELEGRAM, title=title, artist=artist, album=album, playing=playing,
                   durationMicros=duration * 1e6, elapsedTimeMicros=elapsed * 1e6,
                   timestampEpochMicros=time.time() * 1e6, playbackRate=1.0 if playing else 0.0)
    if art:
        payload.update(artworkData=artwork(), artworkMimeType="image/png")
    emit(payload)


start = float(sys.argv[1]) if len(sys.argv) > 1 else 26
send(start)
time.sleep(14)
send(60)                # seek
time.sleep(10)
send(70, playing=False) # pause
time.sleep(9)
send(70)                # resume
time.sleep(6)
send(0, title="today at 14:02", artist="Test Sender", album="", duration=20, art=False)  # voice
time.sleep(5)
emit({})                # voice ends: Telegram publishes nothing for a moment
time.sleep(0.5)
send(76, title="", artist="", album="", duration=0, art=False)  # music resumes, title wiped
time.sleep(600)
