#!/usr/local/bin/python
# -*- coding: utf-8 -*-
"""Per-request CGI bridge to X's undocumented web GraphQL API.

X session cookies and the CGI client key live in a private config file outside
the document root. This script never logs request headers or credentials.
"""

from __future__ import print_function

import hashlib
import hmac
import json
import os
import re
import stat
import sys
import time
from http import HTTPStatus
from pathlib import Path
from urllib.parse import parse_qsl, urlencode, urljoin, urlsplit

PRIVATE_ROOT = Path.home() / "private" / "xrelay"
PRIVATE_PYTHON = PRIVATE_ROOT / "python"
if PRIVATE_PYTHON.is_dir():
    sys.path.insert(0, str(PRIVATE_PYTHON))

try:
    import fcntl
except ImportError:
    fcntl = None

try:
    import requests
except ImportError:
    requests = None


APP_ORIGIN = "https://x.com"
MAX_BODY_BYTES = 256 * 1024
TID_CACHE_SECONDS = 12 * 60 * 60
TID_SCRIPT_LIST_URL = (
    "https://raw.githubusercontent.com/fa0311/TwitterInternalAPIDocument/"
    "develop/docs/json/ScriptLoadJson.json"
)
ALLOWED_OPERATIONS = {
    ("GET", "HomeTimeline"),
    ("GET", "SearchTimeline"),
    ("POST", "CreateTweet"),
}
ALLOWED_GRAPHQL_QUERY_KEYS = {"variables", "features", "fieldToggles"}
ALLOWED_POST_BODY_KEYS = {"queryId", "variables", "features", "fieldToggles"}


class RequestError(Exception):
    def __init__(self, status, message):
        Exception.__init__(self, message)
        self.status = status
        self.message = message


def _config_path():
    override = os.environ.get("XRELAY_CONFIG")
    if override:
        return Path(override).expanduser()
    return PRIVATE_ROOT / "config.json"


def _load_config():
    path = _config_path()
    try:
        file_stat = path.stat()
        if stat.S_IMODE(file_stat.st_mode) & 0o077:
            raise RequestError(503, "Private configuration permissions must be 600.")
        with path.open("r", encoding="utf-8") as handle:
            config = json.load(handle)
    except RequestError:
        raise
    except (IOError, ValueError):
        raise RequestError(503, "Private CGI configuration is unavailable.")

    app_hash = config.get("client_token_sha256", "")
    x_bearer = config.get("x_bearer_token", "")
    profiles = config.get("profiles", {})
    if not re.match(r"^[0-9a-f]{64}$", app_hash):
        raise RequestError(503, "CGI client token is not configured.")
    if not isinstance(x_bearer, str) or not x_bearer.strip():
        raise RequestError(503, "X web-app bearer token is not configured.")
    if not isinstance(profiles, dict) or not profiles:
        raise RequestError(503, "No X session profiles are configured.")
    return config


def _send(status, body, content_type="application/json; charset=utf-8"):
    if isinstance(body, dict):
        body = json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    if not isinstance(body, bytes):
        body = body.encode("utf-8")
    try:
        reason = HTTPStatus(status).phrase
    except ValueError:
        reason = "Error"
    sys.stdout.write("Status: {} {}\r\n".format(status, reason))
    sys.stdout.write("Content-Type: {}\r\n".format(content_type))
    sys.stdout.write("Cache-Control: no-store\r\n")
    sys.stdout.write("X-Content-Type-Options: nosniff\r\n")
    sys.stdout.write("Content-Length: {}\r\n\r\n".format(len(body)))
    sys.stdout.flush()
    sys.stdout.buffer.write(body)
    sys.stdout.buffer.flush()


