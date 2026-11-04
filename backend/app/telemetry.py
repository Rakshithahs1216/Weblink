"""Telemetry push loop and the ``/ws/telemetry`` endpoint (ARCHITECTURE.md section 5)."""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
from collections.abc import AsyncIterator

from fastapi import WebSocket, WebSocketDisconnect

from .auth import expiring_socket, websocket_user
from .robot import RobotSimulator

logger = logging.getLogger("weblink.telemetry")

TELEMETRY_INTERVAL = 0.2  # seconds (5 Hz)


async def periodic(interval: float) -> AsyncIterator[None]:
    """Yield immediately, then every ``interval`` seconds without cumulative drift."""
    loop = asyncio.get_running_loop()
    deadline = loop.time()
    while True:
        yield
        deadline += interval
        delay = deadline - loop.time()
        if delay < 0:  # fell behind (e.g. event loop stalled): skip, don't burst
            deadline = loop.time()
            delay = 0.0
        await asyncio.sleep(delay)


async def _wait_for_disconnect(websocket: WebSocket) -> None:
    # Incoming messages on this socket carry no meaning; drain them so a client
    # close is noticed promptly rather than on the next failed send.
    while True:
        message = await websocket.receive()
        if message["type"] == "websocket.disconnect":
            return


async def telemetry_endpoint(websocket: WebSocket) -> None:
    session = await websocket_user(websocket)
    if session is None:
        return
    user = session.user
    await websocket.accept()
    simulator: RobotSimulator = websocket.app.state.simulator
    logger.info("Telemetry WebSocket opened for %s", user.username)

    disconnected = asyncio.create_task(_wait_for_disconnect(websocket))
    try:
        async with (
            expiring_socket(websocket, session),
            contextlib.aclosing(periodic(TELEMETRY_INTERVAL)) as ticks,
        ):
            async for _ in ticks:
                if disconnected.done():
                    break
                await websocket.send_text(json.dumps(simulator.telemetry()))
    except (WebSocketDisconnect, RuntimeError):
        pass
    finally:
        disconnected.cancel()
        with contextlib.suppress(asyncio.CancelledError, WebSocketDisconnect, RuntimeError):
            await disconnected
        logger.info("Telemetry WebSocket closed for %s", user.username)
