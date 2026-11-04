# Weblink backend

FastAPI + aiortc server for the Weblink app: JWT login, WebRTC video, a
`control` DataChannel for joystick/telemetry, and a telemetry WebSocket.
The wire protocol is specified in [`../docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md).

```
app/
  main.py        app factory, REST routes, lifespan (video start, peer cleanup), log redaction
  config.py      settings from environment variables
  auth.py        bcrypt user store (demo user), JWT create/verify, REST + WebSocket auth
  signaling.py   /ws/signaling: one RTCPeerConnection per socket, control DataChannel
  telemetry.py   /ws/telemetry and the 200 ms push loop
  protocol.py    pure parsing/validation of joystick and ICE messages
  robot.py       shared robot simulator (pure logic, injectable clock)
  video.py       test pattern / webcam / looping file sources, MediaRelay fan-out
scripts/test_client.py   headless aiortc client (sine-wave joystick)
tests/                   unit tests + end-to-end tests against a real uvicorn server
```

## Setup

Python 3.10+.

```bash
cd backend
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

If you have a ROS environment sourced, its `PYTHONPATH` leaks into the venv;
`pytest.ini` disables the ROS pytest plugins, and `env -u PYTHONPATH ...` is a
fallback if anything else conflicts.

## Run

```bash
.venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8010
# with settings from a file:
cp .env.example .env   # set JWT_SECRET (≥ 32 chars)
.venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8010 --env-file .env
# or use HOST/PORT from the environment:
.venv/bin/python -m app
```

Use `--host 0.0.0.0` when the app runs on another device or the Android
emulator (`http://10.0.2.2:8010`).

Demo account: `demo` (or `demo@weblink.local`) / `demo1234`.

### Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `JWT_SECRET` | random per process (tokens die on restart) | HS256 signing key, ≥ 32 chars or startup fails |
| `JWT_EXPIRE_MINUTES` | `60` | token lifetime |
| `VIDEO_SOURCE` | `test` | `test`, `webcam`, or `file:<path>` (looped) |
| `VIDEO_DEVICE` | `/dev/video0` | v4l2 device for `webcam` |
| `HOST` / `PORT` | `0.0.0.0` / `8010` | used by `python -m app` |
| `CORS_ORIGINS` | `*` | comma-separated allowed origins |
| `STUN_SERVERS` | `stun:stun.l.google.com:19302` | comma-separated; empty = host candidates only (offline LAN) |
| `LOG_LEVEL` | `INFO` | log level for `weblink.*` loggers |

If the configured video source cannot be opened, the server logs the error and
falls back to the test pattern, so control and telemetry still work.

## Tests

```bash
.venv/bin/pytest -q
```

Unit tests cover auth, the robot simulator, message parsing and the video sources.
The end-to-end tests start uvicorn on a free port and connect with an aiortc client
(login, offer/answer, trickle ICE, DataChannel joystick, telemetry echo, video frames,
close code 4401, cleanup after `bye` and after an abrupt disconnect).

## Example commands

```bash
# health and login
curl -s localhost:8010/api/health
TOKEN=$(curl -s -X POST localhost:8010/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"demo","password":"demo1234"}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')
curl -s localhost:8010/api/auth/me -H "Authorization: Bearer $TOKEN"

# telemetry stream (5 Hz)
websocat "ws://localhost:8010/ws/telemetry?token=$TOKEN"
# bad token -> connection closed with code 4401
websocat "ws://localhost:8010/ws/telemetry?token=nope"

# full WebRTC client: drives a sine-wave joystick for 10 s, prints telemetry and frame count
WEBLINK_PASSWORD=demo1234 .venv/bin/python scripts/test_client.py --url http://localhost:8010 --duration 10
```

The server logs every joystick command, e.g.
`joystick seq=17 linear=+0.420 angular=-0.100`. Tokens are redacted from
uvicorn's access log (`?token=***`); passwords are never logged.

## Behaviour notes

* WebSocket auth: the token is checked before anything else. A close code can only
  be sent on an established WebSocket (closing before the handshake becomes an HTTP 403),
  so an invalid token gets an accept immediately followed by close `4401`.
* One WebSocket = one peer connection. A second `offer` on the same socket is answered
  with an `error` (open a new socket to reconnect). ICE candidates that arrive before the
  offer are buffered.
* Malformed JSON / unknown message types on the signaling socket get an `error` reply;
  malformed DataChannel messages are logged and ignored. Joystick values are clamped to [-1, 1].
* When the socket closes (or `bye`), the telemetry task, the relay video track and the
  peer connection are torn down; remaining peers are closed on server shutdown.
* Abuse limits: 5 failed logins per client IP per 60 s → `429`; at most 4 concurrent bcrypt
  checks; at most 3 signaling sockets per user (more → close `4429`); signaling messages
  ≤ 64 000 chars; ≤ 64 ICE candidates per socket. Sockets are closed with `4401` when the
  token that opened them expires.
* When the last viewer leaves, the video source is stopped after a 5 s grace period (a quick reconnect reuses it); the next viewer after that reopens it.
  A video file that fails mid-stream (deleted, corrupt) ends cleanly and is reopened on the
  next connection instead of freezing every peer.
* With a generated secret, run a single worker: each process would mint its own secret.
* The simulator is shared by all clients. Telemetry `linear`/`angular` echo the command
  currently in effect (zero after the 500 ms dead-man timeout).