def _client_token_matches(config):
    supplied = os.environ.get("HTTP_X_RELAY_KEY", "").strip()
    if not supplied:
        authorization = os.environ.get("HTTP_AUTHORIZATION", "")
        if not authorization:
            authorization = os.environ.get("REDIRECT_HTTP_AUTHORIZATION", "")
        match = re.match(r"^Bearer\s+(.+)$", authorization, re.I)
        supplied = match.group(1).strip() if match else ""
    if not supplied:
        return False
    digest = hashlib.sha256(supplied.encode("utf-8")).hexdigest()
    return hmac.compare_digest(digest, config["client_token_sha256"])


def _route_and_query():
    pairs = parse_qsl(os.environ.get("QUERY_STRING", ""), keep_blank_values=True)
    paths = [value for key, value in pairs if key == "__path"]
    if len(paths) != 1:
        raise RequestError(400, "A single __path parameter is required.")
    path = paths[0]
    if (not path.startswith("/") or "\\" in path or "\x00" in path
            or any(part == ".." for part in path.split("/"))):
        raise RequestError(400, "Invalid API path.")
    query = [(key, value) for key, value in pairs if key != "__path"]
    return path, query


def _load_catalog():
    catalog_path = Path(__file__).resolve().parent.parent / "requests.ndjson"
    try:
        rows = []
        with catalog_path.open("r", encoding="utf-8") as handle:
            for line in handle:
                if line.strip():
                    rows.append(json.loads(line))
        return rows
    except (IOError, ValueError):
        raise RequestError(503, "The bundled request catalog is unavailable.")


def _catalog_record(method, full_path):
    if not full_path.startswith("/i/api/"):
        return None
    catalog_path = full_path[len("/i/api"):]
    operation = catalog_path.rsplit("/", 1)[-1]
    if (method, operation) not in ALLOWED_OPERATIONS:
        return None
    for row in _load_catalog():
        if row.get("method") == method and row.get("path") == catalog_path:
            return row
    return None


def _read_body():
    try:
        length = int(os.environ.get("CONTENT_LENGTH", "0") or "0")
    except ValueError:
        raise RequestError(400, "Invalid Content-Length.")
    if length < 0 or length > MAX_BODY_BYTES:
        raise RequestError(413, "Request body is too large.")
    data = sys.stdin.buffer.read(length) if length else b""
    if len(data) != length:
        raise RequestError(400, "Incomplete request body.")
    return data


def _select_profile(config):
    name = os.environ.get("HTTP_X_PROFILE_NAME", "").strip()
    if not name:
        name = config.get("default_profile", "")
    profiles = config["profiles"]
    if name not in profiles:
        raise RequestError(400, "Unknown profile.")
    profile = profiles[name]
    if not profile.get("auth_token") or not profile.get("ct0"):
        raise RequestError(503, "The selected X session is incomplete.")
    if not profile.get("user_agent"):
        raise RequestError(503, "The selected profile has no User-Agent.")
    return name, profile


def _cache_dir():
    directory = _config_path().parent / "tid-cache"
    if not directory.exists():
        directory.mkdir(mode=0o700, parents=True)
    return directory


