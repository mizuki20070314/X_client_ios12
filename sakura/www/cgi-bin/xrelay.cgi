#!/usr/local/bin/python
# -*- coding: utf-8 -*-
"""Thin CGI entry point: finds the installed application under the private root and runs it.

The code lives in the xrelay_app package under PRIVATE_ROOT/app; third-party packages under PRIVATE_ROOT/python.
If the package cannot be imported, answer 503 with a plain message (no traceback, no dependency on the package).
"""

import os
import sys
from pathlib import Path


def _private_root():
    override = os.environ.get("XRELAY_HOME")
    if override:
        return Path(override).expanduser()
    return Path.home() / "private" / "xrelay"


def _unavailable():
    body = b'{"error": "CGI application is not installed."}'
    head = ("Status: 503 Service Unavailable\r\n"
            "Content-Type: application/json; charset=utf-8\r\n"
            "Cache-Control: no-store\r\n"
            "X-Content-Type-Options: nosniff\r\n"
            "Content-Length: {}\r\n\r\n").format(len(body)).encode("ascii")
    sys.stdout.buffer.write(head + body)
    sys.stdout.buffer.flush()


def main():
    try:
        root = _private_root()
        for part in ("app", "python"):
            folder = root / part
            if folder.is_dir():
                sys.path.insert(0, str(folder))
        from xrelay_app.main import run
    except Exception:
        _unavailable()
        return
    # www_root is the installed www directory, where requests.ndjson lies
    run(www_root=Path(__file__).resolve().parent.parent)


if __name__ == "__main__":
    main()
