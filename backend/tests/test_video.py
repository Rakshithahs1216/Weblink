import asyncio

import av
import numpy as np
import pytest
from aiortc.mediastreams import MediaStreamError

from app.video import FileVideoTrack, TestPatternTrack, VideoSource


async def test_test_pattern_frames():
    track = TestPatternTrack()
    first = await track.recv()
    second = await track.recv()
    assert (first.width, first.height) == (640, 480)
    assert second.pts > first.pts
    # The moving block makes consecutive frames differ.
    assert not np.array_equal(first.to_ndarray(format="bgr24"), second.to_ndarray(format="bgr24"))
    track.stop()


def _write_clip(path, frames=5):
    container = av.open(str(path), "w")
    stream = container.add_stream("mpeg4", rate=30)
    stream.width, stream.height, stream.pix_fmt = 160, 120, "yuv420p"
    for i in range(frames):
        image = np.full((120, 160, 3), i * 40, dtype=np.uint8)
        for packet in stream.encode(av.VideoFrame.from_ndarray(image, format="rgb24")):
            container.mux(packet)
    for packet in stream.encode():
        container.mux(packet)
    container.close()


async def test_file_track_loops_with_increasing_timestamps(tmp_path):
    clip = tmp_path / "clip.mp4"
    _write_clip(clip)
    track = FileVideoTrack(str(clip))
    pts = [(await track.recv()).pts for _ in range(12)]  # > 2 passes of 5 frames
    track.stop()
    assert all(b > a for a, b in zip(pts, pts[1:], strict=False)), pts


def test_video_source_falls_back_to_test_pattern(tmp_path):
    source = VideoSource(f"file:{tmp_path / 'missing.mp4'}")
    source.start()
    assert source.description == "test pattern (fallback)"
    source.stop()


async def test_file_track_ends_cleanly_when_file_disappears(tmp_path):
    clip = tmp_path / "clip.mp4"
    _write_clip(clip)
    track = FileVideoTrack(str(clip))
    clip.unlink()  # the reopen at the end of the first pass will fail
    with pytest.raises(MediaStreamError):
        for _ in range(12):
            await track.recv()
    assert track.readyState == "ended"


async def test_source_stops_when_last_subscriber_leaves():
    source = VideoSource("test", idle_stop_delay=0)
    source.start()
    first, second = source.subscribe(), source.subscribe()
    upstream = source._track
    await first.recv()
    source.unsubscribe(first)
    assert upstream.readyState == "live"  # one viewer left
    source.unsubscribe(second)
    assert upstream.readyState == "ended"
    third = source.subscribe()  # reopens a fresh source
    assert source._track is not upstream and source._track.readyState == "live"
    assert (await third.recv()).width == 640
    source.unsubscribe(third)


async def test_source_stays_warm_for_a_quick_reconnect():
    source = VideoSource("test", idle_stop_delay=0.2)
    source.start()
    upstream = source._track
    source.unsubscribe(source.subscribe())
    again = source.subscribe()  # within the grace period: same source, timer cancelled
    assert source._track is upstream
    await asyncio.sleep(0.3)
    assert upstream.readyState == "live"
    source.unsubscribe(again)
    await asyncio.sleep(0.3)
    assert upstream.readyState == "ended"
