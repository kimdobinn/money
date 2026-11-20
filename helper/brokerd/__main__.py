import logging
import socket
import sys
import time
from logging.handlers import RotatingFileHandler

import uvicorn

from .config import HOST, LOG_DIR, PORT, ensure_dirs


def main() -> None:
    ensure_dirs()
    handler = RotatingFileHandler(LOG_DIR / "brokerd.log", maxBytes=2_000_000, backupCount=3)
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s"))
    logging.basicConfig(level=logging.INFO, handlers=[handler, logging.StreamHandler()])
    logging.getLogger("httpx").setLevel(logging.WARNING)
    logging.getLogger("ib_async").setLevel(logging.CRITICAL)  # we log our own concise messages
    # Single instance: a second copy would issue a new Toss token and revoke the first one's.
    probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)  # ignore TIME_WAIT, like uvicorn
    try:
        probe.bind((HOST, PORT))
    except OSError:
        logging.getLogger("brokerd").error("port %s already in use — another brokerd is running; exiting", PORT)
        time.sleep(30)  # keep launchd from respawning in a tight loop
        sys.exit(1)
    finally:
        probe.close()
    from .server import app

    uvicorn.run(app, host=HOST, port=PORT, log_level="warning", access_log=False)


if __name__ == "__main__":
    main()
