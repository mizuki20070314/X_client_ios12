"""x-client-transaction-id, the header X checks strictly on some operations (search, user tweets and replies).

generate_transaction_id is pure. The key material (key, animation_key) comes from X's web app and is cached per
user agent under private_root()/tid-cache/<fingerprint>/keys.json. bs4 and x_client_transaction are needed only
by _refresh_keys, so an ordinary request never imports them.
"""

import base64
import contextlib
import hashlib
import json
import math
import os
import random
import re
import time
from urllib.parse import urljoin, urlsplit

from xrelay_app import config as relay_config
from xrelay_app.errors import RelayError

try:
    import fcntl
except ImportError:  # Windows: no flock; the cache is refreshed without a lock there
    fcntl = None

EPOCH_OFFSET = 1682924400  # 2023-05-01T07:00:00Z; the 4-byte time field counts from here
KEYS_MAX_AGE = 6 * 60 * 60
ORIGIN = "https://x.com"
PAGE_JF_URL = "https://x.com/i/jf/"
PAGE_HOME_URL = "https://x.com/home"
SCRIPT_LIST_URL = ("https://raw.githubusercontent.com/fa0311/TwitterInternalAPIDocument/"
                   "develop/docs/json/ScriptLoadJson.json")
SCRIPT_HOST = "abs.twimg.com"
SCRIPT_PREFIX = "/responsive-web/client-web/ondemand.s."
# The chunk id of "ondemand.s" sits in a webpack-style table; group 2 is the hash.
ONDEMAND_RE = re.compile(
    r"""(\d+):\s*["']ondemand\.s["'][\s\S]*?\}\)\[e\]\s*\|\|\s*e\)\s*\+\s*["']\.["']\s*\+\s*\(\{[\s\S]*?\b\1:\s*["']([a-zA-Z0-9_-]+)["']"""
)


def _now():
    return time.time()


def _decode_key(value):
    # keys may come without "=" padding; ValueError for anything that is not base64
    return base64.b64decode(value + "=" * (-len(value) % 4), validate=True)


def _is_key(value):
    if not isinstance(value, str) or not value:
        return False
    try:
        _decode_key(value)
    except ValueError:
        return False
    return True


def _is_material(material):
    return (isinstance(material, dict) and _is_key(material.get("key"))
            and isinstance(material.get("animation_key"), str) and bool(material.get("animation_key")))


def generate_transaction_id(method, path, key, animation_key, now=None, rand=None):
    """The header value for one request. path is the URL path only, without the query string."""
    if now is None:
        now = _now()
    time_now = int(math.floor(now)) - EPOCH_OFFSET
    key_bytes = _decode_key(key)
    text = "{}!{}!{}obfiowerehiring{}".format(method, path, time_now, animation_key)
    digest = hashlib.sha256(text.encode("utf-8")).digest()
    payload = key_bytes + time_now.to_bytes(4, "little") + digest[:16] + bytes([3])
    if rand is None:
        rand = random.randint(0, 255)
    out = bytes([rand]) + bytes(byte ^ rand for byte in payload)
    return base64.b64encode(out).decode("ascii").rstrip("=")


def get_transaction_id(profile, method, path):
    """The header value for one request, using the cached key material (refreshed when stale)."""
    keys = _current_keys(profile)
    try:
        return generate_transaction_id(method, path, keys["key"], keys["animation_key"])
    except (ValueError, OverflowError):
        raise RelayError(502, "x_error", "Xのトランザクションを作成できませんでした。")


def invalidate(profile):
    """Mark the cached keys stale so that the next call refreshes them (old keys stay as a fallback)."""
    directory = _directory_path(profile)
    try:
        if not directory.is_dir():
            return
        with _locked(directory):
            cached = _read_keys(directory)
            if cached is None:
                return
            cached["fetched_at"] = 0
            _write_keys(directory, cached)
    except Exception:
        # a failed invalidation only costs one extra refresh on the next call
        return


