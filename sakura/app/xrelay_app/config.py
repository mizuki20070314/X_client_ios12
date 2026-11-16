"""Private paths, the config file, profile selection and the CGI key check.

Secrets (X cookies, bearer token, hash of the CGI key) live in the config file outside the document root.
Nothing in this module prints, logs or puts them into an error message.
"""

import hashlib
import hmac
import json
import os
import re
import stat
import tempfile
from pathlib import Path

from xrelay_app.errors import RelayError

KEY_HASH_RE = re.compile(r"[0-9a-f]{64}")
BEARER_RE = re.compile(r"Bearer\s+(.+)\Z", re.IGNORECASE)


def private_root():
    """XRELAY_HOME when set (tests use a temp directory), else ~/private/xrelay."""
    override = os.environ.get("XRELAY_HOME")
    if override:
        return Path(override).expanduser()
    return Path.home() / "private" / "xrelay"


def config_path():
    override = os.environ.get("XRELAY_CONFIG")
    if override:
        return Path(override).expanduser()
    return private_root() / "config.json"


def _unavailable(message):
    return RelayError(503, "unavailable", message)


def load_config():
    path = config_path()
    try:
        # group/world readable secrets are refused; Windows has no such mode bits
        if os.name != "nt" and stat.S_IMODE(path.stat().st_mode) & 0o077:
            raise _unavailable("非公開設定ファイルの権限は600にしてください。")
        with path.open("r", encoding="utf-8") as handle:
            config = json.load(handle)
    except RelayError:
        raise
    except (OSError, ValueError):
        raise _unavailable("CGIの非公開設定ファイルを読み込めません。")

    if not isinstance(config, dict):
        raise _unavailable("CGIの非公開設定ファイルの形式が正しくありません。")
    key_hash = config.get("client_token_sha256")
    if not isinstance(key_hash, str) or KEY_HASH_RE.fullmatch(key_hash) is None:
        raise _unavailable("CGIクライアントキーが設定されていません。")
    bearer = config.get("x_bearer_token")
    if not isinstance(bearer, str) or not bearer.strip():
        raise _unavailable("XのBearerトークンが設定されていません。")
    profiles = config.get("profiles")
    if not isinstance(profiles, dict) or not profiles:
        raise _unavailable("Xのプロフィール設定がありません。")
    return config


def select_profile(config, name):
    """(name, profile). An empty name means the default profile."""
    if not name:
        name = config.get("default_profile")
    profiles = config.get("profiles")
    profile = profiles.get(name) if isinstance(name, str) and isinstance(profiles, dict) else None
    if not isinstance(profile, dict):
        raise RelayError(400, "bad_request", "指定されたプロフィール名は設定されていません。")
    for field in ("auth_token", "ct0"):
        if not isinstance(profile.get(field), str) or not profile.get(field):
            raise _unavailable("選択したXセッションの設定が不完全です。")
    user_agent = profile.get("user_agent")
    if not isinstance(user_agent, str) or not user_agent:
        raise _unavailable("選択したプロフィールにUser-Agentがありません。")
    return name, profile


def client_key_matches(config, environ):
    """True when the CGI key (X-Relay-Key, else Authorization: Bearer) hashes to the configured value."""
    supplied = (environ.get("HTTP_X_RELAY_KEY") or "").strip()
    if not supplied:
        authorization = environ.get("HTTP_AUTHORIZATION") or environ.get("REDIRECT_HTTP_AUTHORIZATION") or ""
        match = BEARER_RE.match(authorization.strip())
        supplied = match.group(1).strip() if match else ""
    if not supplied:
        return False
    expected = config.get("client_token_sha256")
    if not isinstance(expected, str):
        return False
    digest = hashlib.sha256(supplied.encode("utf-8", "replace")).hexdigest()
    return hmac.compare_digest(digest, expected)


def ensure_private_dir(path):
    """Create a directory (and missing parents) with mode 700 on the leaf."""
    path = Path(path)
    path.mkdir(parents=True, exist_ok=True)
    if os.name != "nt":
        os.chmod(str(path), 0o700)


def write_private(path, data):
    """Atomically replace path with the bytes data, mode 600 (temp file in the same directory + os.replace)."""
    if not isinstance(data, bytes):
        raise TypeError("write_private takes bytes")
    path = Path(path)
    descriptor, temporary = tempfile.mkstemp(prefix=path.name + ".", suffix=".tmp", dir=str(path.parent))
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, str(path))
    except BaseException:
        try:
            if os.path.exists(temporary):
                os.unlink(temporary)
        except OSError:
            pass
        raise


def update_profile_ct0(profile_name, ct0):
    """Store a rotated ct0 in the config file. True when the profile exists; OSError/ValueError propagate."""
    path = config_path()
    with path.open("r", encoding="utf-8") as handle:
        config = json.load(handle)
    profiles = config.get("profiles") if isinstance(config, dict) else None
    profile = profiles.get(profile_name) if isinstance(profiles, dict) else None
    if not isinstance(profile, dict):
        return False
    profile["ct0"] = ct0
    write_private(path, (json.dumps(config, ensure_ascii=False, indent=2) + "\n").encode("utf-8"))
    return True
