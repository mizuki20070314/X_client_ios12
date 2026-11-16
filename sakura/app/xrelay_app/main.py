"""One CGI request from start to finish: routing, CGI key, profile selection and top-level error handling.

handle() never raises: every failure becomes an HTTP answer. Error bodies follow api-v2.md section 1 for /v2 and
the old {"error": "text"} for the other routes.
"""

import importlib
import os
import sys
from urllib.parse import parse_qsl

from xrelay_app import cgiio
from xrelay_app import config
from xrelay_app import legacy
from xrelay_app import routes
from xrelay_app.errors import RelayError
from xrelay_app.xapi import XClient

INTERNAL_BODY = {"error": {"code": "internal", "message": "サーバー内部でエラーが起きました。",
                           "x_code": None, "retry_after": None}}


def make_client(config_data, profile_name, profile):
    """Replaced by tests with a fake client."""
    return XClient(config_data, profile_name, profile)


def make_normalizer():
    """The normalize module (server-design section 3.7); replaced by tests with a fake."""
    try:
        return importlib.import_module("xrelay_app.normalize")
    except ImportError:
        raise RelayError(503, "unavailable", "応答の変換プログラムを読み込めませんでした。")


def handle(environ, stdin, stdout, www_root=None):
    legacy_shape = _legacy_shape(environ)
    try:
        status, body, content_type = _answer(environ, stdin, www_root)
    except RelayError as error:
        status = error.status
        body = {"error": error.message} if legacy_shape else error.body()
        content_type = cgiio.JSON_TYPE
    except Exception as error:
        # the type name only: messages and tracebacks could contain secrets
        _log_internal(error)
        status, body, content_type = 500, INTERNAL_BODY, cgiio.JSON_TYPE
    try:
        cgiio.send(status, body, environ, stdout, content_type)
    except Exception:
        pass  # the client has gone away; there is nothing else to send


def run(www_root=None):
    handle(os.environ, sys.stdin, sys.stdout, www_root)


def _answer(environ, stdin, www_root):
    """(status, body, content type); body is a dict or bytes."""
    request = cgiio.read_request(environ, stdin)
    path = request.path
    if request.method == "GET" and path == "/healthz":
        return 200, {"status": "ok"}, cgiio.JSON_TYPE
    settings = config.load_config()
    if not config.client_key_matches(settings, environ):
        raise RelayError(401, "unauthorized", "CGIキーが無効か、指定されていません。")
    if request.method == "GET" and path == "/profiles":
        return 200, {"profiles": sorted(settings["profiles"].keys())}, cgiio.JSON_TYPE
    if _is_v2(path):
        name, profile = _select(settings, environ)
        status, payload = routes.dispatch(request, make_client(settings, name, profile), make_normalizer())
        return status, cgiio.encode_payload(payload), cgiio.JSON_TYPE
    if path.startswith("/i/api/graphql/"):
        name, profile = _select(settings, environ)
        status, content_type, content = legacy.dispatch(request, make_client(settings, name, profile), www_root)
        return status, content, content_type
    raise RelayError(404, "not_found", "Unknown API route.")


def _select(settings, environ):
    name = (environ.get("HTTP_X_PROFILE_NAME") or "").strip()
    return config.select_profile(settings, name or None)


def _is_v2(path):
    return path == "/v2" or path.startswith("/v2/")


def _legacy_shape(environ):
    """True for the routes that keep the old {"error": "text"} body. Best effort; never raises."""
    try:
        pairs = parse_qsl(environ.get("QUERY_STRING", ""), keep_blank_values=True)
    except Exception:
        return False
    paths = [value for key, value in pairs if key == "__path"]
    if len(paths) != 1:
        return False  # no route known: the /v2 shape is the default
    return not _is_v2(paths[0])


def _log_internal(error):
    try:
        sys.stderr.write("xrelay: internal error ({})\n".format(type(error).__name__))
    except Exception:
        pass
