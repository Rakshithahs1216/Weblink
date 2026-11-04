"""``/ws/signaling``: one WebSocket = one RTCPeerConnection (ARCHITECTURE.md sections 3-4)."""

from __future__ import annotations

import asyncio
import contextlib
import itertools
import json
import logging

from aiortc import (
    MediaStreamTrack,
    RTCConfiguration,
    RTCDataChannel,
    RTCIceCandidate,
    RTCIceServer,
    RTCPeerConnection,
    RTCSessionDescription,
)
from fastapi import WebSocket
from starlette.websockets import WebSocketState

from .auth import SocketSession, User, expiring_socket, websocket_user
from .protocol import ProtocolError, parse_ice_candidate, parse_joystick, parse_json_object
from .robot import RobotSimulator
from .telemetry import TELEMETRY_INTERVAL, periodic
from .video import VideoSource

logger = logging.getLogger("weblink.signaling")
control_logger = logging.getLogger("weblink.control")

CONTROL_CHANNEL = "control"
MAX_CANDIDATES = 64  # per session, before and after the offer
MAX_MESSAGE_CHARS = 64_000  # an SDP offer is a few KB
MAX_SESSIONS_PER_USER = 3  # leaves room for a reconnect while the old socket drains
WS_CLOSE_TOO_MANY_SESSIONS = 4429
_session_ids = itertools.count(1)


class PeerRegistry:
    """Tracks live peer connections so shutdown can close any that remain."""

    def __init__(self) -> None:
        self._peers: dict[RTCPeerConnection, str] = {}  # pc -> username

    def try_add(self, pc: RTCPeerConnection, username: str, limit: int) -> bool:
        """Register ``pc`` unless ``username`` already holds ``limit`` connections."""
        if sum(1 for owner in self._peers.values() if owner == username) >= limit:
            return False
        self._peers[pc] = username
        return True

    def discard(self, pc: RTCPeerConnection) -> None:
        self._peers.pop(pc, None)

    def __len__(self) -> int:
        return len(self._peers)

    async def close_all(self) -> None:
        peers, self._peers = list(self._peers), {}
        await asyncio.gather(*(pc.close() for pc in peers), return_exceptions=True)


