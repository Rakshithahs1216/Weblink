import socket
import threading
import time

import pytest
import uvicorn
from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app

TEST_SECRET = "test-secret-for-unit-tests-only-0123456789abcdef"


@pytest.fixture
def settings() -> Settings:
    # No STUN: tests must not depend on internet access.
    return Settings(jwt_secret=TEST_SECRET, stun_servers=[])


@pytest.fixture
def client(settings):
    with TestClient(create_app(settings)) as c:
        yield c


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class LiveServer:
    def __init__(self, app, port: int):
        self.app = app
        self.port = port
        self.http_url = f"http://127.0.0.1:{port}"
        self.ws_url = f"ws://127.0.0.1:{port}"


@pytest.fixture(scope="session")
def live_server():
    """A real uvicorn server in a background thread (WebSockets + WebRTC need one)."""
    app = create_app(Settings(jwt_secret=TEST_SECRET, stun_servers=[]))
    port = _free_port()
    server = uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=port, log_level="warning"))
    thread = threading.Thread(target=server.run, daemon=True)
    thread.start()
    deadline = time.monotonic() + 15
    while not server.started:
        if time.monotonic() > deadline or not thread.is_alive():
            raise RuntimeError("uvicorn did not start")
        time.sleep(0.05)
    yield LiveServer(app, port)
    server.should_exit = True
    thread.join(timeout=10)