def _fingerprint(profile):
    text = profile["user_agent"] + (profile.get("sec_ch_ua_platform") or "")
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:16]


def _directory_path(profile):
    return relay_config.private_root() / "tid-cache" / _fingerprint(profile)


def _ensure_directory(profile):
    base = relay_config.private_root() / "tid-cache"
    relay_config.ensure_private_dir(base)
    directory = base / _fingerprint(profile)
    relay_config.ensure_private_dir(directory)
    return directory


@contextlib.contextmanager
def _locked(directory):
    # without a lock file the refresh still runs; the lock only avoids duplicate refreshes
    descriptor = None
    if fcntl is not None:
        try:
            descriptor = os.open(str(directory / "tid.lock"), os.O_RDWR | os.O_CREAT, 0o600)
            fcntl.flock(descriptor, fcntl.LOCK_EX)
        except OSError:
            if descriptor is not None:
                os.close(descriptor)
            descriptor = None
    try:
        yield
    finally:
        if descriptor is not None:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
            os.close(descriptor)


def _read_keys(directory):
    try:
        with (directory / "keys.json").open("r", encoding="utf-8") as handle:
            entry = json.load(handle)
    except (OSError, ValueError):
        return None
    if not isinstance(entry, dict):
        return None
    fetched_at = entry.get("fetched_at")
    if isinstance(fetched_at, bool) or not isinstance(fetched_at, (int, float)):
        return None
    if not _is_key(entry.get("key")):
        return None
    animation_key = entry.get("animation_key")
    if not isinstance(animation_key, str) or not animation_key:
        return None
    source = entry.get("source")
    return {"key": entry["key"], "animation_key": animation_key, "fetched_at": fetched_at,
            "source": source if isinstance(source, str) else ""}


def _write_keys(directory, entry):
    relay_config.write_private(directory / "keys.json", json.dumps(entry, sort_keys=True).encode("utf-8"))


def _is_fresh(entry, now):
    # a timestamp in the future (clock moved back) is not trusted as fresh
    return 0 <= now - entry["fetched_at"] < KEYS_MAX_AGE


def _current_keys(profile):
    try:
        directory = _ensure_directory(profile)
    except OSError:
        raise RelayError(503, "unavailable", "非公開フォルダーを作れません。サーバーの権限を確認してください。")
    cached = _read_keys(directory)
    if cached is not None and _is_fresh(cached, _now()):
        return cached
    with _locked(directory):
        # another request may have refreshed the keys while this one waited for the lock
        cached = _read_keys(directory)
        if cached is not None and _is_fresh(cached, _now()):
            return cached
        try:
            material = _refresh_keys(profile)
            if not _is_material(material):
                raise ValueError("refresh returned unusable key material")
        except RelayError:
            # e.g. a missing dependency: an old copy still works, otherwise the error stands
            if cached is not None:
                return cached
            raise
        except Exception:
            if cached is not None:
                return cached
            raise RelayError(502, "x_error", "Xの認証素材を取得できませんでした。")
        entry = dict(material)
        entry["fetched_at"] = int(_now())
        try:
            _write_keys(directory, entry)
        except OSError:
            pass  # the keys are still good for this request
        return entry


def find_script_url(html):
    """The ondemand.s script URL named in X's HTML, or None (invented snippets are tested, real pages are not)."""
    match = ONDEMAND_RE.search(html)
    if match is None:
        return None
    return "https://{}{}{}a.js".format(SCRIPT_HOST, SCRIPT_PREFIX, match.group(2))


def is_valid_script_url(url):
    if not isinstance(url, str):
        return False
    try:
        parts = urlsplit(url)
    except ValueError:
        return False
    return (parts.scheme == "https" and parts.netloc == SCRIPT_HOST
            and parts.path.startswith(SCRIPT_PREFIX) and parts.path.endswith(".js")
            and not parts.query and not parts.fragment)


