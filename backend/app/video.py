"""Video sources (ARCHITECTURE.md section 7), shared between peers via MediaRelay."""

from __future__ import annotations

import asyncio
import fractions
import logging
import threading
import time
from datetime import datetime

import av
import numpy as np
from aiortc import MediaStreamTrack
from aiortc.contrib.media import MediaPlayer, MediaRelay
from aiortc.mediastreams import MediaStreamError

logger = logging.getLogger("weblink.video")

VIDEO_CLOCK_RATE = 90000
VIDEO_TIME_BASE = fractions.Fraction(1, VIDEO_CLOCK_RATE)

# Minimal 5x7 bitmap font for the overlay, so no OpenCV/PIL dependency is needed.
_GLYPHS = {
    "0": "01110 10001 10011 10101 11001 10001 01110",
    "1": "00100 01100 00100 00100 00100 00100 01110",
    "2": "01110 10001 00001 00010 00100 01000 11111",
    "3": "11110 00001 00001 01110 00001 00001 11110",
    "4": "00010 00110 01010 10010 11111 00010 00010",
    "5": "11111 10000 11110 00001 00001 10001 01110",
    "6": "00110 01000 10000 11110 10001 10001 01110",
    "7": "11111 00001 00010 00100 01000 01000 01000",
    "8": "01110 10001 10001 01110 10001 10001 01110",
    "9": "01110 10001 10001 01111 00001 00010 01100",
    ":": "00000 01100 01100 00000 01100 01100 00000",
    ".": "00000 00000 00000 00000 00000 01100 01100",
    "-": "00000 00000 00000 11111 00000 00000 00000",
    "#": "01010 01010 11111 01010 11111 01010 01010",
    " ": "00000 00000 00000 00000 00000 00000 00000",
    "A": "01110 10001 10001 11111 10001 10001 10001",
    "B": "11110 10001 10001 11110 10001 10001 11110",
    "E": "11111 10000 10000 11110 10000 10000 11111",
    "F": "11111 10000 10000 11110 10000 10000 10000",
    "I": "01110 00100 00100 00100 00100 00100 01110",
    "K": "10001 10010 10100 11000 10100 10010 10001",
    "L": "10000 10000 10000 10000 10000 10000 11111",
    "M": "10001 11011 10101 10101 10001 10001 10001",
    "N": "10001 11001 10101 10011 10001 10001 10001",
    "R": "11110 10001 10001 11110 10100 10010 10001",
    "S": "01111 10000 10000 01110 00001 00001 11110",
    "T": "11111 00100 00100 00100 00100 00100 00100",
    "W": "10001 10001 10001 10101 10101 10101 01010",
}
_GLYPH_MASKS = {
    ch: np.array([[c == "1" for c in row] for row in rows.split()], dtype=bool)
    for ch, rows in _GLYPHS.items()
}


def draw_text(
    img: np.ndarray, text: str, x: int, y: int, scale: int, color: tuple[int, int, int]
) -> None:
    """Draw ``text`` into a BGR image in place (unknown characters render as blanks)."""
    for ch in text.upper():
        mask = _GLYPH_MASKS.get(ch)
        if mask is not None:
            big = np.kron(mask, np.ones((scale, scale), dtype=bool))
            h, w = big.shape
            region = img[y : y + h, x : x + w]
            region[big[: region.shape[0], : region.shape[1]]] = color
        x += 6 * scale


def _make_background(width: int, height: int) -> np.ndarray:
    img = np.zeros((height, width, 3), dtype=np.uint8)
    bars = [
        (192, 192, 192),
        (0, 192, 192),
        (192, 192, 0),
        (0, 192, 0),
        (192, 0, 192),
        (0, 0, 192),
        (192, 0, 0),
    ]  # BGR colour bars
    bar_h = int(height * 0.62)
    edges = np.linspace(0, width, len(bars) + 1).astype(int)
    for color, x0, x1 in zip(bars, edges[:-1], edges[1:], strict=True):
        img[:bar_h, x0:x1] = color
    ramp = np.linspace(0, 255, width, dtype=np.uint8)
    img[bar_h:, :] = ramp[None, :, None]
    return img