class SignalingSession:
    def __init__(self, websocket: WebSocket, auth: SocketSession):
        state = websocket.app.state
        self.ws = websocket
        self.auth = auth
        user = auth.user
        self.simulator: RobotSimulator = state.simulator
        self.video: VideoSource = state.video
        self.peers: PeerRegistry = state.peers
        self.name = f"session-{next(_session_ids)}({user.username})"

        ice_servers = [RTCIceServer(urls=url) for url in state.settings.stun_servers]
        self.pc = RTCPeerConnection(RTCConfiguration(iceServers=ice_servers))
        self.video_track: MediaStreamTrack | None = None
        self.telemetry_task: asyncio.Task | None = None
        self.pending_candidates: list[RTCIceCandidate | None] = []
        self.candidate_count = 0
        self._closed = False

        self.pc.on("datachannel", self._on_datachannel)
        self.pc.on("connectionstatechange", self._on_connection_state)

    # ---- WebSocket side -------------------------------------------------

    @property
    def user(self) -> User:
        return self.auth.user

    async def run(self) -> None:
        if not self.peers.try_add(self.pc, self.user.username, MAX_SESSIONS_PER_USER):
            logger.warning("Rejected signaling for %s: too many sessions", self.user.username)
            await self.ws.close(code=WS_CLOSE_TOO_MANY_SESSIONS, reason="Too many sessions")
            await self.pc.close()
            return
        logger.info("%s: connected", self.name)
        try:
            async with expiring_socket(self.ws, self.auth):
                await self._receive_loop()
        finally:
            await self.close()

    async def _receive_loop(self) -> None:
        while True:
            message = await self.ws.receive()
            if message["type"] == "websocket.disconnect":
                return
            text = message.get("text")
            if text is None:
                await self._send_error("binary frames are not supported")
                continue
            if len(text) > MAX_MESSAGE_CHARS:
                await self._send_error("message too large")
                continue
            if not await self._handle(text):
                return

    async def _handle(self, raw: str) -> bool:
        """Process one signaling message. Returns False when the session should end."""
        data: dict = {}
        try:
            data = parse_json_object(raw)
            kind = data.get("type")
            if kind == "offer":
                return await self._on_offer(data)
            elif kind == "ice":
                await self._on_ice(data)
            elif kind == "bye":
                logger.info("%s: bye", self.name)
                return False
            else:
                raise ProtocolError(f"unknown message type: {kind!r}")
        except ProtocolError as exc:
            logger.warning("%s: bad message: %s", self.name, exc)
            await self._send_error(str(exc))
        except Exception:
            # e.g. aiortc rejecting an SDP it cannot parse; keep the socket alive.
            logger.exception("%s: failed to process %r message", self.name, data.get("type"))
            await self._send_error(f"failed to process {data.get('type')} message")
        return True

    def _ws_open(self) -> bool:
        return (
            self.ws.client_state == WebSocketState.CONNECTED
            and self.ws.application_state == WebSocketState.CONNECTED
        )

    async def _send(self, payload: dict) -> None:
        if self._ws_open():
            with contextlib.suppress(Exception):
                await self.ws.send_text(json.dumps(payload))

    async def _send_error(self, message: str) -> None:
        await self._send({"type": "error", "message": message})

    async def _on_offer(self, data: dict) -> bool:
        """Answer the offer. Returns False (ending the session) if negotiation fails midway,
        since a half-applied offer can't be retried on this socket."""
        sdp = data.get("sdp")
        if not isinstance(sdp, str) or not sdp.strip():
            raise ProtocolError("offer.sdp must be a non-empty string")
        if self.pc.remoteDescription is not None:
            raise ProtocolError("renegotiation is not supported; open a new connection")

        try:
            await self.pc.setRemoteDescription(RTCSessionDescription(sdp=sdp, type="offer"))
            if any(t.kind == "video" for t in self.pc.getTransceivers()):
                self.video_track = self.video.subscribe()
                self.pc.addTrack(self.video_track)
            # aiortc gathers all ICE candidates here and embeds them in the answer.
            await self.pc.setLocalDescription(await self.pc.createAnswer())
        except Exception:
            logger.exception("%s: negotiation failed", self.name)
            await self._send_error("failed to process offer; open a new connection")
            return False
        await self._send({"type": "answer", "sdp": self.pc.localDescription.sdp})
        logger.info("%s: answered offer", self.name)

        pending, self.pending_candidates = self.pending_candidates, []
        for candidate in pending:
            with contextlib.suppress(Exception):  # one bad candidate must not end the session
                await self.pc.addIceCandidate(candidate)
        return True

    async def _on_ice(self, data: dict) -> None:
        if self.candidate_count >= MAX_CANDIDATES:
            raise ProtocolError("too many ICE candidates")
        candidate = parse_ice_candidate(data.get("candidate"))
        self.candidate_count += 1
        if self.pc.remoteDescription is None:
            self.pending_candidates.append(candidate)
        else:
            await self.pc.addIceCandidate(candidate)

    # ---- Peer connection side ------------------------------------------

    async def _on_connection_state(self) -> None:
        state = self.pc.connectionState
        logger.info("%s: peer connection %s", self.name, state)
        if state == "failed":
            # The socket can't renegotiate, so end the whole session and tell the client.
            await self._send_error("peer connection failed")
            await self.close()

    def _on_datachannel(self, channel: RTCDataChannel) -> None:
        if channel.label != CONTROL_CHANNEL:
            logger.info("%s: ignoring data channel %r", self.name, channel.label)
            return
        logger.info("%s: control channel open", self.name)
        channel.on("message", self._on_control_message)
        self._stop_telemetry()
        self.telemetry_task = asyncio.create_task(self._push_telemetry(channel))

    def _on_control_message(self, message: object) -> None:
        try:
            command = parse_joystick(message)
        except ProtocolError as exc:
            logger.warning("%s: ignoring control message: %s", self.name, exc)
            return
        self.simulator.command(command.linear, command.angular)
        control_logger.info(command.log_line())

    async def _push_telemetry(self, channel: RTCDataChannel) -> None:
        async with contextlib.aclosing(periodic(TELEMETRY_INTERVAL)) as ticks:
            async for _ in ticks:
                if channel.readyState == "connecting":
                    continue
                if channel.readyState != "open":
                    return
                try:
                    channel.send(json.dumps(self.simulator.telemetry()))
                except Exception as exc:  # channel closed between check and send
                    logger.debug("%s: telemetry send failed: %s", self.name, exc)
                    return

    def _stop_telemetry(self) -> None:
        if self.telemetry_task is not None:
            self.telemetry_task.cancel()
            self.telemetry_task = None

    # ---- Teardown ---------------------------------------------------------

    async def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        task, self.telemetry_task = self.telemetry_task, None
        if task is not None:
            task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await task
        if self.video_track is not None:
            self.video.unsubscribe(self.video_track)  # leaves the MediaRelay
            self.video_track = None
        try:
            await self.pc.close()
        finally:
            self.peers.discard(self.pc)
        if self._ws_open():
            with contextlib.suppress(Exception):
                await self.ws.close()
        logger.info("%s: closed", self.name)


async def signaling_endpoint(websocket: WebSocket) -> None:
    auth = await websocket_user(websocket)
    if auth is None:
        return
    await websocket.accept()
    await SignalingSession(websocket, auth).run()
