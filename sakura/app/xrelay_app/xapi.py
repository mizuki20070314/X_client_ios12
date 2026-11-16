"""XClient: authenticated calls to X's web API, and the answer table of server-design section 3.6.

raw() is the only place that builds headers, cookies and the transaction id, so the v1 pass-through and the v2
routes share it. It repeats a call at most twice: once after an empty 404 (with the transaction keys invalidated),
once after a 353 that came with a rotated ct0.
"""

import json
import time
from collections import namedtuple
from urllib.parse import urlencode

from xrelay_app import catalog
from xrelay_app import config as relay_config
from xrelay_app import transaction
from xrelay_app.errors import RelayError

try:
    import requests
except ImportError:  # only real calls need requests; tests inject a session class
    requests = None

ORIGIN = "https://x.com"
TIMEOUT = (5, 40)
# the request header as the v1 CGI and server-design section 3.6 send it; the answer default is with charset
REQUEST_JSON = "application/json"
ANSWER_JSON = "application/json; charset=utf-8"
FORM_TYPE = "application/x-www-form-urlencoded"
RATE_LIMIT_CODE = 88
CSRF_CODE = 353
AUTH_CODES = frozenset([32, 64, 89, 215, 326, 353])
NOT_FOUND_CODES = frozenset([34, 50, 63, 144, 421, 422])

MSG_NETWORK = "Xに接続できませんでした。"
MSG_RATE = "Xのレート制限に達しました。しばらく待ってから再度お試しください。"
MSG_AUTH = "Xのログイン情報が無効です。サーバーで setup_config.py を実行して更新してください。"
MSG_NOT_FOUND = "Xでデータが見つかりませんでした。"
MSG_X_ERROR = "Xからエラーが返されました。"
MSG_BAD_ANSWER = "Xの応答を読み取れませんでした。"
MSG_NO_REQUESTS = "依存パッケージが足りません。sakura/requirements.txt の内容をインストールしてください。"

_Answer = namedtuple("_Answer", "status content_type content headers ct0")


class XClient(object):
    def __init__(self, config, profile_name, profile, session_factory=None):
        self.config = config
        self.profile_name = profile_name
        self.profile = profile
        if session_factory is None and requests is not None:
            session_factory = requests.Session
        self._session_factory = session_factory
        self._ct0 = profile["ct0"]  # replaced when X rotates it during this request
        self._bearer = _bearer_header(config.get("x_bearer_token"))

    def graphql(self, name, variables, field_toggles=None):
        """The whole answer (a dict) of one GraphQL operation; RelayError for failures."""
        operation = catalog.get_operation(name)
        query_id = operation["queryId"]
        path = "/i/api/graphql/{}/{}".format(query_id, name)
        features = operation["features"]
        if operation["method"] == "GET":
            params = [("variables", _compact(variables))]
            if features:
                params.append(("features", _compact(features)))
            if field_toggles is not None:
                params.append(("fieldToggles", _compact(field_toggles)))
            return _interpret(self._call("GET", path, params, None, REQUEST_JSON))
        payload = {"variables": variables, "queryId": query_id}
        if features:
            payload["features"] = features
        if field_toggles is not None:
            payload["fieldToggles"] = field_toggles
        return _interpret(self._call("POST", path, None, _compact(payload).encode("utf-8"), REQUEST_JSON))

    def rest(self, method, path, params=None, form=None, json_body=None):
        """The parsed JSON of one REST call. path is like /i/api/1.1/...; form and json_body are alternatives."""
        body = None
        content_type = REQUEST_JSON
        if form is not None:
            pairs = list(form.items()) if isinstance(form, dict) else list(form)
            body = urlencode(pairs).encode("utf-8")
            content_type = FORM_TYPE
        elif json_body is not None:
            body = _compact(json_body).encode("utf-8")
        return _interpret(self._call(method.upper(), path, params, body, content_type))

    def raw(self, method, path, params=None, body=None, content_type=REQUEST_JSON):
        """One call without interpreting X's answer: (status code, content type, body bytes), as X sent them."""
        answer = self._call(method.upper(), path, params, body, content_type)
        return answer.status, answer.content_type, answer.content

    def _call(self, method, path, params, body, content_type):
        session = self._new_session()
        try:
            retried_missing = False  # an empty 404 is retried once, with new transaction keys
            retried_csrf = False     # a 353 with a rotated ct0 is retried once
            while True:
                answer = self._send(session, method, path, params, body, content_type)
                rotated = self._adopt_ct0(answer.ct0)
                if answer.status == 404 and not answer.content.strip() and not retried_missing:
                    transaction.invalidate(self.profile)
                    retried_missing = True
                    continue
                if rotated and not retried_csrf and _first_code(_json_object(answer.content)) == CSRF_CODE:
                    retried_csrf = True
                    continue
                return answer
        finally:
            _close(session)

    def _send(self, session, method, path, params, body, content_type):
        # built before the try: a transaction-id failure is a RelayError, not a network error
        headers = self._headers(method, path, content_type)
        cookies = {"auth_token": self.profile["auth_token"], "ct0": self._ct0}
        url = ORIGIN + path
        try:
            if method == "GET":
                response = session.get(url, params=params, headers=headers, cookies=cookies, timeout=TIMEOUT)
            else:
                response = session.post(url, params=params, data=body, headers=headers, cookies=cookies,
                                        timeout=TIMEOUT)
            status = int(response.status_code)
            content = response.content
            lower = _lower_headers(getattr(response, "headers", None))
            ct0 = _cookie_value(response, "ct0")
        except Exception:
            # connection errors and timeouts (requests' exceptions and anything the transport raises)
            raise RelayError(502, "x_error", MSG_NETWORK)
        return _Answer(status, lower.get("content-type") or ANSWER_JSON, content, lower, ct0)

    def _headers(self, method, path, content_type):
        headers = {
            "Authorization": self._bearer,
            "User-Agent": self.profile["user_agent"],
            "Accept": "application/json, text/plain, */*",
            "Origin": ORIGIN,
            "Referer": ORIGIN + "/home",
            "Content-Type": content_type,
            "x-csrf-token": self._ct0,
            "x-twitter-active-user": "yes",
            "x-twitter-auth-type": "OAuth2Session",
            "x-twitter-client-language": "ja",
            "x-client-transaction-id": transaction.get_transaction_id(self.profile, method, path),
        }
        if self.profile.get("sec_ch_ua_platform"):
            headers["sec-ch-ua-platform"] = self.profile["sec_ch_ua_platform"]
        if self.profile.get("sec_ch_ua"):
            headers["sec-ch-ua"] = self.profile["sec_ch_ua"]
        return headers

    def _adopt_ct0(self, value):
        if not value or value == self._ct0:
            return False
        self._ct0 = value
        self.profile["ct0"] = value
        try:
            relay_config.update_profile_ct0(self.profile_name, value)
        except Exception:
            pass  # the request goes on with the new value even if the config file cannot be written
        return True

    def _new_session(self):
        if self._session_factory is None:
            raise RelayError(503, "unavailable", MSG_NO_REQUESTS)
        return self._session_factory()