class TestPatternTrack(MediaStreamTrack):
    """Synthetic colour bars with a moving block, wall clock and frame counter."""

    kind = "video"
    __test__ = False  # not a pytest test class despite the name

    def __init__(self, width: int = 640, height: int = 480, fps: int = 30):
        super().__init__()
        self.width, self.height, self.fps = width, height, fps
        self._background = _make_background(width, height)
        self._frame_count = 0
        self._start: float | None = None
        self._next: float = 0.0

    def render(self, frame_number: int) -> np.ndarray:
        img = self._background.copy()
        box = 60
        span = self.width - box
        pos = frame_number * 6 % (2 * span)
        x = pos if pos < span else 2 * span - pos  # bounce left/right
        y = int(self.height * 0.62) - box // 2
        img[y : y + box, x : x + box] = (255, 255, 255)
        img[y + 10 : y + box - 10, x + 10 : x + box - 10] = (0, 0, 255)

        img[0:96, :] = (24, 24, 24)
        clock = datetime.now().strftime("%H:%M:%S.%f")[:-3]
        draw_text(img, "WEBLINK TEST", 16, 12, 3, (0, 220, 255))
        draw_text(img, clock, 16, 50, 4, (255, 255, 255))
        draw_text(img, f"FRAME #{frame_number}", 16, self.height - 40, 3, (255, 255, 255))
        return img

    async def recv(self) -> av.VideoFrame:
        if self.readyState != "live":
            raise MediaStreamError
        period = 1.0 / self.fps
        now = time.monotonic()
        if self._start is None:
            self._start = self._next = now
        else:
            self._next += period
            if self._next < now - period:  # nobody was reading: resync, don't burst
                self._next = now
        await asyncio.sleep(max(0.0, self._next - now))

        frame = av.VideoFrame.from_ndarray(self.render(self._frame_count), format="bgr24")
        frame.pts = int((self._next - self._start) * VIDEO_CLOCK_RATE)
        frame.time_base = VIDEO_TIME_BASE
        self._frame_count += 1
        return frame


class FileVideoTrack(MediaStreamTrack):
    """Plays the video stream of a file in real time, looping forever.

    Each pass re-opens the file (aiortc's MediaPlayer(loop=True) stops after the
    first pass with PyAV 14) and timestamps keep increasing across passes.
    Audio streams are never decoded.
    """

    kind = "video"

    def __init__(self, path: str):
        super().__init__()
        self.path = path
        self._lock = threading.Lock()  # guards the container against stop() mid-decode
        self._container: av.container.InputContainer | None = None
        self._frames = None
        self._pass_offset = 0.0  # stream time at which the current pass started
        self._pass_first: float | None = None
        self._last_time = 0.0
        self._clock_start: float | None = None
        self._reopen()  # fail fast on a missing/invalid file

    def _reopen(self) -> None:
        if self._container is not None:
            self._container.close()
            self._container = None
        container = av.open(self.path)
        if not container.streams.video:
            container.close()
            raise ValueError(f"{self.path} has no video stream")
        stream = container.streams.video[0]
        stream.thread_type = "AUTO"
        self._frame_period = 1.0 / float(stream.average_rate) if stream.average_rate else 1.0 / 30
        self._container = container
        self._frames = container.decode(stream)
        self._pass_first = None

    def _next_frame(self) -> av.VideoFrame:
        """Blocking decode of the next frame; runs in a worker thread."""
        with self._lock:
            for _ in range(2):  # at most one re-open per frame; an empty file ends the track
                if self._container is None:
                    raise MediaStreamError
                try:
                    frame = next(self._frames)
                except (StopIteration, av.error.EOFError):
                    self._pass_offset = self._last_time + self._frame_period
                    self._reopen()
                    continue
                if self._pass_first is None:
                    self._pass_first = frame.time or 0.0
                self._last_time = self._pass_offset + (frame.time or 0.0) - self._pass_first
                return frame
            raise MediaStreamError

    async def recv(self) -> av.VideoFrame:
        if self.readyState != "live":
            raise MediaStreamError
        try:
            frame = await asyncio.to_thread(self._next_frame)
        except MediaStreamError:
            self.stop()
            raise
        except Exception as exc:
            # A corrupt packet or a file moved between passes. End the track (rather than
            # letting the error kill MediaRelay's reader) so peers see end-of-stream and the
            # next subscribe() reopens the source.
            logger.error("Video file %s failed: %s", self.path, exc)
            self.stop()
            raise MediaStreamError from exc
        t = self._last_time
        now = time.monotonic()
        if self._clock_start is None or now - (self._clock_start + t) > 1.0:
            self._clock_start = now - t  # first frame, or resync after nobody was reading
        await asyncio.sleep(max(0.0, self._clock_start + t - now))
        frame.pts = int(t * VIDEO_CLOCK_RATE)
        frame.time_base = VIDEO_TIME_BASE
        return frame

    def stop(self) -> None:
        super().stop()
        with self._lock:
            if self._container is not None:
                self._container.close()
                self._container = None


