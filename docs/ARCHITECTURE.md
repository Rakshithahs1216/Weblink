# Weblink — Architecture & Interface Contract

This document is the single source of truth for how the Flutter app and the
backend talk to each other. Both sides MUST follow it exactly.

## 1. Components

```
┌──────────────────────────── Flutter app (repo root) ───────────────────────────┐
│ LoginScreen → HomeScreen ─┬─ VideoScreen     (renders remote video track)       │
│                           ├─ JoystickScreen  (sends joystick over DataChannel)  │
│                           └─ TelemetryScreen (DataChannel, WebSocket fallback)  │
│ AuthService + TokenStorage (flutter_secure_storage)                              │
│ RobotSession (ONE shared RTCPeerConnection + "control" DataChannel)              │
│ TelemetrySocket (WebSocket fallback when WebRTC is not connected)                │
└──────────────────────────────────────────────────────────────────────────────────┘
          │ HTTPS/HTTP REST          │ WebSocket signaling        │ WebRTC (SRTP + SCTP)
┌──────────────────────────── Backend (backend/, FastAPI + aiortc) ───────────────┐
│ /api/auth/*  (bcrypt + JWT HS256)                                                │
│ /ws/signaling (offer/answer/ICE, JWT-gated)                                      │
│ /ws/telemetry (JWT-gated telemetry stream)                                       │
│ VideoSource: webcam | file | synthetic test pattern (MediaRelay fan-out)         │
│ RobotSimulator: integrates joystick → speed, battery, temperature                │
└──────────────────────────────────────────────────────────────────────────────────┘
```

Default port: **8010**. All JSON field names are `snake_case`.

## 2. Authentication API

| Method | Path | Auth | Body | Success |
|---|---|---|---|---|
| POST | `/api/auth/login` | none | `{"username": str, "password": str}` | 200 `{"access_token": str, "token_type": "bearer", "expires_in": int_seconds, "user": {"username": str, "display_name": str}}` |
| GET | `/api/auth/me` | `Authorization: Bearer <jwt>` | – | 200 `{"username": str, "display_name": str}` |
| GET | `/api/health` | none | – | 200 `{"status": "ok"}` |

* `username` may be the username **or** email of the user.
* Bad credentials → `401 {"detail": "Invalid username or password"}`.
* Missing/invalid/expired token → `401 {"detail": "..."}`.
* 5 failed logins from one client IP within 60 s → `429` with `Retry-After` until the window passes.
* JWT: HS256, secret from `JWT_SECRET` env (≥ 32 chars, else startup fails; unset → random
  per-process secret), claims `sub` (username), `iat`, `exp` (default 60 min,
  `JWT_EXPIRE_MINUTES`), `iss` = `weblink`.
* Demo account: username `demo` / email `demo@weblink.local`, password `demo1234`.

## 3. WebSocket signaling — `ws://<host>:8010/ws/signaling?token=<jwt>`

Token is validated before anything else happens; invalid → the socket is accepted only to be
closed with code **4401** (a close code can't be delivered before the handshake). When the token
expires during the session, the socket (signaling and telemetry) is also closed with **4401**.
A user may hold at most 3 signaling sockets; more → close **4429**.
One WebSocket = one peer connection. Messages are JSON text frames, ≤ 64 000 chars; at most 64
`ice` messages per socket. Over-limit or malformed messages get an `error` reply and are ignored.
An `error` is fatal only when the server then closes the socket (failed offer negotiation,
peer connection `failed`).

| Direction | Message |
|---|---|
| client → server | `{"type": "offer", "sdp": "<sdp>"}` |
| server → client | `{"type": "answer", "sdp": "<sdp>"}` |
| both ways | `{"type": "ice", "candidate": {"candidate": str, "sdp_mid": str\|null, "sdp_m_line_index": int\|null}}` |
| client → server | `{"type": "bye"}` (server closes the peer connection) |
| server → client | `{"type": "error", "message": str}` |

Flow:
1. Client creates `RTCPeerConnection` (STUN `stun:stun.l.google.com:19302`).
2. Client adds a **recvonly video transceiver** and creates DataChannel
   **`control`** (ordered, reliable).
3. Client sends `offer`; trickles its ICE candidates as `ice` messages.
4. Server attaches the video track, answers (its candidates are embedded in the
   answer SDP — aiortc does not trickle), and adds any client `ice` candidates.
5. When the socket closes, the server closes the peer connection.

## 4. DataChannel `control` messages (JSON text)

Client → server, sent at **20 Hz while the stick is held** plus one final
zero message on release:

```json
{"type": "joystick", "linear": 0.42, "angular": -0.10, "seq": 17, "ts": 1730551234567}
```
* `linear`, `angular` ∈ [-1.0, 1.0] (forward / counter-clockwise positive), rounded to 3 dp.
* `seq` monotonically increasing int, `ts` = client epoch millis.
* Server logs every message: `joystick seq=17 linear=+0.420 angular=-0.100`.
* Server clamps out-of-range values and ignores malformed messages.

Server → client, every **200 ms** (5 Hz):

```json
{"type": "telemetry", "speed": 0.63, "battery": 87.4, "temperature": 36.2,
 "linear": 0.42, "angular": -0.10, "ts": 1730551234600}
```
* `speed` m/s (max 1.5), `battery` % 0–100, `temperature` °C.
* `linear`/`angular` echo the last command applied (lets the UI show round-trip).

## 5. Telemetry WebSocket — `ws://<host>:8010/ws/telemetry?token=<jwt>`

Same auth rule as signaling (close 4401). Server pushes the same `telemetry`
JSON as above every 200 ms. Used by the Home screen and as a fallback for the
Telemetry screen when WebRTC is not connected.

## 6. Robot simulator (backend)

One shared simulator for the whole server.
* Command times out to zero after 500 ms without joystick input (dead-man switch).
* `speed` approaches `|linear| * 1.5` with first-order lag.
* Battery drains 0.01 %/s idle + 0.15 %/s × load; recharges to 100 when it hits 5 (demo).
* Temperature approaches `30 + 15 × load` °C with lag. `load = max(|linear|, |angular|)`.

## 7. Video source (backend, `VIDEO_SOURCE` env)

* `test` (default) — synthetic 640×480 @ 30 fps pattern with clock overlay; needs no hardware.
* `webcam` — `/dev/video0` (`VIDEO_DEVICE` to override) via aiortc `MediaPlayer` (v4l2).
* `file:<path>` — loops a video file.
A single source is shared across clients with `MediaRelay`.

## 8. Flutter app

* State management: `provider` (`ChangeNotifier`).
* Packages: `flutter_webrtc`, `flutter_secure_storage`, `http`, `web_socket_channel`, `provider`.
* The server base URL is entered on the login screen (persisted), default
  `http://10.0.2.2:8010` on Android, `http://localhost:8010` elsewhere.
* Routes require a valid token; on 401 or logout the token is deleted and the
  app returns to Login. Logout also tears down WebRTC and WebSockets.
* Joystick is a custom widget: circular base, draggable knob, y-up = +linear,
  x-left = +angular, values clamped to unit circle with 0.08 dead-zone.
