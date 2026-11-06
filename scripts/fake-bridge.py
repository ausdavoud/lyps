#!/usr/bin/env python3
"""Stands in for the now-playing bridge in debug builds, to test the UI and lyrics without a player.

Run: LYPS_BRIDGE="python3 scripts/fake-bridge.py" .build/out/Products/Debug/Lyps
Timeline, as recorded from Telegram: plays, seeks, pauses, resumes, then a voice message interrupts
(no island, nothing sent to LRCLIB), the music resumes with its title wiped (island returns), and a
replayed voice message arrives with no title (island stays hidden). Then the two cases where
Telegram resumes a song silently: a voice closed early, and a voice played to the end.
"""
import base64, json, os, struct, sys, time, zlib

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
send(76, playing=False) # Telegram pauses the song for the voice message
time.sleep(0.2)
send(0, title="today at 14:02", artist="Test Sender", album="", duration=20, art=False)  # voice
time.sleep(5)
emit({})                # voice ends: Telegram publishes nothing for a moment
time.sleep(0.5)
send(76, title="", artist="", album="", duration=0, art=False)  # music resumes, title wiped
time.sleep(5)
emit({})
time.sleep(0.5)
send(0, title="", artist="", album="", duration=0, art=False)  # a replayed voice: no title, starts at 0
time.sleep(4.5)

# The cases below need Telegram's audio output too, faked through a flag file in debug builds.
AUDIO = os.environ.get("LYPS_FAKE_TELEGRAM_AUDIO")
def audio(on):
    if AUDIO and on: open(AUDIO, "w").close()
    elif AUDIO and os.path.exists(AUDIO): os.remove(AUDIO)

send(100)               # a song plays normally
audio(True)
time.sleep(5)
send(105, playing=False)  # paused for a voice message
send(0, title="today at 14:03", artist="Test Sender", album="", duration=20, art=False)
time.sleep(4)
emit({})                # voice closed: Telegram leaves Now Playing, but the song plays on (island returns)
time.sleep(8)
audio(False)            # paused in Telegram (island hides after a pause)
time.sleep(10)
audio(True)             # played again (island returns)
time.sleep(6)
send(0, title="today at 14:04", artist="Test Sender", album="", duration=20, art=False)  # another voice
time.sleep(5)
send(0, title="today at 14:04", artist="Test Sender", album="", duration=20, playing=False, art=False)
# voice played out: Telegram keeps reporting it, paused, while the song plays on (island returns)
time.sleep(7)
audio(False)            # paused (island hides)
time.sleep(600)
