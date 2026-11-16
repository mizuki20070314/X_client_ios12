"""CGI request parsing and response writing (headers exactly as server-design section 3.3)."""

import gzip
import json
import re
from http import HTTPStatus
from urllib.parse import parse_qsl

from xrelay_app.errors import RelayError

MAX_BODY_BYTES = 256 * 1024
GZIP_MIN_BYTES = 1024  # below this, gzip costs more than it saves
GZIP_LEVEL = 6
JSON_TYPE = "application/json; charset=utf-8"
CONTENT_LENGTH_RE = re.compile(r"[0-9]{1,12}")


class Request(object):
    def __init__(self, method, path, query, environ, body):
        self.method = method    # "GET" or "POST"
        self.path = path        # "/v2/home"
        self.query = query      # list of (key, value) pairs without __path
        self.environ = environ  # the CGI environment (headers as HTTP_*)
        self.body = body        # bytes, b"" for GET

    def param(self, name, default=None):
        """The first query value with that name."""
        for key, value in self.query:
            if key == name:
                return value
        return default

    def json(self):
        """The body as a JSON object; RelayError(400) for anything else."""
        try:
            payload = json.loads(self.body.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            payload = None
        if not isinstance(payload, dict):
            raise RelayError(400, "bad_request", "リクエスト本文はJSONオブジェクトで送ってください。")
        return payload


def read_request(environ, stdin):
    method = environ.get("REQUEST_METHOD", "GET").upper()
    if method not in ("GET", "POST"):
        raise RelayError(405, "bad_request", "GETとPOSTだけ使えます。")
    path, query = _route_and_query(environ.get("QUERY_STRING", ""))
    # only POST has a body; a GET must not block on stdin
    body = _read_body(environ, stdin) if method == "POST" else b""
    return Request(method, path, query, environ, body)


def _route_and_query(query_string):
    pairs = parse_qsl(query_string, keep_blank_values=True)
    paths = [value for key, value in pairs if key == "__path"]
    if len(paths) != 1:
        raise RelayError(400, "bad_request", "__path は1つだけ指定してください。")
    path = paths[0]
    if (not path.startswith("/") or "\\" in path or "\x00" in path
            or any(part == ".." for part in path.split("/"))):
        raise RelayError(400, "bad_request", "APIのパスが正しくありません。")
    query = [(key, value) for key, value in pairs if key != "__path"]
    return path, query


def _read_body(environ, stdin):
    raw_length = (environ.get("CONTENT_LENGTH") or "0").strip()
    if CONTENT_LENGTH_RE.fullmatch(raw_length) is None:
        raise RelayError(400, "bad_request", "Content-Length が正しくありません。")
    length = int(raw_length)
    if length > MAX_BODY_BYTES:
        raise RelayError(413, "bad_request", "リクエスト本文が大きすぎます。")
    if length == 0:
        return b""
    reader = getattr(stdin, "buffer", stdin)  # sys.stdin is text; the body is bytes
    data = reader.read(length)
    if len(data) != length:
        raise RelayError(400, "bad_request", "リクエスト本文が途中で切れています。")
    return data


def encode_payload(payload):
    """dict -> compact UTF-8 JSON; str and bytes are encoded as they are."""
    if isinstance(payload, dict):
        return json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    if isinstance(payload, str):
        return payload.encode("utf-8")
    return bytes(payload)


def send(status, payload, environ, stdout, content_type=JSON_TYPE):
    """Write one CGI response: header lines as text, the body to stdout.buffer."""
    body = encode_payload(payload)
    lines = [
        "Status: {} {}".format(status, _reason(status)),
        "Content-Type: {}".format(content_type),
        "Cache-Control: no-store",
        "X-Content-Type-Options: nosniff",
        "Vary: Accept-Encoding",
    ]
    if _accepts_gzip(environ) and len(body) >= GZIP_MIN_BYTES:
        body = gzip.compress(body, GZIP_LEVEL)
        lines.append("Content-Encoding: gzip")
    lines.append("Content-Length: {}".format(len(body)))
    stdout.write("".join(line + "\r\n" for line in lines) + "\r\n")
    stdout.flush()
    stdout.buffer.write(body)
    stdout.buffer.flush()


def _reason(status):
    try:
        return HTTPStatus(status).phrase
    except ValueError:
        return "Error"


def _accepts_gzip(environ):
    return "gzip" in (environ.get("HTTP_ACCEPT_ENCODING") or "").lower()
