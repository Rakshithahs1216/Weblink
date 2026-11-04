"""Parsing/validation of the JSON messages defined in ARCHITECTURE.md (sections 3-4).

Everything here is pure and side-effect free so it can be unit tested directly.
"""

from __future__ import annotations

import json
import math
from dataclasses import dataclass
from typing import Any

from aiortc import RTCIceCandidate
from aiortc.sdp import candidate_from_sdp, candidate_to_sdp

from .robot import clamp_unit


class ProtocolError(ValueError):
    """A message that is not valid per the contract. It is reported/ignored, never fatal."""


def parse_json_object(raw: Any) -> dict:
    if not isinstance(raw, str):
        raise ProtocolError("expected a JSON text message")
    try:
        data = json.loads(raw)
    except (ValueError, RecursionError) as exc:
        raise ProtocolError("malformed JSON") from exc
    if not isinstance(data, dict):
        raise ProtocolError("expected a JSON object")
    return data


def _is_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


@dataclass(frozen=True)
class JoystickCommand:
    linear: float
    angular: float
    seq: int | None
    ts: int | None

    def log_line(self) -> str:
        seq = self.seq if self.seq is not None else "-"
        return f"joystick seq={seq} linear={self.linear:+.3f} angular={self.angular:+.3f}"


def parse_joystick(raw: Any) -> JoystickCommand:
    """Parse a DataChannel ``control`` message; values are clamped to [-1, 1]."""
    data = parse_json_object(raw)
    if data.get("type") != "joystick":
        raise ProtocolError(f"unsupported control message type: {data.get('type')!r}")
    linear, angular = data.get("linear"), data.get("angular")
    if not (_is_number(linear) and _is_number(angular)):
        raise ProtocolError("linear and angular must be finite numbers")
    seq, ts = data.get("seq"), data.get("ts")
    return JoystickCommand(
        linear=clamp_unit(float(linear)),
        angular=clamp_unit(float(angular)),
        seq=seq if isinstance(seq, int) and not isinstance(seq, bool) else None,
        ts=ts if isinstance(ts, int) and not isinstance(ts, bool) else None,
    )


def parse_ice_candidate(payload: Any) -> RTCIceCandidate | None:
    """Translate the contract's ``candidate`` object into an aiortc candidate.

    Returns None for an end-of-candidates marker (empty candidate string).
    """
    if not isinstance(payload, dict):
        raise ProtocolError("ice.candidate must be an object")
    line = payload.get("candidate")
    sdp_mid = payload.get("sdp_mid")
    sdp_m_line_index = payload.get("sdp_m_line_index")
    if not isinstance(line, str):
        raise ProtocolError("ice.candidate.candidate must be a string")
    if sdp_mid is not None and not isinstance(sdp_mid, str):
        raise ProtocolError("ice.candidate.sdp_mid must be a string or null")
    if sdp_m_line_index is not None and (
        not isinstance(sdp_m_line_index, int) or isinstance(sdp_m_line_index, bool)
    ):
        raise ProtocolError("ice.candidate.sdp_m_line_index must be an int or null")

    line = line.strip()
    if line.startswith("a="):
        line = line[2:]
    if line.startswith("candidate:"):
        line = line[len("candidate:") :]
    if not line:
        return None
    if sdp_mid is None and sdp_m_line_index is None:
        raise ProtocolError("ice candidate needs sdp_mid or sdp_m_line_index")
    try:
        candidate = candidate_from_sdp(line)
    except (AssertionError, ValueError, IndexError) as exc:
        raise ProtocolError("unparseable ICE candidate") from exc
    candidate.sdpMid = sdp_mid
    candidate.sdpMLineIndex = sdp_m_line_index
    return candidate


def ice_message(candidate: RTCIceCandidate) -> dict:
    """Inverse of parse_ice_candidate (used by clients; aiortc servers do not trickle)."""
    return {
        "type": "ice",
        "candidate": {
            "candidate": "candidate:" + candidate_to_sdp(candidate),
            "sdp_mid": candidate.sdpMid,
            "sdp_m_line_index": candidate.sdpMLineIndex,
        },
    }
