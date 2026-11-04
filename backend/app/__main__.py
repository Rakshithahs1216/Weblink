"""``python -m app``: run the server on HOST/PORT from the environment."""

import uvicorn

from .main import app

if __name__ == "__main__":
    settings = app.state.settings
    uvicorn.run(app, host=settings.host, port=settings.port)
