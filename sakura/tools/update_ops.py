"""Rebuild app/xrelay_app/data/ops.json, the operation snapshot bundled with the application.

Usage (run from the repository root, isolated mode because the input is downloaded data):
    python -I sakura/tools/update_ops.py <path to API.json>
Without a path the public catalog is downloaded. Every operation of server-design section 4 must be present and
valid; otherwise nothing is written.
"""

import json
import os
import sys
import tempfile
import time

TOOLS_DIR = os.path.dirname(os.path.abspath(__file__))
APP_DIR = os.path.normpath(os.path.join(TOOLS_DIR, "..", "app"))
OUTPUT = os.path.join(APP_DIR, "xrelay_app", "data", "ops.json")
sys.path.insert(0, APP_DIR)

from xrelay_app import catalog  # noqa: E402  (needs APP_DIR on sys.path)


def _read_document(path):
    with open(path, "rb") as handle:
        return json.loads(handle.read().decode("utf-8"))


def _write_atomic(path, text):
    descriptor, temporary = tempfile.mkstemp(prefix="ops.", suffix=".tmp", dir=os.path.dirname(path))
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(text.encode("utf-8"))
        os.replace(temporary, path)
    except BaseException:
        if os.path.exists(temporary):
            os.unlink(temporary)
        raise


def main(argv):
    try:
        if len(argv) > 1:
            document = _read_document(argv[1])
        else:
            document = catalog._download_document()
    except (OSError, ValueError) as error:
        sys.stderr.write("cannot read the operation catalog: {}\n".format(type(error).__name__))
        return 1
    entries, problems = catalog.reduce_document(document)
    if problems:
        sys.stderr.write("missing or invalid operations, nothing written: {}\n".format(", ".join(problems)))
        return 1
    snapshot = {"fetched_at": int(time.time()), "ops": entries}
    text = json.dumps(snapshot, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    _write_atomic(OUTPUT, text)
    print("wrote {} operations to {}".format(len(entries), OUTPUT))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
