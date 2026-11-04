"""Abuse resistance: login throttling, secrets, socket limits and token expiry."""

import asyncio
import contextlib
import json

import pytest
from test_auth import login
from test_e2e import get_token, recv_json, wait_until
from test_protocol import CANDIDATE as CANDIDATE_LINE
from websockets.asyncio.client import connect
from websockets.exceptions import ConnectionClosed

from app.auth import LoginThrottle
from app.config import Settings
from app.signaling import MAX_CANDIDATES, MAX_SESSIONS_PER_USER

CANDIDATE = {"candidate": CANDIDATE_LINE, "sdp_mid": "0", "sdp_m_line_index": 0}


def test_throttle_blocks_after_max_failures_and_expires():
    now = [0.0]
    throttle = LoginThrottle(max_failures=3, window=60, clock=lambda: now[0])
    for _ in range(3):
        assert throttle.retry_after("ip") == 0
        throttle.record_failure("ip")
    assert throttle.retry_after("ip") == pytest.approx(60)
    assert throttle.retry_after("other-ip") == 0
    now[0] = 61
    assert throttle.retry_after("ip") == 0


def test_login_is_throttled_per_client(client):
    for _ in range(5):
        assert login(client, password="wrong").status_code == 401
    r = login(client)  # even the right password is refused while throttled
    assert r.status_code == 429
    assert int(r.headers["Retry-After"]) > 0


def test_successful_login_resets_failures(client):
    for _ in range(4):
        login(client, password="wrong")
    assert login(client).status_code == 200
    for _ in range(4):
        assert login(client, password="wrong").status_code == 401


def test_short_secret_is_refused():
    with pytest.raises(ValueError, match="at least 32"):
        Settings(jwt_secret="change-me")


def test_unset_secret_generates_a_random_one(monkeypatch):
    monkeypatch.delenv("JWT_SECRET", raising=False)
    first, second = Settings.from_env(), Settings.from_env()
    assert first.generated_secret and len(first.jwt_secret) >= 32
    assert first.jwt_secret != second.jwt_secret


@pytest.mark.parametrize("path", ["/ws/signaling", "/ws/telemetry"])
async def test_socket_closes_with_4401_when_token_expires(live_server, path):
    token = live_server.app.state.auth.tokens.create("demo", expires_in=2)
    async with connect(f"{live_server.ws_url}{path}?token={token}") as ws:
        with pytest.raises(ConnectionClosed) as info:
            while True:  # telemetry keeps flowing until expiry
                await asyncio.wait_for(ws.recv(), 5)
    assert info.value.rcvd.code == 4401


async def test_signaling_sessions_are_capped_per_user(live_server):
    token = await get_token(live_server)
    url = f"{live_server.ws_url}/ws/signaling?token={token}"
    peers = live_server.app.state.peers
    async with contextlib.AsyncExitStack() as stack:
        for _ in range(MAX_SESSIONS_PER_USER):
            await stack.enter_async_context(connect(url))
        await wait_until(lambda: len(peers) == MAX_SESSIONS_PER_USER, 5, "sessions to register")
        async with connect(url) as extra:
            with pytest.raises(ConnectionClosed) as info:
                await asyncio.wait_for(extra.recv(), 5)
        assert info.value.rcvd.code == 4429
    await wait_until(lambda: len(peers) == 0, 5, "sessions to close")


async def test_oversized_and_excess_signaling_messages_are_rejected(live_server):
    token = await get_token(live_server)
    async with connect(f"{live_server.ws_url}/ws/signaling?token={token}") as ws:
        await ws.send(json.dumps({"type": "offer", "sdp": "x" * 70_000}))
        assert await recv_json(ws) == {"type": "error", "message": "message too large"}

        for _ in range(MAX_CANDIDATES):
            await ws.send(json.dumps({"type": "ice", "candidate": CANDIDATE}))
        await ws.send(json.dumps({"type": "ice", "candidate": CANDIDATE}))
        reply = await recv_json(ws)
        assert reply == {"type": "error", "message": "too many ICE candidates"}
    await wait_until(lambda: len(live_server.app.state.peers) == 0, 5, "session to close")