class VideoSource:
    """Owns the single upstream video track and hands out per-peer relay tracks."""

    def __init__(
        self, spec: str = "test", device: str = "/dev/video0", idle_stop_delay: float = 5.0
    ):
        self.spec = spec
        self.device = device
        # Keep the source warm briefly after the last viewer leaves, so a quick
        # reconnect doesn't pay for reopening the webcam/file.
        self.idle_stop_delay = idle_stop_delay
        self._idle_stop: asyncio.TimerHandle | None = None
        self._relay = MediaRelay()
        self._track: MediaStreamTrack | None = None
        self._subscribers = 0
        self.description = "not started"

    def _open(self) -> None:
        try:
            self._track = self._open_spec()
        except Exception:
            logger.exception(
                "Could not open video source %r; falling back to the test pattern", self.spec
            )
            self._track = TestPatternTrack()
            self.description = "test pattern (fallback)"
        logger.info("Video source: %s", self.description)

    def _open_spec(self) -> MediaStreamTrack:
        if self.spec == "test":
            self.description = "test pattern 640x480@30"
            return TestPatternTrack()
        if self.spec == "webcam":
            player = MediaPlayer(
                self.device, format="v4l2", options={"video_size": "640x480", "framerate": "30"}
            )
            if player.video is None:
                raise ValueError(f"{self.device} has no video stream")
            self.description = f"webcam {self.device}"
            return player.video
        if self.spec.startswith("file:"):
            path = self.spec[len("file:") :]
            track = FileVideoTrack(path)
            self.description = f"file {path} (looping)"
            return track
        raise ValueError(
            f"unknown VIDEO_SOURCE {self.spec!r} (expected test, webcam or file:<path>)"
        )

    def start(self) -> None:
        self._open()

    def subscribe(self) -> MediaStreamTrack:
        """A new track for one peer. Callers must pass it to ``unsubscribe()`` when done."""
        if self._idle_stop is not None:
            self._idle_stop.cancel()
            self._idle_stop = None
        if self._track is None or self._track.readyState != "live":
            self._open()
        self._subscribers += 1
        return self._relay.subscribe(self._track, buffered=False)

    def unsubscribe(self, track: MediaStreamTrack) -> None:
        """Stop one peer's track; stop the source once nobody is watching."""
        track.stop()
        self._subscribers = max(0, self._subscribers - 1)
        if self._subscribers > 0:
            return
        # Stopping ends MediaRelay's reader; the next subscribe() reopens the source.
        if self.idle_stop_delay <= 0:
            self.stop()
        else:
            self._idle_stop = asyncio.get_running_loop().call_later(self.idle_stop_delay, self.stop)

    def stop(self) -> None:
        if self._idle_stop is not None:
            self._idle_stop.cancel()
            self._idle_stop = None
        if self._track is not None:
            self._track.stop()
            self._track = None
