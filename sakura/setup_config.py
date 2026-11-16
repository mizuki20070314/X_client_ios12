#!/usr/local/bin/python
# -*- coding: utf-8 -*-
"""Create/update X session configuration outside Sakura's document root."""

from __future__ import print_function

import argparse
import getpass
import hashlib
import json
import os
import secrets
import tempfile
from pathlib import Path
from urllib.request import urlopen


API_HEADERS_URL = "https://raw.githubusercontent.com/fa0311/TwitterInternalAPIDocument/develop/docs/json/API.json"


def read_existing(path):
    try:
        with path.open("r", encoding="utf-8") as handle:
            return json.load(handle)
    except (IOError, ValueError):
        return {}


def write_private(path, payload):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(str(path.parent), 0o700)
    descriptor, temporary = tempfile.mkstemp(prefix="config-", dir=str(path.parent))
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        os.replace(temporary, str(path))
        os.chmod(str(path), 0o600)
    finally:
        try:
            if os.path.exists(temporary):
                os.unlink(temporary)
        except OSError:
            pass


def prompt_secret(label, existing=""):
    suffix = "（空欄なら既存値を維持）" if existing else ""
    value = getpass.getpass(label + suffix + ": ").strip()
    return value or existing


def fetch_public_headers():
    try:
        with urlopen(API_HEADERS_URL, timeout=20) as response:
            document = json.loads(response.read().decode("utf-8"))
        headers = document.get("header", {})
        return headers if isinstance(headers, dict) else {}
    except Exception:
        return {}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--rotate-client-key", action="store_true", help="iOS側のCGIキーも再発行する")
    args = parser.parse_args()

    config_path = Path.home() / "private" / "xrelay" / "config.json"
    config = read_existing(config_path)
    profiles = config.get("profiles", {})
    if not isinstance(profiles, dict):
        profiles = {}
    public_headers = fetch_public_headers()

    name = input("プロフィール名 [account1]: ").strip() or "account1"
    old_profile = profiles.get(name, {})
    if not isinstance(old_profile, dict):
        old_profile = {}

    print("\nXのログイン情報はチャットや公開リポジトリに貼らないでください。")
    auth_token = prompt_secret("X Cookie auth_token", old_profile.get("auth_token", ""))
    ct0 = prompt_secret("X Cookie ct0", old_profile.get("ct0", ""))
    bearer_default = config.get("x_bearer_token") or public_headers.get("authorization", "")
    x_bearer = prompt_secret(
        "X web-app Authorization token（空欄なら公開APIカタログの既定値）",
        bearer_default,
    )

    user_agent_default = old_profile.get("user_agent") or public_headers.get("user-agent", "")
    user_agent = input("Cookie取得時のブラウザーUser-Agent [{}]: ".format(user_agent_default)).strip()
    user_agent = user_agent or user_agent_default
    platform_default = old_profile.get("sec_ch_ua_platform") or public_headers.get("sec-ch-ua-platform", '"Windows"')
    platform = input("sec-ch-ua-platform [{}]: ".format(platform_default)).strip()
    if platform:
        platform = '"{}"'.format(platform.strip('"'))
    else:
        platform = platform_default
    sec_ch_ua_default = old_profile.get("sec_ch_ua") or public_headers.get("sec-ch-ua", "")
    sec_ch_ua = input("sec-ch-ua（空欄なら既定値）: ").strip() or sec_ch_ua_default

    if not auth_token or not ct0 or not x_bearer or not user_agent:
        raise SystemExit("auth_token、ct0、Bearer token、User-Agentは必須です。設定は保存されませんでした。")

    profiles[name] = {
        "auth_token": auth_token,
        "ct0": ct0,
        "user_agent": user_agent,
        "sec_ch_ua_platform": platform,
        "sec_ch_ua": sec_ch_ua,
    }
    config["profiles"] = profiles
    config["default_profile"] = config.get("default_profile") or name
    config["x_bearer_token"] = x_bearer

    client_key = None
    if not config.get("client_token_sha256") or args.rotate_client_key:
        client_key = secrets.token_urlsafe(32)
        config["client_token_sha256"] = hashlib.sha256(client_key.encode("utf-8")).hexdigest()

    write_private(config_path, config)
    print("Saved private configuration: {}".format(config_path))
    if client_key:
        print("\nCGI key — enter this once in the iOS app's Bearer-token setting:\n{}".format(client_key))
        print("Keep it private; it is not stored in plaintext on the server.")
    else:
        print("Existing iOS CGI key was preserved.")


if __name__ == "__main__":
    main()
