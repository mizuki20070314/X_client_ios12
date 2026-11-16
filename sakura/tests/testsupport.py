"""Helpers shared by the sakura tests: paths, temp directories, environment, fakes. No network, no real home.

Imported by the test modules; it is not a test module itself (its name does not match test*.py).
"""

import contextlib
import hashlib
import io
import json
import os
import shutil
import sys
import tempfile
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
SAKURA = os.path.normpath(os.path.join(HERE, ".."))
APP_DIR = os.path.join(SAKURA, "app")
WWW_DIR = os.path.join(SAKURA, "www")
CGI_PATH = os.path.join(WWW_DIR, "cgi-bin", "xrelay.cgi")
POSIX = os.name != "nt"

if APP_DIR not in sys.path:
    sys.path.insert(0, APP_DIR)

from xrelay_app import catalog  # noqa: E402  (imported after the path is set)

CLIENT_KEY = "test-client-key-0001"
BEARER = "Bearer AAAA-test-bearer"
KEYS = {  # invented key material; the real keys come from X and are never in the repository
    "key": "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8w",
    "animation_key": "a1b2c3d4e5f60718293a4b5c6d7e8f9012345",
    "source": "https://x.com/i/jf/",
}


def key_hash(secret):
    return hashlib.sha256(secret.encode("utf-8")).hexdigest()


def profile(**overrides):
    values = {
        "auth_token": "auth-test-0000",
        "ct0": "ct0-test-0000",
        "user_agent": "Mozilla/5.0 (test browser)",
        "sec_ch_ua_platform": "\"Windows\"",
        "sec_ch_ua": "\"Chromium\";v=\"1\", \"Test\";v=\"2\"",
    }
    values.update(overrides)
    return values


def config_data(profiles=None, default="account1", client_key=CLIENT_KEY, bearer=BEARER):
    return {
        "client_token_sha256": key_hash(client_key),
        "default_profile": default,
        "x_bearer_token": bearer,
        "profiles": profiles if profiles is not None else {"account1": profile()},
    }


def write_config(path, data=None, mode=0o600):
    with open(str(path), "w", encoding="utf-8") as handle:
        json.dump(data if data is not None else config_data(), handle)
    if POSIX:
        os.chmod(str(path), mode)
    return str(path)


def temp_dir(testcase):
    path = tempfile.mkdtemp(prefix="xrelay-test-")
    testcase.addCleanup(shutil.rmtree, path, True)
    return path


@contextlib.contextmanager
def environment(**values):
    """Set (or with None, remove) environment variables for the duration of the block."""
    saved = {}
    for key, value in values.items():
        saved[key] = os.environ.get(key)
        if value is None:
            os.environ.pop(key, None)
        else:
            os.environ[key] = value
    try:
        yield
    finally:
        for key, value in saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


def relay_home(testcase, config_dir=None):
    """XRELAY_HOME in a temp directory and XRELAY_CONFIG pointing at a config file there (not written yet)."""
    root = temp_dir(testcase)
    config_file = os.path.join(config_dir or root, "config.json")
    patcher = environment(XRELAY_HOME=root, XRELAY_CONFIG=config_file)
    patcher.__enter__()
    testcase.addCleanup(patcher.__exit__, None, None, None)
    return root, config_file


def offline(testcase):
    """The operation catalog cannot download: the bundled snapshot answers instead."""
    patcher = mock.patch.object(catalog, "_download_document", side_effect=OSError("offline in tests"))
    patcher.start()
    testcase.addCleanup(patcher.stop)


class FakeStdout(object):
    """Accepts the text headers (write/flush) and keeps the body bytes in .buffer, like sys.stdout."""

    def __init__(self):
        self.text = []
        self.buffer = io.BytesIO()

    def write(self, text):
        self.text.append(text)

    def flush(self):
        pass

    def header_text(self):
        return "".join(self.text)

    def body(self):
        return self.buffer.getvalue()


def split_response(stdout):
    """(status code int, {lower-case header: value}, body bytes) of a FakeStdout response."""
    head, _, _ = stdout.header_text().partition("\r\n\r\n")
    lines = head.split("\r\n")
    status = int(lines[0].split(" ")[1])
    headers = {}
    for line in lines[1:]:
        name, _, value = line.partition(": ")
        headers[name.lower()] = value
    return status, headers, stdout.body()


class FakeResponse(object):
    """The parts of a requests response that the relay reads."""

    def __init__(self, status_code=200, headers=None, content=b"", cookies=None):
        self.status_code = status_code
        self.headers = dict(headers or {})
        self.content = content if isinstance(content, bytes) else content.encode("utf-8")
        self.cookies = dict(cookies or {})

    @property
    def text(self):
        return self.content.decode("utf-8")

    def raise_for_status(self):
        if self.status_code >= 400:
            raise IOError("HTTP {}".format(self.status_code))


def json_response(payload, status_code=200, headers=None, cookies=None):
    return FakeResponse(status_code, headers, json.dumps(payload).encode("utf-8"), cookies)


class FakeTransport(object):
    """A stand-in for requests.Session: answers come from a queue, every call is recorded."""

    def __init__(self, *answers):
        self.answers = list(answers)
        self.calls = []        # (method, url, kwargs)
        self.sessions = 0
        self.closed = 0

    def session_factory(self):
        transport = self
        self.sessions += 1

        class _Session(object):
            def get(self, url, **kwargs):
                return transport._next("GET", url, kwargs)

            def post(self, url, **kwargs):
                return transport._next("POST", url, kwargs)

            def close(self):
                transport.closed += 1

        return _Session()

    def _next(self, method, url, kwargs):
        self.calls.append((method, url, kwargs))
        if not self.answers:
            raise AssertionError("unexpected request: {} {}".format(method, url))
        answer = self.answers.pop(0)
        if isinstance(answer, BaseException):
            raise answer
        return answer