def _login_cookies(profile):
    return {"auth_token": profile["auth_token"], "ct0": profile["ct0"]}


def _page_headers(profile):
    headers = {
        "User-Agent": profile["user_agent"],
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8",
        "Accept-Language": "ja,en;q=0.9",
        "Cache-Control": "no-cache",
        "Sec-Fetch-Dest": "document",
        "Sec-Fetch-Mode": "navigate",
        "Sec-Fetch-Site": "none",
        "Sec-Fetch-User": "?1",
        "Upgrade-Insecure-Requests": "1",
    }
    _add_client_hints(headers, profile)
    return headers


def _script_headers(profile):
    headers = {"User-Agent": profile["user_agent"], "Accept": "*/*", "Referer": PAGE_HOME_URL}
    _add_client_hints(headers, profile)
    return headers


def _add_client_hints(headers, profile):
    if profile.get("sec_ch_ua_platform"):
        headers["sec-ch-ua-platform"] = profile["sec_ch_ua_platform"]
    if profile.get("sec_ch_ua"):
        headers["sec-ch-ua"] = profile["sec_ch_ua"]


def _fallback_script_url(session, soup, ondemand_lookup):
    # Fallback 1: the helper of x_client_transaction; fallback 2: the public catalog of script names
    candidate = None
    try:
        candidate = ondemand_lookup(response=soup)
    except Exception:
        candidate = None
    if not isinstance(candidate, str) or not candidate:
        try:
            response = session.get(SCRIPT_LIST_URL, timeout=(5, 20))
            response.raise_for_status()
            candidate = json.loads(response.text).get("ondemand.s")
        except Exception:
            candidate = None
    if not isinstance(candidate, str) or not candidate:
        return None
    return urljoin(ORIGIN + "/", candidate)


def _fetch_keys(session, profile, page_url, cookies, soup_class, client_class, ondemand_lookup):
    response = session.get(page_url, headers=_page_headers(profile), cookies=cookies, timeout=(5, 25))
    response.raise_for_status()
    html = response.text
    soup = soup_class(html, "html.parser")
    script_url = find_script_url(html)
    if script_url is None:
        script_url = _fallback_script_url(session, soup, ondemand_lookup)
    if not is_valid_script_url(script_url):
        raise ValueError("unexpected transaction script url")
    script = session.get(script_url, headers=_script_headers(profile), timeout=(5, 25))
    script.raise_for_status()
    client = client_class(home_page_response=soup, ondemand_file_response=script.text)
    key = client.key
    animation_key = client.animation_key
    if not _is_key(key) or not isinstance(animation_key, str) or not animation_key:
        raise ValueError("unexpected key material")
    return {"key": key, "animation_key": animation_key, "source": page_url}


def _refresh_keys(profile):
    """Fetch the key material from X. The only function that needs the network and bs4/x_client_transaction.

    Tests replace this function. Plan 1 reads the public page without cookies; plan 2 (fallback) reads the
    home page with the session cookies.
    """
    try:
        import requests
        from bs4 import BeautifulSoup
        from x_client_transaction import ClientTransaction
        from x_client_transaction.utils import get_ondemand_file_url
    except ImportError:
        raise RelayError(503, "unavailable",
                         "依存パッケージが足りません。sakura/requirements.txt の内容をインストールしてください。")
    plans = [(PAGE_JF_URL, None), (PAGE_HOME_URL, _login_cookies(profile))]
    session = requests.Session()
    try:
        for page_url, cookies in plans:
            try:
                return _fetch_keys(session, profile, page_url, cookies,
                                   BeautifulSoup, ClientTransaction, get_ondemand_file_url)
            except Exception:
                continue  # try the next plan; its failure is reported below
        raise RelayError(502, "x_error", "Xの認証素材を取得できませんでした。")
    finally:
        session.close()
