"""Users, password hashing (bcrypt) and JWT (HS256) handling."""

from __future__ import annotations

import asyncio
import contextlib
import logging
import threading
import time
from collections import defaultdict, deque
from collections.abc import AsyncIterator
from dataclasses import dataclass

import bcrypt
import jwt
from fastapi import Depends, HTTPException, Request, WebSocket, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

logger = logging.getLogger("weblink.auth")

JWT_ALGORITHM = "HS256"
JWT_ISSUER = "weblink"


class AuthError(Exception):
    """Raised when a token is missing, malformed, expired or names an unknown user."""


@dataclass(frozen=True)
class User:
    username: str
    email: str
    display_name: str
    password_hash: bytes

    def public(self) -> dict:
        return {"username": self.username, "display_name": self.display_name}


def hash_password(password: str) -> bytes:
    return bcrypt.hashpw(password.encode("utf-8"), bcrypt.gensalt())


class UserStore:
    """In-memory user store. Lookups accept either the username or the email."""

    def __init__(self, users: list[User]):
        self._by_username = {u.username.lower(): u for u in users}
        self._by_email = {u.email.lower(): u for u in users}
        # Compared against when the user does not exist, so that response time
        # does not reveal which usernames are valid.
        self._dummy_hash = hash_password("not-a-real-password")

    @classmethod
    def with_demo_user(cls) -> UserStore:
        demo = User(
            username="demo",
            email="demo@weblink.local",
            display_name="Demo Operator",
            password_hash=hash_password("demo1234"),
        )
        return cls([demo])

    def get(self, identifier: str) -> User | None:
        key = identifier.strip().lower()
        return self._by_username.get(key) or self._by_email.get(key)

    def authenticate(self, identifier: str, password: str) -> User | None:
        user = self.get(identifier)
        hashed = user.password_hash if user else self._dummy_hash
        try:
            ok = bcrypt.checkpw(password.encode("utf-8"), hashed)
        except ValueError:
            ok = False
        return user if (user and ok) else None


class LoginThrottle:
    """Per-client limit on failed logins: ``max_failures`` per sliding ``window`` seconds."""

    def __init__(self, max_failures: int = 5, window: float = 60.0, clock=time.monotonic):
        self.max_failures = max_failures
        self.window = window
        self._clock = clock
        self._failures: dict[str, deque[float]] = defaultdict(deque)
        self._lock = threading.Lock()

    def _prune(self, key: str, now: float) -> deque[float]:
        failures = self._failures[key]
        while failures and now - failures[0] >= self.window:
            failures.popleft()
        if not failures:
            del self._failures[key]  # keep the table from growing with one-off clients
            return deque()
        return failures

    def retry_after(self, key: str) -> float:
        """Seconds until ``key`` may try again; 0 if allowed now."""
        with self._lock:
            now = self._clock()
            failures = self._prune(key, now)
            if len(failures) < self.max_failures:
                return 0.0
            return self.window - (now - failures[0])

    def record_failure(self, key: str) -> None:
        with self._lock:
            self._failures[key].append(self._clock())

    def reset(self, key: str) -> None:
        with self._lock:
            self._failures.pop(key, None)


class TokenService:
    def __init__(self, secret: str, expire_minutes: int):
        self._secret = secret
        self.expires_in = expire_minutes * 60

    def create(self, username: str, now: float | None = None, expires_in: int | None = None) -> str:
        issued = int(now if now is not None else time.time())
        ttl = self.expires_in if expires_in is None else expires_in
        claims = {"sub": username, "iat": issued, "exp": issued + ttl, "iss": JWT_ISSUER}
        return jwt.encode(claims, self._secret, algorithm=JWT_ALGORITHM)

    def verify(self, token: str) -> tuple[str, int]:
        """Return ``(username, exp)`` of a valid token, else raise AuthError."""
        try:
            claims = jwt.decode(
                token,
                self._secret,
                algorithms=[JWT_ALGORITHM],
                issuer=JWT_ISSUER,
                options={"require": ["sub", "iat", "exp", "iss"]},
            )
        except jwt.ExpiredSignatureError as exc:
            raise AuthError("Token has expired") from exc
        except jwt.InvalidTokenError as exc:
            raise AuthError("Invalid token") from exc
        sub = claims.get("sub")
        if not isinstance(sub, str) or not sub:
            raise AuthError("Invalid token")
        return sub, int(claims["exp"])


class Authenticator:
    """Combines the user store and token service; shared by REST and WebSockets."""

    def __init__(self, users: UserStore, tokens: TokenService):
        self.users = users
        self.tokens = tokens

    def session_from_token(self, token: str | None) -> tuple[User, int]:
        """The user named by a valid token, and the token's expiry (epoch seconds)."""
        if not token:
            raise AuthError("Not authenticated")
        username, expires_at = self.tokens.verify(token)
        user = self.users.get(username)
        if user is None:
            raise AuthError("Unknown user")
        return user, expires_at


_bearer = HTTPBearer(auto_error=False)


def get_authenticator(request: Request) -> Authenticator:
    return request.app.state.auth


def current_user(
    credentials: HTTPAuthorizationCredentials | None = Depends(_bearer),
    auth: Authenticator = Depends(get_authenticator),
) -> User:
    """FastAPI dependency: the user named by a valid ``Authorization: Bearer`` token."""
    try:
        return auth.session_from_token(credentials.credentials if credentials else None)[0]
    except AuthError as exc:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=str(exc),
            headers={"WWW-Authenticate": "Bearer"},
        ) from exc


WS_CLOSE_UNAUTHORIZED = 4401


@dataclass(frozen=True)
class SocketSession:
    user: User
    expires_at: int  # token expiry, epoch seconds; the socket is closed with 4401 then

    def seconds_left(self) -> float:
        return self.expires_at - time.time()


async def _close_when_expired(websocket: WebSocket, session: SocketSession) -> None:
    await asyncio.sleep(max(0.0, session.seconds_left()))
    with contextlib.suppress(Exception):
        await websocket.close(code=WS_CLOSE_UNAUTHORIZED, reason="Token has expired")


@contextlib.asynccontextmanager
async def expiring_socket(websocket: WebSocket, session: SocketSession) -> AsyncIterator[None]:
    """Close the socket with 4401 if the token that opened it expires inside the block."""
    task = asyncio.create_task(_close_when_expired(websocket, session))
    try:
        yield
    finally:
        task.cancel()


async def websocket_user(websocket: WebSocket) -> SocketSession | None:
    """Validate ``?token=`` before anything else happens on a WebSocket.

    On failure the socket is closed with code 4401 and None is returned. The
    handshake must be completed to deliver a close code at all (closing before
    ``accept`` turns into a bare HTTP 403), so it is accepted only for that.
    """
    auth: Authenticator = websocket.app.state.auth
    try:
        user, expires_at = auth.session_from_token(websocket.query_params.get("token"))
        return SocketSession(user, expires_at)
    except AuthError as exc:
        logger.info("Rejected %s WebSocket: %s", websocket.url.path, exc)
        await websocket.accept()
        await websocket.close(code=WS_CLOSE_UNAUTHORIZED, reason=str(exc))
        return None
