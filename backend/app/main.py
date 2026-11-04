"""FastAPI application: REST auth, signaling and telemetry WebSockets."""

from __future__ import annotations

import logging
import re
from contextlib import asynccontextmanager

import anyio
from fastapi import Depends, FastAPI, HTTPException, Request, status
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

from .auth import Authenticator, LoginThrottle, TokenService, User, UserStore, current_user
from .config import Settings
from .robot import RobotSimulator
from .signaling import PeerRegistry, signaling_endpoint
from .telemetry import telemetry_endpoint
from .video import VideoSource

logger = logging.getLogger("weblink")


class _RedactTokens(logging.Filter):
    """Uvicorn logs WebSocket paths including the query string; hide ``token=``."""

    _pattern = re.compile(r"(token=)[^&\s\"']+")

    def filter(self, record: logging.LogRecord) -> bool:
        if record.args:
            record.args = tuple(
                self._pattern.sub(r"\1***", a) if isinstance(a, str) else a for a in record.args
            )
        if isinstance(record.msg, str):
            record.msg = self._pattern.sub(r"\1***", record.msg)
        return True


def configure_logging(level: str) -> None:
    app_logger = logging.getLogger("weblink")
    app_logger.setLevel(level)
    if not app_logger.handlers:
        handler = logging.StreamHandler()
        handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)-7s %(name)s: %(message)s"))
        app_logger.addHandler(handler)
        app_logger.propagate = False
    redact = _RedactTokens()
    for name in ("uvicorn.error", "uvicorn.access"):
        target = logging.getLogger(name)
        if not any(isinstance(f, _RedactTokens) for f in target.filters):
            target.addFilter(redact)


class LoginRequest(BaseModel):
    username: str  # username or email
    password: str


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or Settings.from_env()
    configure_logging(settings.log_level)
    settings.warn_if_insecure()

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        # bcrypt is deliberately slow: cap concurrent checks so a login flood can't
        # occupy every threadpool worker. Waiters queue on the event loop, not in threads.
        app.state.bcrypt_limiter = anyio.CapacityLimiter(4)
        app.state.video.start()
        logger.info("Weblink backend ready")
        try:
            yield
        finally:
            logger.info("Shutting down: closing %d peer connection(s)", len(app.state.peers))
            await app.state.peers.close_all()
            app.state.video.stop()

    app = FastAPI(title="Weblink backend", version="1.0.0", lifespan=lifespan)
    app.state.settings = settings
    app.state.login_throttle = LoginThrottle()
    app.state.auth = Authenticator(
        UserStore.with_demo_user(), TokenService(settings.jwt_secret, settings.jwt_expire_minutes)
    )
    app.state.simulator = RobotSimulator()
    app.state.video = VideoSource(settings.video_source, settings.video_device)
    app.state.peers = PeerRegistry()

    # Bearer tokens, not cookies, so credentials are not needed and "*" is safe for dev.
    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.cors_origins,
        allow_methods=["*"],
        allow_headers=["*"],
    )

    @app.get("/api/health")
    async def health() -> dict:
        return {"status": "ok"}

    @app.post("/api/auth/login")
    async def login(body: LoginRequest, request: Request) -> dict:
        auth: Authenticator = request.app.state.auth
        throttle: LoginThrottle = request.app.state.login_throttle
        client = request.client.host if request.client else "unknown"
        wait = throttle.retry_after(client)
        if wait > 0:
            raise HTTPException(
                status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                detail="Too many failed login attempts; try again later",
                headers={"Retry-After": str(int(wait) + 1)},
            )
        user = await anyio.to_thread.run_sync(
            auth.users.authenticate,
            body.username,
            body.password,
            limiter=request.app.state.bcrypt_limiter,
        )
        if user is None:
            throttle.record_failure(client)
            logger.info("Failed login attempt")
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="Invalid username or password",
                headers={"WWW-Authenticate": "Bearer"},
            )
        throttle.reset(client)
        logger.info("User %s logged in", user.username)
        return {
            "access_token": auth.tokens.create(user.username),
            "token_type": "bearer",
            "expires_in": auth.tokens.expires_in,
            "user": user.public(),
        }

    @app.get("/api/auth/me")
    async def me(user: User = Depends(current_user)) -> dict:
        return user.public()

    app.add_api_websocket_route("/ws/signaling", signaling_endpoint)
    app.add_api_websocket_route("/ws/telemetry", telemetry_endpoint)
    return app


app = create_app()
