import json

import pytest

from app.protocol import ProtocolError, ice_message, parse_ice_candidate, parse_joystick


def test_joystick_parse_and_log_line():
    cmd = parse_joystick(
        json.dumps({"type": "joystick", "linear": 0.42, "angular": -0.1, "seq": 17, "ts": 1})
    )
    assert (cmd.linear, cmd.angular, cmd.seq, cmd.ts) == (0.42, -0.1, 17, 1)
    assert cmd.log_line() == "joystick seq=17 linear=+0.420 angular=-0.100"


def test_joystick_values_are_clamped():
    cmd = parse_joystick('{"type": "joystick", "linear": 7, "angular": -1.5, "seq": 1}')
    assert (cmd.linear, cmd.angular) == (1.0, -1.0)
    assert cmd.log_line() == "joystick seq=1 linear=+1.000 angular=-1.000"


@pytest.mark.parametrize(
    "raw",
    [
        "not json",
        b'{"type": "joystick", "linear": 0, "angular": 0}',
        "[1, 2]",
        '{"type": "joystick", "linear": "fast", "angular": 0}',
        '{"type": "joystick", "linear": true, "angular": 0}',
        '{"type": "joystick", "linear": NaN, "angular": 0}',
        '{"type": "joystick", "angular": 0}',
        '{"type": "telemetry", "linear": 0, "angular": 0}',
        "[" * 100000,
    ],
)
def test_malformed_joystick_rejected(raw):
    with pytest.raises(ProtocolError):
        parse_joystick(raw)


CANDIDATE = (
    "candidate:842163049 1 udp 1677729535 192.168.1.20 54321 "
    "typ srflx raddr 10.0.0.2 rport 54321 generation 0"
)


def test_ice_candidate_translation():
    c = parse_ice_candidate({"candidate": CANDIDATE, "sdp_mid": "0", "sdp_m_line_index": 0})
    assert (c.ip, c.port, c.type, c.protocol, c.priority) == (
        "192.168.1.20",
        54321,
        "srflx",
        "udp",
        1677729535,
    )
    assert (c.sdpMid, c.sdpMLineIndex) == ("0", 0)
    assert c.relatedAddress == "10.0.0.2"
    # Round trip through the client-side helper.
    again = parse_ice_candidate(ice_message(c)["candidate"])
    assert (again.ip, again.port, again.foundation) == (c.ip, c.port, c.foundation)


def test_ice_end_of_candidates():
    assert parse_ice_candidate({"candidate": "", "sdp_mid": "0", "sdp_m_line_index": 0}) is None


@pytest.mark.parametrize(
    "payload",
    [
        None,
        "candidate:1 1 udp 1 1.2.3.4 5 typ host",
        {"candidate": "candidate:garbage", "sdp_mid": "0"},
        {"candidate": CANDIDATE},  # neither sdp_mid nor sdp_m_line_index
        {"candidate": CANDIDATE, "sdp_mid": 0},
        {"candidate": CANDIDATE, "sdp_m_line_index": "0"},
        {"candidate": 5, "sdp_mid": "0"},
    ],
)
def test_bad_ice_rejected(payload):
    with pytest.raises(ProtocolError):
        parse_ice_candidate(payload)
