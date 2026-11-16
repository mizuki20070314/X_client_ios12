"""The v1 pass-through: GET HomeTimeline and SearchTimeline, POST CreateTweet, under /i/api/graphql/.

Requests are validated against www/requests.ndjson exactly as the v1 xrelay.cgi did. The messages below are the
v1 texts on purpose: the installed app shows them as "HTTP <code>: <text>". X's answer goes back unchanged.
"""

import json
import re
from pathlib import Path

from xrelay_app.errors import RelayError

ALLOWED_OPERATIONS = {("GET", "HomeTimeline"), ("GET", "SearchTimeline"), ("POST", "CreateTweet")}
ALLOWED_GRAPHQL_QUERY_KEYS = {"variables", "features", "fieldToggles"}
ALLOWED_POST_BODY_KEYS = {"queryId", "variables", "features", "fieldToggles"}
CATALOG_FILE = "requests.ndjson"
NUMERIC_ID_RE = re.compile(r"[0-9]{1,30}")


def dispatch(request, client, www_root=None):
    """(status, content type, body bytes) of X's answer. RelayError for requests the v1 CGI refused."""
    if catalog_record(request.method, request.path, www_root) is None:
        raise RelayError(404, "not_found", "This GraphQL operation is not enabled.")
    if any(key not in ALLOWED_GRAPHQL_QUERY_KEYS for key, _ in request.query):
        raise RelayError(400, "bad_request", "Unsupported GraphQL query parameter.")
    operation = request.path.rsplit("/", 1)[-1]
    if request.method == "POST":
        if operation != "CreateTweet":
            raise RelayError(405, "bad_request", "Only CreateTweet is enabled for POST.")
        body = validate_post(request.body, request.path.split("/")[4])
    else:
        if operation not in ("HomeTimeline", "SearchTimeline"):
            raise RelayError(405, "bad_request", "This operation is not enabled for GET.")
        body = None
    return client.raw(request.method, request.path, params=request.query, body=body)


def catalog_record(method, full_path, www_root=None):
    """The requests.ndjson row for this method and path, or None."""
    if not full_path.startswith("/i/api/"):
        return None
    catalog_path = full_path[len("/i/api"):]
    operation = catalog_path.rsplit("/", 1)[-1]
    if (method, operation) not in ALLOWED_OPERATIONS:
        return None
    for row in load_catalog(www_root):
        if row.get("method") == method and row.get("path") == catalog_path:
            return row
    return None


def load_catalog(www_root):
    if www_root is None:
        raise RelayError(503, "unavailable", "旧版のリクエストカタログが設定されていません。")
    rows = []
    try:
        with (Path(www_root) / CATALOG_FILE).open("r", encoding="utf-8") as handle:
            for line in handle:
                if line.strip():
                    rows.append(json.loads(line))
    except (OSError, ValueError):
        raise RelayError(503, "unavailable", "旧版のリクエストカタログを読み込めません。")
    return [row for row in rows if isinstance(row, dict)]


def validate_post(body, expected_query_id):
    """The CreateTweet body, normalised as v1 did (reply and media fields rebuilt). Bytes out."""
    try:
        payload = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        raise RelayError(400, "bad_request", "Expected a JSON request body.")
    if not isinstance(payload, dict) or set(payload) - ALLOWED_POST_BODY_KEYS:
        raise RelayError(400, "bad_request", "Unsupported post payload.")
    if payload.get("queryId") != expected_query_id:
        raise RelayError(400, "bad_request", "GraphQL query ID does not match the selected operation.")
    variables = payload.get("variables")
    if not isinstance(variables, dict):
        raise RelayError(400, "bad_request", "Missing post variables.")
    text = variables.get("tweet_text")
    if not isinstance(text, str) or not text.strip() or len(text) > 280:
        raise RelayError(400, "bad_request", "Post text must be between 1 and 280 characters.")

    reply = variables.get("reply")
    if reply is None:
        variables["reply"] = None
    elif isinstance(reply, dict):
        reply_id = reply.get("in_reply_to_tweet_id")
        excluded_ids = reply.get("exclude_reply_user_ids", [])
        if not isinstance(reply_id, str) or NUMERIC_ID_RE.fullmatch(reply_id) is None:
            raise RelayError(400, "bad_request", "Reply target must be a numeric post ID.")
        if (not isinstance(excluded_ids, list) or len(excluded_ids) > 50
                or any(not isinstance(item, str) or NUMERIC_ID_RE.fullmatch(item) is None
                       for item in excluded_ids)):
            raise RelayError(400, "bad_request", "Reply exclusions are invalid.")
        variables["reply"] = {"in_reply_to_tweet_id": reply_id, "exclude_reply_user_ids": excluded_ids}
    else:
        raise RelayError(400, "bad_request", "Reply payload is invalid.")
    variables["media"] = {"media_entities": [], "possibly_sensitive": False}
    return json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