def _interpret(answer):
    """The parsed JSON of an answer, or the RelayError of the table in server-design section 3.6."""
    payload = _json_object(answer.content)
    code = _first_code(payload)
    if 200 <= answer.status < 300:
        if payload is None:
            raise RelayError(502, "x_error", MSG_BAD_ANSWER)
        # errors next to usable data are a success: a sub-object failed, the rest is still there
        if not payload.get("errors") or _has_data(payload):
            return payload
    if answer.status == 429 or code == RATE_LIMIT_CODE:
        raise RelayError(429, "rate_limited", MSG_RATE, x_code=RATE_LIMIT_CODE,
                         retry_after=_retry_after(answer.headers))
    if answer.status in (401, 403) or code in AUTH_CODES:
        raise RelayError(403, "x_auth", MSG_AUTH, x_code=code)
    if code in NOT_FOUND_CODES:
        raise RelayError(404, "not_found", MSG_NOT_FOUND, x_code=code)
    raise RelayError(502, "x_error", _x_message(payload) or MSG_X_ERROR, x_code=code)


def _has_data(payload):
    # "data" missing, null, {} or all-null values count as no data
    data = payload.get("data")
    return isinstance(data, dict) and any(value is not None for value in data.values())


def _error_entries(payload):
    if not isinstance(payload, dict):
        return []
    errors = payload.get("errors")
    if not isinstance(errors, list):
        return []
    return [entry for entry in errors if isinstance(entry, dict)]


def _first_code(payload):
    for entry in _error_entries(payload):
        code = entry.get("code")
        if isinstance(code, int) and not isinstance(code, bool):
            return code
    return None


def _x_message(payload):
    for entry in _error_entries(payload):
        message = entry.get("message")
        if isinstance(message, str) and message.strip():
            return " ".join(message.split())[:200]  # X's text for the user, without control characters
    return None


def _json_object(content):
    try:
        text = content.decode("utf-8") if isinstance(content, bytes) else content
        payload = json.loads(text)
    except (AttributeError, TypeError, UnicodeDecodeError, ValueError):
        return None
    return payload if isinstance(payload, dict) else None


def _retry_after(headers):
    try:
        reset = int(headers.get("x-rate-limit-reset"))
    except (TypeError, ValueError):
        return None
    return max(0, reset - int(_now()))


def _now():
    return time.time()


def _cookie_value(response, name):
    jar = getattr(response, "cookies", None)
    if not jar:
        return None
    try:
        value = jar.get(name)
    except Exception:
        return None  # two cookies of that name in different domains: take none
    return value if isinstance(value, str) and value else None


def _lower_headers(headers):
    return {str(key).lower(): value for key, value in (headers or {}).items()}


def _bearer_header(value):
    token = (value or "").strip()
    if token and not token.lower().startswith("bearer "):
        token = "Bearer " + token
    return token


def _compact(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def _close(session):
    try:
        session.close()
    except Exception:
        pass
