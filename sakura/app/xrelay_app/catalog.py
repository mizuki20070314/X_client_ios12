"""GraphQL operation catalog: query ids and feature flags (server-design section 3.5).

Sources, in order: a fresh cache file (younger than 24 h), a fresh download, the stale cache file, the bundled
data/ops.json. A failed download never fails a request. Every entry taken from a download or a file is validated;
an invalid entry is dropped and the next source is used for that operation.
"""

import json
import re
import time
from pathlib import Path

from xrelay_app import config as relay_config
from xrelay_app.errors import RelayError

API_URL = ("https://raw.githubusercontent.com/fa0311/TwitterInternalAPIDocument/"
           "develop/docs/json/API.json")
DOWNLOAD_TIMEOUT = (5, 15)
MAX_DOWNLOAD_BYTES = 8 * 1024 * 1024
CACHE_MAX_AGE = 24 * 60 * 60
FAILURE_BACKOFF = 60 * 60  # after a failed download, do not try again for an hour
QUERY_ID_RE = re.compile(r"[A-Za-z0-9_-]{10,40}")
BUNDLE_PATH = Path(__file__).resolve().parent / "data" / "ops.json"

# operation name -> HTTP method, exactly the operations of server-design section 4
OPERATIONS = {
    "HomeTimeline": "GET",
    "HomeLatestTimeline": "GET",
    "TweetDetail": "GET",
    "SearchTimeline": "GET",
    "UserByScreenName": "GET",
    "UserByRestId": "GET",
    "UserTweets": "GET",
    "UserTweetsAndReplies": "GET",
    "UserMedia": "GET",
    "Likes": "GET",
    "Following": "GET",
    "Followers": "GET",
    "NotificationsTimeline": "GET",
    "Bookmarks": "GET",
    "ExplorePage": "GET",
    "GenericTimelineById": "GET",
    "Viewer": "GET",
    "FavoriteTweet": "POST",
    "UnfavoriteTweet": "POST",
    "CreateRetweet": "POST",
    "DeleteRetweet": "POST",
    "CreateBookmark": "POST",
    "DeleteBookmark": "POST",
    "CreateTweet": "POST",
    "DeleteTweet": "POST",
}


def get_operation(name):
    """{"queryId": str, "method": "GET" or "POST", "features": dict}; RelayError(503) when no source has it."""
    if name not in OPERATIONS:
        raise RelayError(503, "unavailable", "内部の操作定義にない操作です。")
    now = _now()
    cache = _read_entries(_cache_path())
    if cache is not None and _is_fresh(cache, now) and name in cache["ops"]:
        return cache["ops"][name]

    # download only when the cache is not fresh: a fresh cache lacking the operation is not a reason to fetch
    if cache is None or not _is_fresh(cache, now):
        downloaded = _download_if_allowed(now)
        if downloaded is not None:
            merged = dict(cache["ops"]) if cache is not None else {}
            merged.update(downloaded)
            cache = {"fetched_at": int(now), "ops": merged}
            _write_cache(cache)
            if name in merged:
                return merged[name]

    if cache is not None and name in cache["ops"]:
        return cache["ops"][name]  # stale, but better than the bundle
    bundle = _read_entries(BUNDLE_PATH)
    if bundle is not None and name in bundle["ops"]:
        return bundle["ops"][name]
    raise RelayError(503, "unavailable", "XのAPI操作定義を読み込めませんでした。")


def reduce_document(document):
    """(valid entries, names that are missing or invalid) for the operations of section 4 of an API.json."""
    graphql = document.get("graphql") if isinstance(document, dict) else None
    if not isinstance(graphql, dict):
        graphql = {}
    entries = {}
    problems = []
    for name in OPERATIONS:
        entry = _valid_entry(name, graphql.get(name))
        if entry is None:
            problems.append(name)
        else:
            entries[name] = entry
    return entries, problems


def _valid_entry(name, entry):
    if not isinstance(entry, dict):
        return None
    query_id = entry.get("queryId")
    if not isinstance(query_id, str) or QUERY_ID_RE.fullmatch(query_id) is None:
        return None
    if entry.get("method") != OPERATIONS[name]:
        return None
    features = entry.get("features")
    if not isinstance(features, dict):
        return None
    if not all(isinstance(value, bool) for value in features.values()):
        return None
    return {"queryId": query_id, "method": OPERATIONS[name], "features": dict(features)}


def _read_entries(path):
    """{"fetched_at": number, "ops": {name: valid entry}} or None when the file is missing or malformed."""
    try:
        with Path(path).open("r", encoding="utf-8") as handle:
            document = json.load(handle)
    except (OSError, ValueError):
        return None
    if not isinstance(document, dict):
        return None
    fetched_at = document.get("fetched_at")
    ops = document.get("ops")
    if isinstance(fetched_at, bool) or not isinstance(fetched_at, (int, float)) or not isinstance(ops, dict):
        return None
    valid = {}
    for name in OPERATIONS:
        entry = _valid_entry(name, ops.get(name))
        if entry is not None:
            valid[name] = entry
    return {"fetched_at": fetched_at, "ops": valid}


def _is_fresh(cache, now):
    return 0 <= now - cache["fetched_at"] < CACHE_MAX_AGE


def _download_if_allowed(now):
    """Valid entries from a fresh download, or None when skipped (backoff) or failed."""
    failed_at = _read_failure()
    if failed_at is not None and 0 <= now - failed_at < FAILURE_BACKOFF:
        return None
    try:
        document = _download_document()
    except Exception:
        _write_failure(now)
        return None
    entries, _ = reduce_document(document)
    if not entries:
        _write_failure(now)
        return None
    return entries


def _download_document():
    """The public catalog as parsed JSON. Tests replace this function; nothing else talks to the network."""
    import requests  # only the cache refresh needs requests; a request without it still has the bundle
    response = requests.get(API_URL, timeout=DOWNLOAD_TIMEOUT)
    response.raise_for_status()
    content = response.content
    if len(content) > MAX_DOWNLOAD_BYTES:
        raise ValueError("operation catalog is too large")
    return json.loads(content.decode("utf-8"))


def _cache_dir():
    return relay_config.private_root() / "cache"


def _cache_path():
    return _cache_dir() / "ops.json"


def _failure_path():
    return _cache_dir() / "ops.failed"


def _read_failure():
    try:
        with _failure_path().open("r", encoding="utf-8") as handle:
            return float(handle.read().strip())
    except (OSError, ValueError):
        return None


def _write_failure(now):
    try:
        relay_config.ensure_private_dir(_cache_dir())
        relay_config.write_private(_failure_path(), str(int(now)).encode("ascii"))
    except OSError:
        pass


def _write_cache(cache):
    try:
        relay_config.ensure_private_dir(_cache_dir())
        data = json.dumps(cache, ensure_ascii=False, sort_keys=True).encode("utf-8")
        relay_config.write_private(_cache_path(), data)
    except OSError:
        pass  # the downloaded entries are still used for this request


def _now():
    return time.time()
