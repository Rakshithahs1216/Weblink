"""Runtime settings, read from environment variables (see .env.example)."""

from __future__ import annotations

import logging
import os
import secrets
from dataclasses import dataclass, field

MIN_SECRET_LENGTH = 32
DEFAULT_STUN = "stun:stun.l.google.com:19302"

logger = logging.getLogger("weblink.config")


def _split_csv(value: str) -> list[str]:
    return [item.strip() for item in value.split(",") if item.strip()]


@dataclass(frozen=True)
class Settings:
    # None (JWT_SECRET unset) -> a random per-process secret: safe by default, but
    # tokens stop working when the server restarts.
    jwt_secret: str | None = None
    generated_secret: bool = field(default=False, init=False)
    jwt_expire_minutes: int = 60
    video_source: str = "test"  # "test" | "webcam" | "file:<path>"
    video_device: str = "/dev/video0"
    host: str = "0.0.0.0"
    port: int = 8010
    cors_origins: list[str] = field(default_factory=lambda: ["*"])
    stun_servers: list[str] = field(default_factory=lambda: [DEFAULT_STUN])
    log_level: str = "INFO"

    def __post_init__(self) -> None:
        if self.jwt_secret is None:  # frozen dataclass: assign through object
            object.__setattr__(self, "jwt_secret", secrets.token_urlsafe(48))
            object.__setattr__(self, "generated_secret", True)
        elif len(self.jwt_secret) < MIN_SECRET_LENGTH:
            raise ValueError(
                f"JWT_SECRET must be at least {MIN_SECRET_LENGTH} characters "
                '(generate one: python3 -c "import secrets; print(secrets.token_urlsafe(48))")'
            )

    @classmethod
    def from_env(cls) -> Settings:
        env = os.environ
        return cls(
            jwt_secret=env.get("JWT_SECRET", "").strip() or None,
            jwt_expire_minutes=int(env.get("JWT_EXPIRE_MINUTES", "60")),
            video_source=env.get("VIDEO_SOURCE", "test").strip() or "test",
            video_device=env.get("VIDEO_DEVICE", "/dev/video0"),
            host=env.get("HOST", "0.0.0.0"),
            port=int(env.get("PORT", "8010")),
            cors_origins=_split_csv(env.get("CORS_ORIGINS", "*")),
            # Empty string disables STUN (host candidates only, e.g. offline LAN).
            stun_servers=_split_csv(env.get("STUN_SERVERS", DEFAULT_STUN)),
            log_level=env.get("LOG_LEVEL", "INFO").upper(),
        )

    def warn_if_insecure(self) -> None:
        if self.generated_secret:
            logger.warning(
                "JWT_SECRET is not set: using a random secret for this process. "
                "Tokens become invalid when the server restarts; set JWT_SECRET to keep them."
            )