def _write_private(path, content):
    temporary = path.with_name(path.name + ".tmp")
    descriptor = os.open(str(temporary), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(content)
        os.replace(str(temporary), str(path))
    finally:
        try:
            if temporary.exists():
                temporary.unlink()
        except OSError:
            pass


def _get_ondemand_script_url(session, home_soup, get_ondemand_file_url):
    candidate = None
    try:
        candidate = get_ondemand_file_url(response=home_soup)
    except Exception:
        # Current X HTML may not expose the chunk name in the markup. The
        # linked internal-API catalog also tracks the current ondemand.s URL.
        try:
            response = session.get(TID_SCRIPT_LIST_URL, timeout=(5, 20))
            response.raise_for_status()
            candidate = json.loads(response.text).get("ondemand.s")
        except Exception:
            candidate = None

    if not isinstance(candidate, str):
        raise RequestError(502, "Could not locate X transaction-ID script.")
    candidate = urljoin(APP_ORIGIN + "/", candidate)
    parsed = urlsplit(candidate)
    if (parsed.scheme != "https" or parsed.hostname != "abs.twimg.com"
            or not parsed.path.startswith("/responsive-web/client-web/ondemand.s.")
            or not parsed.path.endswith(".js") or parsed.query or parsed.fragment):
        raise RequestError(502, "X returned an unexpected transaction-ID script URL.")
    return candidate


def _transaction_client(profile):
    try:
        from bs4 import BeautifulSoup
        from x_client_transaction import ClientTransaction
        from x_client_transaction.utils import generate_headers, get_ondemand_file_url
    except ImportError:
        raise RequestError(503, "Install the CGI Python dependencies from sakura/requirements.txt.")

    fingerprint = hashlib.sha256(
        (profile["user_agent"] + profile.get("sec_ch_ua_platform", "")).encode("utf-8")
    ).hexdigest()[:16]
    cache_dir = _cache_dir() / fingerprint
    if not cache_dir.exists():
        cache_dir.mkdir(mode=0o700)
    home_path = cache_dir / "home.html"
    script_path = cache_dir / "ondemand.js"
    lock_path = cache_dir / "tid.lock"
    lock_fd = os.open(str(lock_path), os.O_RDWR | os.O_CREAT, 0o600) if fcntl else None
    try:
        if fcntl:
            fcntl.flock(lock_fd, fcntl.LOCK_EX)
        fresh = False
        try:
            fresh = (time.time() - script_path.stat().st_mtime) < TID_CACHE_SECONDS
            fresh = fresh and home_path.exists()
        except OSError:
            fresh = False

        if not fresh:
            if requests is None:
                raise RequestError(503, "Install requests from sakura/requirements.txt.")
            session = requests.Session()
            try:
                session.headers.update(generate_headers())
                session.headers["User-Agent"] = profile["user_agent"]
                platform = profile.get("sec_ch_ua_platform")
                if platform:
                    session.headers["sec-ch-ua-platform"] = platform
                if profile.get("sec_ch_ua"):
                    session.headers["sec-ch-ua"] = profile["sec_ch_ua"]
                home_response = session.get(APP_ORIGIN + "/home", timeout=(5, 25))
                home_response.raise_for_status()
                home_html = home_response.text
                home_soup = BeautifulSoup(home_html, "html.parser")
                script_url = _get_ondemand_script_url(session, home_soup, get_ondemand_file_url)
                script_response = session.get(script_url, timeout=(5, 25))
                script_response.raise_for_status()
                _write_private(home_path, home_html.encode("utf-8"))
                _write_private(script_path, script_response.text.encode("utf-8"))
            except RequestError:
                raise
            except Exception:
                raise RequestError(502, "Could not refresh X transaction-ID assets.")
            finally:
                session.close()

        home_html = home_path.read_text(encoding="utf-8")
        script_text = script_path.read_text(encoding="utf-8")
        return ClientTransaction(
            home_page_response=BeautifulSoup(home_html, "html.parser"),
            ondemand_file_response=script_text,
        )
    finally:
        if fcntl and lock_fd is not None:
            fcntl.flock(lock_fd, fcntl.LOCK_UN)
            os.close(lock_fd)


def _validate_post(body, expected_query_id):
    try:
        payload = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        raise RequestError(400, "Expected a JSON request body.")
    if not isinstance(payload, dict) or set(payload) - ALLOWED_POST_BODY_KEYS:
        raise RequestError(400, "Unsupported post payload.")
    if payload.get("queryId") != expected_query_id:
        raise RequestError(400, "GraphQL query ID does not match the selected operation.")
    variables = payload.get("variables")
    if not isinstance(variables, dict):
        raise RequestError(400, "Missing post variables.")
    text = variables.get("tweet_text")
    if not isinstance(text, str) or not text.strip() or len(text) > 280:
        raise RequestError(400, "Post text must be between 1 and 280 characters.")
    payload["variables"]["reply"] = None
    payload["variables"]["media"] = {"media_entities": [], "possibly_sensitive": False}
    return json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def _send_to_x(config, profile, method, path, query, body):
    if requests is None:
        raise RequestError(503, "Install requests from sakura/requirements.txt.")
    try:
        transaction = _transaction_client(profile)
        transaction_id = transaction.generate_transaction_id(method=method, path=path)
    except RequestError:
        raise
    except Exception:
        raise RequestError(502, "Could not generate the X transaction header.")

    bearer = config["x_bearer_token"].strip()
    if not bearer.lower().startswith("bearer "):
        bearer = "Bearer " + bearer
    headers = {
        "Authorization": bearer,
        "User-Agent": profile["user_agent"],
        "Accept": "application/json, text/plain, */*",
        "Origin": APP_ORIGIN,
        "Referer": APP_ORIGIN + "/home",
        "Content-Type": "application/json",
        "x-csrf-token": profile["ct0"],
        "x-twitter-active-user": "yes",
        "x-twitter-auth-type": "OAuth2Session",
        "x-twitter-client-language": "ja",
        "x-client-transaction-id": transaction_id,
    }
    if profile.get("sec_ch_ua_platform"):
        headers["sec-ch-ua-platform"] = profile["sec_ch_ua_platform"]
    if profile.get("sec_ch_ua"):
        headers["sec-ch-ua"] = profile["sec_ch_ua"]

    session = requests.Session()
    session.headers.update(headers)
    session.cookies.set("auth_token", profile["auth_token"], domain=".x.com", path="/")
    session.cookies.set("ct0", profile["ct0"], domain=".x.com", path="/")
    url = APP_ORIGIN + path
    try:
        if method == "GET":
            response = session.get(url, params=query, timeout=(5, 40))
        else:
            response = session.post(url, params=query, data=body, timeout=(5, 40))
        return response.status_code, response.headers.get("Content-Type", "application/json; charset=utf-8"), response.content
    except requests.RequestException:
        raise RequestError(502, "The X API request failed.")
    finally:
        session.close()


def handle():
    method = os.environ.get("REQUEST_METHOD", "GET").upper()
    if method not in ("GET", "POST"):
        raise RequestError(405, "Only GET and POST are supported.")

    path, query = _route_and_query()
    if path == "/healthz" and method == "GET":
        _send(200, {"status": "ok"})
        return

    config = _load_config()
    if not _client_token_matches(config):
        raise RequestError(401, "Unauthorized.")

    if path == "/profiles" and method == "GET":
        _send(200, {"profiles": sorted(config["profiles"].keys())})
        return

    if path == "/i/api/graphql/" or not path.startswith("/i/api/graphql/"):
        raise RequestError(404, "Unknown API route.")

    _, profile = _select_profile(config)
    row = _catalog_record(method, path)
    if row is None:
        raise RequestError(404, "This GraphQL operation is not enabled.")
    allowed_query = ALLOWED_GRAPHQL_QUERY_KEYS
    if any(key not in allowed_query for key, _ in query):
        raise RequestError(400, "Unsupported GraphQL query parameter.")

    body = _read_body() if method == "POST" else b""
    if method == "POST":
        if path.rsplit("/", 1)[-1] != "CreateTweet":
            raise RequestError(405, "Only CreateTweet is enabled for POST.")
        query_id = path.split("/")[4]
        body = _validate_post(body, query_id)
    elif path.rsplit("/", 1)[-1] not in ("HomeTimeline", "SearchTimeline"):
        raise RequestError(405, "This operation is not enabled for GET.")

    status, content_type, response_body = _send_to_x(config, profile, method, path, query, body)
    _send(status, response_body, content_type)


if __name__ == "__main__":
    try:
        handle()
    except RequestError as error:
        _send(error.status, {"error": error.message})
    except Exception:
        _send(500, {"error": "Internal CGI error."})
