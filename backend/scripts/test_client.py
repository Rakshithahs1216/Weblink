#!/usr/bin/env python3
"""Headless Weblink client: login, WebRTC connect, drive a sine-wave joystick.

Example:
    .venv/bin/python scripts/test_client.py --url http://localhost:8010 --duration 10
"""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import getpass
import json
import math
import os
import sys
import time
from urllib.parse import urlsplit, urlunsplit

import httpx
from aiortc import RTCConfiguration, RTCIceServer, RTCPeerConnection, RTCSessionDescription
from aiortc.mediastreams import MediaStreamError
from websockets.asyncio.client import connect
from websockets.exceptions import ConnectionClosed


def ws_base(http_url: str) -> str:
    parts = urlsplit(http_url)
    scheme = "wss" if parts.scheme == "https" else "ws"
    return urlunsplit((scheme, parts.netloc, "", "", ""))


async def login(base_url: str, username: str, password: str) -> str:
    async with httpx.AsyncClient(base_url=base_url, timeout=10) as http:
        r = await http.post("/api/auth/login", json={"username": username, "password": password})
        if r.status_code != 200:
            raise SystemExit(f"login failed: HTTP {r.status_code} {r.text}")
        body = r.json()
        print(f"logged in as {body['user']['display_name']} (token valid {body['expires_in']} s)")
        return body["access_token"]


async def run(args: argparse.Namespace) -> int:
    token = await login(args.url, args.username, args.password)

    ice = [RTCIceServer(urls=args.stun)] if args.stun else []
    pc = RTCPeerConnection(RTCConfiguration(iceServers=ice))
    frames = 0
    first_frame_size = None
    telemetry_count = 0
    last_telemetry: dict = {}
    channel_open = asyncio.Event()
    tasks: list[asyncio.Task] = []

    async def read_video(track):
        nonlocal frames, first_frame_size
        try:
            while True:
                frame = await track.recv()
                frames += 1
                first_frame_size = first_frame_size or (frame.width, frame.height)
        except MediaStreamError:
            pass

    @pc.on("track")
    def on_track(track):
        print(f"remote {track.kind} track received")
        tasks.append(asyncio.create_task(read_video(track)))

    @pc.on("connectionstatechange")
    def on_state():
        print(f"peer connection: {pc.connectionState}")

    pc.addTransceiver("video", direction="recvonly")
    channel = pc.createDataChannel("control", ordered=True)
    channel.on("open", channel_open.set)

    @channel.on("message")
    def on_message(message):
        nonlocal telemetry_count, last_telemetry
        try:
            last_telemetry = json.loads(message)
        except ValueError:
            return
        telemetry_count += 1
        t = last_telemetry
        print(
            f"telemetry speed={t.get('speed'):.3f} battery={t.get('battery'):.2f} "
            f"temp={t.get('temperature'):.2f} linear={t.get('linear'):+.3f} "
            f"angular={t.get('angular'):+.3f} | frames={frames}"
        )

    try:
        async with connect(f"{ws_base(args.url)}/ws/signaling?token={token}") as ws:
            await pc.setLocalDescription(await pc.createOffer())
            await ws.send(json.dumps({"type": "offer", "sdp": pc.localDescription.sdp}))
            while True:
                msg = json.loads(await asyncio.wait_for(ws.recv(), 30))
                if msg.get("type") == "answer":
                    break
                if msg.get("type") == "error":
                    print(f"server error: {msg.get('message')}", file=sys.stderr)
            await pc.setRemoteDescription(RTCSessionDescription(sdp=msg["sdp"], type="answer"))
            await asyncio.wait_for(channel_open.wait(), 30)
            print(f"control channel open; driving for {args.duration:.0f} s")

            start = time.monotonic()
            seq = 0
            while (elapsed := time.monotonic() - start) < args.duration:
                if channel.readyState != "open":
                    print("control channel closed by the server", file=sys.stderr)
                    break
                phase = 2 * math.pi * elapsed / args.period
                linear = round(0.8 * math.sin(phase), 3)
                angular = round(0.5 * math.cos(phase), 3)
                channel.send(
                    json.dumps(
                        {
                            "type": "joystick",
                            "linear": linear,
                            "angular": angular,
                            "seq": seq,
                            "ts": int(time.time() * 1000),
                        }
                    )
                )
                seq += 1
                await asyncio.sleep(0.05)  # 20 Hz
            if channel.readyState == "open":  # release: one final zero command
                channel.send(
                    json.dumps(
                        {
                            "type": "joystick",
                            "linear": 0.0,
                            "angular": 0.0,
                            "seq": seq,
                            "ts": int(time.time() * 1000),
                        }
                    )
                )
                seq += 1
                await asyncio.sleep(0.3)
            with contextlib.suppress(ConnectionClosed):
                await ws.send(json.dumps({"type": "bye"}))
    finally:
        await pc.close()
        for task in tasks:
            task.cancel()

    elapsed = max(time.monotonic() - start, 1e-6)
    print(
        f"\nsummary: sent {seq} joystick messages, received {telemetry_count} telemetry "
        f"messages and {frames} video frames in {elapsed:.1f} s "
        f"({frames / elapsed:.1f} fps, size {first_frame_size})"
    )
    return 0 if (frames > 0 and telemetry_count > 0) else 1


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--url", default="http://localhost:8010", help="backend base URL")
    parser.add_argument("--username", default="demo", help="username or email")
    parser.add_argument(
        "--password",
        default=os.environ.get("WEBLINK_PASSWORD"),
        help="password (default: $WEBLINK_PASSWORD, else prompt)",
    )
    parser.add_argument("--duration", type=float, default=10.0, help="seconds to drive")
    parser.add_argument("--period", type=float, default=4.0, help="sine period in seconds")
    parser.add_argument(
        "--stun", default=None, help="optional STUN URL, e.g. stun:stun.l.google.com:19302"
    )
    args = parser.parse_args()
    if args.password is None:
        args.password = getpass.getpass(f"password for {args.username}: ")
    sys.exit(asyncio.run(run(args)))


if __name__ == "__main__":
    main()
