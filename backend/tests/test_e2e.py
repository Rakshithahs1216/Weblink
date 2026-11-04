"""End-to-end tests against a real uvicorn server, using aiortc as the client."""

import asyncio
import json
import re
import time

import httpx
import pytest
from aiortc import RTCConfiguration, RTCPeerConnection, RTCSessionDescription
from aiortc.mediastreams import MediaStreamError
from websockets.asyncio.client import connect
from websockets.exceptions import ConnectionClosed


async def get_token(server) -> str:
    async with httpx.AsyncClient(base_url=server.http_url) as http:
        r = await http.post("/api/auth/login", json={"username": "demo", "password": "demo1234"})
        r.raise_for_status()
        return r.json()["access_token"]


async def wait_until(predicate, timeout: float, message: str):
    deadline = time.monotonic() + timeout
    while not predicate():
        if time.monotonic() > deadline:
            raise AssertionError(f"timed out waiting for {message}")
        await asyncio.sleep(0.05)


async def recv_json(ws, timeout: float = 10.0) -> dict:
    return json.loads(await asyncio.wait_for(ws.recv(), timeout))


def first_candidate(sdp: str):
    """(candidate line, mid) of the first candidate in an SDP, for exercising trickle ICE."""
    mid = None
    for line in sdp.splitlines():
        if line.startswith("a=mid:"):
            mid = line[len("a=mid:") :]
        m = re.match(r"a=(candidate:.*)", line)
        if m and mid is not None:
            return m.group(1), mid
    raise AssertionError("no candidate in SDP")


async def test_webrtc_end_to_end(live_server):
    token = await get_token(live_server)
    pc = RTCPeerConnection(RTCConfiguration(iceServers=[]))
    telemetry: list[dict] = []
    frames: list = []
    reader_tasks = []
    channel_open = asyncio.Event()

    async def read_video(track):
        try:
            while True:
                frames.append(await track.recv())
        except MediaStreamError:
            pass

    @pc.on("track")
    def on_track(track):
        reader_tasks.append(asyncio.create_task(read_video(track)))

    pc.addTransceiver("video", direction="recvonly")
    channel = pc.createDataChannel("control", ordered=True)
    channel.on("open", channel_open.set)
    channel.on("message", lambda m: telemetry.append(json.loads(m)))

    try:
        async with connect(f"{live_server.ws_url}/ws/signaling?token={token}") as ws:
            # Malformed input is answered with an error, not a crash.
            await ws.send("this is not json")
            assert (await recv_json(ws))["type"] == "error"
            await ws.send(json.dumps({"type": "warp-drive"}))
            assert (await recv_json(ws))["type"] == "error"

            await pc.setLocalDescription(await pc.createOffer())
            offer_sdp = pc.localDescription.sdp
            await ws.send(json.dumps({"type": "offer", "sdp": offer_sdp}))
            # Trickle path: a (duplicate) candidate plus end-of-candidates.
            line, mid = first_candidate(offer_sdp)
            await ws.send(
                json.dumps(
                    {
                        "type": "ice",
                        "candidate": {"candidate": line, "sdp_mid": mid, "sdp_m_line_index": 0},
                    }
                )
            )
            await ws.send(
                json.dumps(
                    {
                        "type": "ice",
                        "candidate": {"candidate": "", "sdp_mid": mid, "sdp_m_line_index": 0},
                    }
                )
            )

            answer = await recv_json(ws)
            assert answer["type"] == "answer", answer
            await pc.setRemoteDescription(RTCSessionDescription(sdp=answer["sdp"], type="answer"))

            await asyncio.wait_for(channel_open.wait(), 15)
            channel.send("garbage")  # must be ignored
            channel.send(json.dumps({"type": "joystick", "linear": "x", "angular": 0}))
            for seq in range(12):
                channel.send(
                    json.dumps(
                        {
                            "type": "joystick",
                            "linear": 0.42,
                            "angular": -0.1,
                            "seq": seq,
                            "ts": int(time.time() * 1000),
                        }
                    )
                )
                await asyncio.sleep(0.05)

            await wait_until(
                lambda: any(t["linear"] == 0.42 for t in telemetry), 5, "telemetry echoing linear"
            )
            echoed = next(t for t in telemetry if t["linear"] == 0.42)
            assert echoed["angular"] == -0.1
            assert set(echoed) == {
                "type",
                "speed",
                "battery",
                "temperature",
                "linear",
                "angular",
                "ts",
            }
            assert echoed["type"] == "telemetry"
            assert 0 <= echoed["speed"] <= 1.5 and 0 <= echoed["battery"] <= 100

            # Out-of-range values are clamped.
            channel.send(json.dumps({"type": "joystick", "linear": 3.0, "angular": -9, "seq": 100}))
            await wait_until(lambda: telemetry[-1]["linear"] == 1.0, 3, "clamped telemetry")
            assert telemetry[-1]["angular"] == -1.0

            await wait_until(lambda: len(frames) >= 1, 15, "a video frame")
            assert (frames[0].width, frames[0].height) == (640, 480)

            # Telemetry cadence is ~200 ms.
            start = len(telemetry)
            await asyncio.sleep(1.0)
            assert 3 <= len(telemetry) - start <= 7

            await ws.send(json.dumps({"type": "bye"}))
            with pytest.raises(ConnectionClosed):
                while True:
                    msg = await recv_json(ws)
                    assert msg["type"] != "error", msg
    finally:
        await pc.close()
        for task in reader_tasks:
            task.cancel()

    await wait_until(
        lambda: len(live_server.app.state.peers) == 0, 5, "server to release the peer connection"
    )


async def test_abrupt_disconnect_releases_peer(live_server):
    token = await get_token(live_server)
    pc = RTCPeerConnection(RTCConfiguration(iceServers=[]))
    pc.addTransceiver("video", direction="recvonly")
    pc.createDataChannel("control")
    await pc.setLocalDescription(await pc.createOffer())
    async with connect(f"{live_server.ws_url}/ws/signaling?token={token}") as ws:
        await ws.send(json.dumps({"type": "offer", "sdp": pc.localDescription.sdp}))
        assert (await recv_json(ws))["type"] == "answer"
        assert len(live_server.app.state.peers) == 1
    # Socket dropped without "bye".
    await pc.close()
    await wait_until(
        lambda: len(live_server.app.state.peers) == 0, 5, "peer cleanup after disconnect"
    )


async def test_telemetry_websocket(live_server):
    token = await get_token(live_server)
    async with connect(f"{live_server.ws_url}/ws/telemetry?token={token}") as ws:
        await ws.send("ignored")
        first = await recv_json(ws)
        stamps = [time.monotonic()]
        for _ in range(4):
            msg = await recv_json(ws)
            stamps.append(time.monotonic())
        assert first["type"] == msg["type"] == "telemetry"
        period = (stamps[-1] - stamps[0]) / 4
        assert 0.15 < period < 0.3


@pytest.mark.parametrize("path", ["/ws/signaling", "/ws/telemetry"])
@pytest.mark.parametrize("query", ["", "?token=", "?token=garbage"])
async def test_bad_token_closes_with_4401(live_server, path, query):
    async with connect(f"{live_server.ws_url}{path}{query}") as ws:
        with pytest.raises(ConnectionClosed) as info:
            await asyncio.wait_for(ws.recv(), 5)
    assert info.value.rcvd.code == 4401
