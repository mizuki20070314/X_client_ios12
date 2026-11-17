# Server design (`sakura/`)

The server is a Python CGI on a shared rental server (Sakura, FreeBSD, Apache, **Python 3.8.12**). Every HTTP request
starts a new process. It calls X's web API with the account owner's own session cookies and answers with the JSON of
[`api-v2.md`](api-v2.md).

## 1. Constraints

- **Python 3.8 syntax and standard library only.** No `match`, no `X | Y` type unions, no `list[str]` generics in
  annotations that are evaluated, no `str.removeprefix/removesuffix`, no `zoneinfo`, no dict `|`, no parenthesised
  context managers, no `int.bit_count`. Developers run tests with a newer Python locally, so this needs care.
- Third-party packages (installed outside the document root, see `requirements.txt`): `requests`, `urllib3<2`,
  `beautifulsoup4`, `xclienttransaction`. `bs4` and `x_client_transaction` are needed **only** when the
  transaction-id key material is refreshed (a few times a day): import them lazily inside that function. A normal
  request imports `requests` and the standard library only. Tests must run on a machine that has `requests` but not
  `bs4` / `x_client_transaction`.
- Secrets (X cookies, bearer token, hash of the CGI key) live in `~/private/xrelay/config.json` (mode 600), outside
  the document root. Nothing secret is ever printed, logged, put into an error message or written under `www/`.
- The public repository must never contain real account data: fixtures are hand-made.

## 2. Files

```
sakura/
  README.md                 how to install / update (Japanese)
  requirements.txt
  setup_config.py           interactive: writes ~/private/xrelay/config.json           (exists, unchanged)
  deploy.sh                 run on the server after `git pull`: tests, then installs app + www files
  app/xrelay_app/           the application package; installed to ~/private/xrelay/app/xrelay_app/
    __init__.py
    errors.py               RelayError
    config.py               private paths, config file, profile, CGI key check
    cgiio.py                CGI request parsing / response writing (gzip)
    transaction.py          x-client-transaction-id
    catalog.py              GraphQL operation catalog (query ids, feature flags)
    xapi.py                 XClient: authenticated calls to X, error mapping
    normalize.py            X JSON -> api-v2 JSON (pure functions)
    routes.py               the /v2 endpoints
    legacy.py               the v1 pass-through (/i/api/graphql/...)
    main.py                 routing, authentication, top-level error handling
    data/ops.json           bundled snapshot of the operation catalog
  www/                      copied into the document root (…/www/xclient/)
    .htaccess
    requests.ndjson         v1 catalog (kept for the old app version)
    cgi-bin/xrelay.cgi      thin entry point
  tools/
    update_ops.py           rebuilds app/xrelay_app/data/ops.json from the public catalog
    replay_samples.py       runs normalize.py over captured real answers (local use; captures are never committed)
  tests/
    fixtures/*.json         hand-made X-shaped answers
    test_*.py
```

Installed layout on the server (`~` is the account's home):

```
~/private/xrelay/config.json       secrets (600)
~/private/xrelay/python/           pip --target directory with the third-party packages
~/private/xrelay/app/xrelay_app/   this package (installed by deploy.sh)
~/private/xrelay/tid-cache/        transaction-id key cache (700)
~/private/xrelay/cache/            operation catalog cache (700)
~/www/xclient/.htaccess, requests.ndjson, cgi-bin/xrelay.cgi
```

### 2.1 `www/cgi-bin/xrelay.cgi`

Shebang `#!/usr/local/bin/python`. It only locates the code and runs it:

- `PRIVATE_ROOT` = environment `XRELAY_HOME` if set, else `Path.home() / "private" / "xrelay"`.
- Insert `PRIVATE_ROOT/"app"` and `PRIVATE_ROOT/"python"` at the front of `sys.path` (those that exist).
- `from xrelay_app.main import run; run(www_root=Path(__file__).resolve().parent.parent)` (`www_root` is the
  installed `www` directory, where `requests.ndjson` lies).
- If the import fails, answer `503` with `{"error": "CGI application is not installed."}` (plain `print`, no
  dependency on the package) — never a traceback.

### 2.2 `www/.htaccess`

```
Options -Indexes
RewriteEngine On
RewriteRule ^v2/(.*)$ cgi-bin/xrelay.cgi?__path=/v2/$1 [QSA,L]
RewriteRule ^i/api/(.*)$ cgi-bin/xrelay.cgi?__path=/i/api/$1 [QSA,L]
RewriteRule ^(profiles|healthz)$ cgi-bin/xrelay.cgi?__path=/$1 [QSA,L]
```

The route is passed in the `__path` query parameter (exactly one; must start with `/`, no `..`, no backslash, no NUL).

## 3. Modules

Signatures are normative: other modules and the tests rely on them.

### 3.1 `errors.py`

```python
class RelayError(Exception):
    def __init__(self, status, code, message, x_code=None, retry_after=None): ...
    # attributes: status (int), code (str), message (str), x_code (int or None), retry_after (int or None)
    def body(self):           # {"error": {"code":…, "message":…, "x_code":…, "retry_after":…}}
```

`code` values and HTTP statuses are those of api-v2.md §1. Messages are Japanese and never contain secrets.

### 3.2 `config.py`

```python
def private_root()                      # Path; honours XRELAY_HOME
def config_path()                       # Path; honours XRELAY_CONFIG (used by tests), else private_root()/"config.json"
def load_config()                       # dict; raises RelayError(503, "unavailable", …)
def select_profile(config, name)        # (name, profile dict); name None/"" -> config["default_profile"]
def client_key_matches(config, environ) # bool; constant-time compare of sha256(key) with config["client_token_sha256"]
def write_private(path, data)           # atomic write of bytes, mode 600 (temp file + os.replace)
def update_profile_ct0(profile_name, ct0)   # re-reads the config file, replaces that profile's ct0, writes atomically
```

Config file format (unchanged):

```json
{"client_token_sha256": "<64 hex>", "default_profile": "account1", "x_bearer_token": "Bearer AAAA…",
 "profiles": {"account1": {"auth_token": "…", "ct0": "…", "user_agent": "Mozilla/5.0 …",
                           "sec_ch_ua_platform": "\"Windows\"", "sec_ch_ua": "\"Chromium\";v=\"…\""}}}
```

`load_config` rules (same as the current CGI): the file must not be group/world accessible (`mode & 0o077 == 0`,
else 503; skip this check on Windows where `os.name == "nt"`), `client_token_sha256` must match `^[0-9a-f]{64}$`,
`x_bearer_token` non-empty, `profiles` a non-empty dict. `select_profile`: unknown name → `RelayError(400,
"bad_request")`; a profile without `auth_token`/`ct0`/`user_agent` → 503.

The CGI key is read from `HTTP_X_RELAY_KEY`, else from `HTTP_AUTHORIZATION` / `REDIRECT_HTTP_AUTHORIZATION`
(`Bearer <key>`).

### 3.3 `cgiio.py`

```python
class Request(object):
    method      # "GET" / "POST"
    path        # "/v2/home"
    query       # list of (key, value) pairs without "__path"
    environ     # the CGI environment (headers as HTTP_*)
    body        # bytes (b"" for GET)
    def param(self, name, default=None)   # first query value with that name
    def json(self)                        # parsed JSON object of the body; RelayError(400) if not a JSON object

def read_request(environ, stdin)          # -> Request; RelayError(400/405/413) on malformed input
def send(status, payload, environ, stdout, content_type="application/json; charset=utf-8")
```

- Methods other than GET/POST → 405. Body limit 256 KiB (413). `Content-Length` must be a valid number and the body
  complete.
- `send`: `payload` is a dict (JSON-encoded with `ensure_ascii=False, separators=(",", ":")`), `bytes` or `str`.
  Headers: `Status: <code> <reason>`, `Content-Type`, `Cache-Control: no-store`, `X-Content-Type-Options: nosniff`,
  `Vary: Accept-Encoding`, `Content-Length`. When `HTTP_ACCEPT_ENCODING` contains `gzip` and the body is ≥ 1024
  bytes, gzip it (level 6) and add `Content-Encoding: gzip`. Write headers as text to `stdout`, the body to
  `stdout.buffer` (flush in between), exactly like the current `_send`.

### 3.4 `transaction.py` — `x-client-transaction-id`

X checks this header strictly on some operations (`SearchTimeline`, `UserTweetsAndReplies`: wrong id → HTTP 404 with
an empty body) and not on others.

```python
def generate_transaction_id(method, path, key, animation_key, now=None, rand=None)   # pure
def get_transaction_id(profile, method, path)      # uses the cached key material, refreshing it when needed
def invalidate(profile)                            # forget the cache (next call refreshes)
```

**Generation** (must reproduce the reference vectors below):

```
time_now   = floor(now or time.time()) - 1682924400            # seconds since 2023-05-01T07:00:00Z
key_bytes  = base64-decode(key)
digest     = sha256("{method}!{path}!{time_now}obfiowerehiring{animation_key}")
payload    = key_bytes + [time_now little-endian, 4 bytes] + digest[:16] + [3]
rand       = rand if given else random.randint(0, 255)
out        = [rand] + [b ^ rand for b in payload]
result     = base64(out) without "=" padding
```

`path` is the URL path only (`/i/api/graphql/<id>/<Name>`), no query string.

Reference vectors (`key = "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8w"`,
`animation_key = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345"`; `now` = `time_now + 1682924400`):

| method | path | time_now | rand | result |
|---|---|---|---|---|
| GET | `/i/api/graphql/vLHjqbDv7TPFMBkIIO1nOA/SearchTimeline` | 111222333 | 77 | `TUxPTklIS0pFREdGQUBDQl1cX15ZWFtaVVRXVlFQU1JtbG9uaWhramVkZ2ZhYGNifXBT7Etz6J5dLhLRh8Tc6K3KycfNTg` |
| POST | `/i/api/graphql/lI07N6Otwv1PhnEgXILM7A/FavoriteTweet` | 1 | 0 | `AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gISIjJCUmJygpKissLS4vMAEAAADXuL+VG/3ewPfmWctnDC4YAw` |
| GET | `/i/api/1.1/dm/inbox_initial_state.json` | 2317075600 | 255 | `//79/Pv6+fj39vX08/Lx8O/u7ezr6uno5+bl5OPi4eDf3t3c29rZ2NfW1dTT0tHQz2875HUB+ppDmRLlGBp6RShreI87/A` |

**Key material** (`key`, `animation_key`) comes from X's web app shell and one of its scripts:

1. `GET https://x.com/i/jf/` — browser navigation headers, **no cookies**, redirects followed, timeout `(5, 25)`.
   (`https://x.com/home` without a login answers with an onboarding page that lacks the script table; that was the
   bug behind search failing with 404.) Headers: `User-Agent` = the profile's; `Accept:
   text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8`;
   `Accept-Language: ja,en;q=0.9`; `Cache-Control: no-cache`; `Sec-Fetch-Dest: document`; `Sec-Fetch-Mode: navigate`;
   `Sec-Fetch-Site: none`; `Sec-Fetch-User: ?1`; `Upgrade-Insecure-Requests: 1`; plus the profile's `sec-ch-ua` and
   `sec-ch-ua-platform` when set.
2. Find the script URL in the HTML with
   `(\d+):\s*["']ondemand\.s["'][\s\S]*?\}\)\[e\]\s*\|\|\s*e\)\s*\+\s*["']\.["']\s*\+\s*\(\{[\s\S]*?\b\1:\s*["']([a-zA-Z0-9_-]+)["']`
   → `https://abs.twimg.com/responsive-web/client-web/ondemand.s.<group 2>a.js`.
   Fallback 1: `x_client_transaction.utils.get_ondemand_file_url(response=soup)`.
   Fallback 2: key `"ondemand.s"` of
   `https://raw.githubusercontent.com/fa0311/TwitterInternalAPIDocument/develop/docs/json/ScriptLoadJson.json`.
   Accept the URL only if: scheme `https`, host `abs.twimg.com`, path starts with
   `/responsive-web/client-web/ondemand.s.` and ends with `.js`, no query, no fragment.
3. `GET` that script.
4. `ClientTransaction(home_page_response=BeautifulSoup(html, "html.parser"), ondemand_file_response=script_text)`
   → `.key` and `.animation_key`.
5. If step 1–4 fail, try once more with `https://x.com/home` **with** the session cookies (`auth_token`, `ct0`).

**Cache**: `private_root()/"tid-cache"/<fingerprint>/"keys.json"` =
`{"key": …, "animation_key": …, "fetched_at": <epoch>, "source": <page url>}` (mode 600; directories 700).
`fingerprint` = first 16 hex of `sha256(user_agent + sec_ch_ua_platform)`. Fresh for 6 hours. Refresh under an
exclusive `fcntl.flock` on `tid.lock` in that directory (skip locking where `fcntl` is missing). If a refresh fails
and an old `keys.json` exists (any age), keep using it; if there is none, raise
`RelayError(502, "x_error", …)`. `invalidate` marks the cache stale (for example by setting `fetched_at` to 0) so the
next call refreshes but can still fall back to the old keys.

### 3.5 `catalog.py` — GraphQL operations

Query ids and feature flags change every few weeks. The public repository
`fa0311/TwitterInternalAPIDocument` tracks them daily:
`https://raw.githubusercontent.com/fa0311/TwitterInternalAPIDocument/develop/docs/json/API.json`
= `{"graphql": {"<OperationName>": {"url": …, "queryId": "…", "method": "GET"|"POST", "features": {…}}, …}, "header": {…}}`.

```python
def get_operation(name)     # {"queryId": str, "method": "GET"|"POST", "features": dict}; RelayError(503) if unknown
```

- Sources, in order: (1) `private_root()/"cache"/"ops.json"` when younger than 24 h; (2) a fresh download
  (timeout `(5, 15)`), reduced to the operations of §4 and written to that cache file; (3) the stale cache file;
  (4) the bundled `data/ops.json`. A failed download must not fail the request.
- Validate every entry taken from the download: `queryId` matches `^[A-Za-z0-9_-]{10,40}$`, `method` is the one §4
  expects for that operation, `features` is a dict whose values are all `bool`. Invalid entries are dropped (the
  older source is used for them).
- Cache/bundle file format: `{"fetched_at": <epoch>, "ops": {"HomeTimeline": {"queryId": …, "method": …, "features": {…}}, …}}`.
- `tools/update_ops.py` writes the bundled file from a downloaded `API.json` (path argument or download).

### 3.6 `xapi.py`

```python
class XClient(object):
    def __init__(self, config, profile_name, profile): ...
    def graphql(self, name, variables, field_toggles=None)   # -> parsed JSON dict (the whole body)
    def rest(self, method, path, params=None, form=None, json_body=None)   # path like "/i/api/1.1/…"; -> parsed JSON
```

Request headers (as the current CGI): `Authorization` (config `x_bearer_token`, prefixed with `Bearer ` when
missing), `User-Agent`, `Accept: application/json, text/plain, */*`, `Origin: https://x.com`,
`Referer: https://x.com/home`, `Content-Type: application/json` (`application/x-www-form-urlencoded` for `form`),
`x-csrf-token: <ct0>`, `x-twitter-active-user: yes`, `x-twitter-auth-type: OAuth2Session`,
`x-twitter-client-language: ja`, `x-client-transaction-id`, the profile's `sec-ch-ua*`. Cookies: `auth_token`, `ct0`
(domain `.x.com`). URL: `https://x.com` + path. Timeout `(5, 40)`. A new `requests.Session` per call, closed after.

`graphql`: `path = "/i/api/graphql/<queryId>/<name>"`.
GET: query parameters `variables`, `features` (omit when the dict is empty), `fieldToggles` (omit when `None`), each
compact JSON. POST: JSON body `{"variables": …, "queryId": …}` plus `"features"` (when non-empty) and
`"fieldToggles"` (when given).

Answer handling (both methods):

| situation | result |
|---|---|
| network error / timeout | `RelayError(502, "x_error", "Xに接続できませんでした。")` |
| HTTP 404 with an empty body, first time | `transaction.invalidate(profile)`, then repeat the request **once** |
| HTTP 429, or X error code 88 | `RelayError(429, "rate_limited", …, x_code=88, retry_after=max(0, x-rate-limit-reset − now))` (`retry_after` `None` without that header) |
| HTTP 401/403, or X error code 32, 64, 89, 215, 326, 353 | `RelayError(403, "x_auth", "Xのログイン情報が無効です。サーバーで setup_config.py を実行して更新してください。", x_code=…)` |
| X error code 34, 50, 63, 144, 421, 422 (no data) | `RelayError(404, "not_found", …)` |
| other HTTP ≥ 400, body not JSON, or `errors` without usable `data` | `RelayError(502, "x_error", <X's message or "Xからエラーが返されました。">, x_code=…)` |
| HTTP 2xx with JSON | return the dict |

- GraphQL answers may carry `errors` **and** valid `data` (some sub-object failed). That is a success: only treat
  `errors` as failure when `data` is missing, `null`, `{}` or all of its values are `null`.
- X error objects look like `{"message": "…", "code": 88, …}` (also `{"errors":[…]}` for REST).
- `ct0` rotation: when an answer sets a `ct0` cookie that differs from the profile's, store it with
  `config.update_profile_ct0` (ignore write failures) and use it for the rest of this request. On error code 353
  with a new `ct0`, repeat the request once.

### 3.7 `normalize.py`

Pure functions (no I/O, no globals mutated, never raise on odd input — unknown shapes are skipped):

```python
def find_instructions(data)                    # first list found under a key "instructions" (depth-first); [] if none
def normalize_user(result, full=False)         # X "User" object -> api-v2 User / FullUser, or None
def normalize_tweet(result)                    # X tweet result -> api-v2 Tweet, or None when it cannot be shown
def normalize_timeline(data, focal_id=None)    # whole GraphQL answer -> {"items": […], "top": …, "bottom": …}
def normalize_explore(data)                    # ExplorePage answer -> {"tabs": […], "tab": …, "items": […], "top": None, "bottom": None}
def normalize_user_response(data)              # Viewer / UserByScreenName / UserByRestId answer -> FullUser or None
def normalize_created_tweet(data)              # CreateTweet answer -> Tweet or None
```

Rules are in §5 and §6.

### 3.8 `routes.py`

```python
def dispatch(request, client, normalizer=None)   # -> (status, payload dict)
```

`client` is an `XClient` (tests pass a fake with the same two methods); `normalizer` defaults to the
`xrelay_app.normalize` module (imported inside `dispatch`, so tests can pass a fake object and never import the real
one). Every `/v2` route of api-v2.md §3 is implemented here with the X requests of §4. Parameter validation:

- ids (`id`, `reply_to`, `quote`, `media_ids[]`): `^[0-9]{1,25}$`. `handle`: `^[A-Za-z0-9_]{1,20}$` (a leading `@` is
  stripped). `cursor`: 1…2000 characters. `q`: 1…500 characters after trimming. `tab`/`mode`/`kind`: one of the
  listed words. `on`: JSON boolean. `text`: string, 1…4000 characters after trimming.
- Anything else → `RelayError(400, "bad_request", …)`. Unknown route → `RelayError(404, "not_found", …)`.
  GET route called with POST (or the reverse) → `RelayError(405, "bad_request", …)`.

"Already in that state" answers of X are a success for the write routes: error codes 139 (already liked), 327
(already reposted), 144 (nothing to undo), 405 (already bookmarked) → `{"ok": true}`.

### 3.9 `legacy.py`

The v1 behaviour, for the app version that is installed now: `GET/POST /i/api/graphql/<id>/<Operation>` for
`GET HomeTimeline`, `GET SearchTimeline`, `POST CreateTweet` only, the request validated against
`www/requests.ndjson` and the `CreateTweet` body normalised exactly as the current `xrelay.cgi` does
(`_catalog_record`, `_validate_post`). The request is sent through `XClient`'s transport (so it gets the fixed
transaction id) and X's answer is passed through unchanged (status, content type, body). Errors use the old body
`{"error": "text"}`.

### 3.10 `main.py`

```python
def handle(environ, stdin, stdout, www_root=None)    # one request; never raises
def run(www_root=None)                               # handle(os.environ, sys.stdin, sys.stdout, www_root)
```

`www_root` (a `Path`) is where `requests.ndjson` is read from by `legacy`; when `None`, the v1 pass-through answers
503.

Order: read the request → `/healthz` (GET, no key) → load config → check the CGI key (401) → `/profiles` → select
the profile (`HTTP_X_PROFILE_NAME`) → `/v2/...` via `routes.dispatch` → `/i/api/graphql/...` via `legacy` → else 404.
`RelayError` → its status and body (old body shape for non-`/v2` paths); any other exception →
`500 {"error": {"code": "internal", …}}` without details.

## 4. X requests

`…` in variables means "plus `"cursor": <cursor>` when the route got one".

| Route | Operation (method) | variables | fieldToggles |
|---|---|---|---|
| `/v2/home?tab=foryou` | `HomeTimeline` (GET) | first page `{"count":20,"includePromotedContent":true,"requestContext":"launch","withCommunity":true}`; with cursor `{"count":20,"cursor":C,"includePromotedContent":true,"withCommunity":true}` | `{"withPayments":false}` |
| `/v2/home?tab=following` | `HomeLatestTimeline` (GET) | same as above plus `"latestControlAvailable":true` | `{"withPayments":false}` |
| `/v2/tweet` | `TweetDetail` (GET) | `{"focalTweetId":ID,"with_rux_injections":false,"rankingMode":"Relevance","includePromotedContent":true,"withCommunity":true,"withQuickPromoteEligibilityTweetFields":true,"withBirdwatchNotes":true,"withVoice":true}`; with cursor add `"cursor":C,"referrer":"tweet"` | `{"withArticleRichContentState":true,"withArticlePlainText":false,"withGrokAnalyze":false,"withDisallowedReplyControls":false}` |
| `/v2/search` | `SearchTimeline` (GET) | `{"rawQuery":Q,"count":20,"querySource":"typed_query","product":P,"withGrokTranslatedBio":false,…}` with `P` = `Top` / `Latest` / `People` / `Media` | — |
| `/v2/user?handle=` | `UserByScreenName` (GET) | `{"screen_name":H,"withGrokTranslatedBio":false}` | `{"withPayments":false,"withAuxiliaryUserLabels":true}` |
| `/v2/user?id=` | `UserByRestId` (GET) | `{"userId":ID}` | `{"withPayments":false,"withAuxiliaryUserLabels":true}` |
| `/v2/user/timeline?tab=posts` | `UserTweets` (GET) | `{"userId":ID,"count":20,"includePromotedContent":true,"withQuickPromoteEligibilityTweetFields":true,"withVoice":true,…}` | `{"withArticlePlainText":false}` |
| `…?tab=replies` | `UserTweetsAndReplies` (GET) | `{"userId":ID,"count":20,"includePromotedContent":true,"withCommunity":true,"withVoice":true,…}` | `{"withArticlePlainText":false}` |
| `…?tab=media` | `UserMedia` (GET) | `{"userId":ID,"count":20,"includePromotedContent":false,"withClientEventToken":false,"withBirdwatchNotes":false,"withVoice":true,…}` | `{"withArticlePlainText":false}` |
| `…?tab=likes` | `Likes` (GET) | same as `UserMedia` | `{"withArticlePlainText":false}` |
| `/v2/user/follows?kind=following` | `Following` (GET) | `{"userId":ID,"count":20,"includePromotedContent":false,"withGrokTranslatedBio":false,…}` | — |
| `…?kind=followers` | `Followers` (GET) | same | — |
| `/v2/notifications` | `NotificationsTimeline` (GET) | `{"timeline_type":"All" or "Mentions","count":20,…}` | — |
| `/v2/bookmarks` | `Bookmarks` (GET) | `{"count":20,"includePromotedContent":true,…}` | — |
| `/v2/explore` (first tab) | `ExplorePage` (GET) | `{"cursor":""}` | — |
| `/v2/explore?tab=<other>` | `ExplorePage` to learn the tab's `timeline.id`, then `GenericTimelineById` (GET) | `{"timelineId":TID,"count":20,"withQuickPromoteEligibilityTweetFields":true}` | — |
| `/v2/me` | `Viewer` (GET), then REST badge count | `{"withCommunitiesMemberships":true}` | `{"isDelegate":false,"withAuxiliaryUserLabels":true}` |
| `/v2/badges` | REST `GET /i/api/2/badge_count/badge_count.json?supports_ntab_urt=1` → `{"ntab_unread_count": 5, "dm_unread_count": 0, …}` | | |
| `/v2/tweet/like` | `FavoriteTweet` / `UnfavoriteTweet` (POST) | `{"tweet_id":ID}` | — |
| `/v2/tweet/retweet` on | `CreateRetweet` (POST) | `{"tweet_id":ID,"dark_request":false}` | — |
| `/v2/tweet/retweet` off | `DeleteRetweet` (POST) | `{"source_tweet_id":ID,"dark_request":false}` | — |
| `/v2/tweet/bookmark` | `CreateBookmark` / `DeleteBookmark` (POST) | `{"tweet_id":ID}` | — |
| `/v2/tweet/delete` | `DeleteTweet` (POST) | `{"tweet_id":ID,"dark_request":false}` | — |
| `/v2/tweet/create` | `CreateTweet` (POST) | `{"tweet_text":T,"dark_request":false,"media":{"media_entities":[{"media_id":M,"tagged_users":[]}…],"possibly_sensitive":false},"semantic_annotation_ids":[],"disallowed_reply_options":null}` plus, for a reply, `"reply":{"in_reply_to_tweet_id":ID,"exclude_reply_user_ids":[]}` and, for a quote, `"attachment_url":"https://x.com/i/status/<ID>"` | — |
| `/v2/user/follow` | REST `POST /i/api/1.1/friendships/create.json` / `destroy.json` | form: `include_profile_interstitial_type=1&include_blocking=1&include_blocked_by=1&include_followed_by=1&include_want_retweets=1&include_mute_edge=1&include_can_dm=1&include_can_media_tag=1&include_ext_is_blue_verified=1&include_ext_verified_type=1&include_ext_profile_image_shape=1&skip_status=1&user_id=<ID>` | |
| `/v2/user/mute` | REST `POST /i/api/1.1/mutes/users/create.json` / `destroy.json` | form: `user_id=<ID>` | |
| `/v2/user/block` | REST `POST /i/api/1.1/blocks/create.json` / `destroy.json` | form: `user_id=<ID>` | |

The operations the catalog must know: `HomeTimeline`, `HomeLatestTimeline`, `TweetDetail`, `SearchTimeline`,
`UserByScreenName`, `UserByRestId`, `UserTweets`, `UserTweetsAndReplies`, `UserMedia`, `Likes`, `Following`,
`Followers`, `NotificationsTimeline`, `Bookmarks`, `ExplorePage`, `GenericTimelineById`, `Viewer` (all GET);
`FavoriteTweet`, `UnfavoriteTweet`, `CreateRetweet`, `DeleteRetweet`, `CreateBookmark`, `DeleteBookmark`,
`CreateTweet`, `DeleteTweet` (all POST).

`/v2/me` answers `{"user": normalize_user_response(viewer answer), "badges": {"notifications": ntab_unread_count,
"messages": dm_unread_count}}`; if the badge request fails, the badges are `0` (the route still succeeds).

`/v2/explore`: tabs are `data.explore_page.body.timelines[]` (`{"id": "for_you", "labelText": "話題を検索",
"timeline": {"id": "VGltZWxpbmU6…"}}`), `data.explore_page.body.initialTimeline` holds the content of the first tab.

## 5. X's JSON (as of 2026-11)

Timeline-shaped answers contain, somewhere inside `data`, an object with `"instructions": [...]`
(`data.home.home_timeline_urt`, `data.threaded_conversation_with_injections_v2`,
`data.search_by_raw_query.search_timeline.timeline`, `data.user.result.timeline.timeline`,
`data.bookmark_timeline_v2.timeline`, `data.viewer_v2.user_results.result.notification_timeline.timeline`,
`data.timeline.timeline`, `data.explore_page.body.initialTimeline.timeline.timeline`). Use `find_instructions`.

### 5.1 Instructions

| `type` | content |
|---|---|
| `TimelineAddEntries` | `entries: [entry]` |
| `TimelinePinEntry` | `entry` (a pinned post; shown first) |
| `TimelineAddToModule` | `moduleItems: [{"entryId":…, "item": {"itemContent": …}}]` (continuation of a grid/thread) |
| `TimelineReplaceEntry` | `entry` (normally a cursor) |
| `TimelineTerminateTimeline` | `direction: "Top" \| "Bottom"` — no more entries that way |
| `TimelineClearCache`, `TimelineClearEntriesUnreadState`, `TimelineMarkEntriesUnreadGreaterThanSortIndex`, others | ignore |

An entry: `{"entryId": "tweet-2122…", "sortIndex": "…", "content": {…}}`. `content.entryType` (same as
`content.__typename`):

- `TimelineTimelineItem` → `content.itemContent`
- `TimelineTimelineModule` → `content.items: [{"entryId":…, "item": {"itemContent": …}}]`, `content.displayType`
  (`VerticalConversation`, `Vertical`, `VerticalGrid`, `Carousel`), optional `content.header.text`
- `TimelineTimelineCursor` → `content.cursorType` (`Top`, `Bottom`, `ShowMoreThreads`, `ShowMoreThreadsPrompt`,
  `ShowMore`, `Gap`), `content.value`, optional `content.displayTreatment.actionText`

`itemContent.itemType` (same as `itemContent.__typename`):

- `TimelineTweet`: `tweet_results.result` (may be absent), `tweetDisplayType`, optional `promotedMetadata` (an
  advertisement), optional `socialContext`
- `TimelineUser`: `user_results.result`, optional `promotedMetadata`
- `TimelineNotification`: see 5.5
- `TimelineTrend`: see 5.6
- `TimelineTimelineCursor`: a cursor inside a module (`cursorType`, `value`, `displayTreatment`)
- `TimelineTombstone`: `tombstoneInfo.richText.text` (or `tombstoneInfo.text`)
- `TimelineLabel`: `text`
- `TimelinePrompt`, `TimelineMessagePrompt`, `TimelineEventSummary`, `TimelineCommunity`, anything else: ignore

Module entry ids seen: `home-conversation-…`, `profile-conversation-…`, `conversationthread-…`
(`VerticalConversation`); `who-to-follow-…` (`Vertical`, users); `tweetdetailrelatedtweets-…` (`Vertical`, posts,
header "もっと見つける"); `profile-grid-…` (`VerticalGrid`, posts with `tweetDisplayType: "MediaGrid"`); `stories-…`
(`Vertical`, trends, header "本日のニュース"); `tweet-…` in explore (`Vertical`, posts).

`socialContext`: `{"type": "TimelineGeneralContext", "contextType": "Pin" | "TextOnly" | "Like" | "Follow" |
"Conversation" | "Facepile" | …, "text": "固定"}` or `{"type": "TimelineTopicContext", "topic": {"name": "…"}}`.

### 5.2 Tweet result

`tweet_results.result.__typename`:

- `Tweet` — below.
- `TweetWithVisibilityResults` — `{"tweet": <Tweet without __typename>, "limitedActionResults": {…}?,
  "tweetInterstitial": {…}?}`. Use `.tweet`; `limitedActionResults` present → `reply_limited: true`.
- `TweetTombstone` — `{"tombstone": {"text": {"text": "このポストは、ポストの作成者により削除されました。詳細はこちら", …}}}`.
- `TweetUnavailable` — `{"reason": "…"}`.

```
Tweet
  rest_id                                   "1900000000000000001"
  core.user_results.result                  User (5.3)
  legacy
    full_text                               HTML-escaped (&amp; &lt; &gt;), with t.co links
    display_text_range                      [start, end] in Unicode code points of full_text
    created_at                              "Mon Nov 16 06:48:58 +0000 2026"
    conversation_id_str
    favorite_count, retweet_count, reply_count, quote_count, bookmark_count     ints
    favorited, retweeted, bookmarked        bools
    lang, possibly_sensitive
    in_reply_to_status_id_str, in_reply_to_screen_name, in_reply_to_user_id_str  (replies only)
    is_quote_status, quoted_status_id_str, quoted_status_permalink.{url,expanded,display}
    entities.urls[]            {indices:[s,e], url:"https://t.co/…", display_url:"example.com/pa…", expanded_url:"https://example.com/page"}
    entities.user_mentions[]   {indices, screen_name, name, id_str}
    entities.hashtags[]        {indices, text}
    entities.symbols[]         {indices, text}
    entities.media[], extended_entities.media[]   (prefer extended_entities)
        type                   "photo" | "video" | "animated_gif"
        media_url_https        "https://pbs.twimg.com/media/AbCdEfGhIjKlMnO.jpg" (poster frame for video)
        indices, url           the t.co link of the media inside full_text
        original_info.{width,height}
        ext_alt_text           string or null
        video_info             {aspect_ratio:[16,9], duration_millis:19919,
                                variants:[{content_type:"application/x-mpegURL", url:"…m3u8"},
                                          {bitrate:832000, content_type:"video/mp4", url:"…mp4"}, …]}
    retweeted_status_result.result          the original post when this is a repost (then full_text is "RT @x: …")
    place.full_name                         "東京 世田谷区"
    conversation_control                    present when replies are restricted
  note_tweet.note_tweet_results.result      long post: {text, entity_set:{urls,user_mentions,hashtags,symbols}} (indices refer to this text)
  quoted_status_result.result               Tweet | TweetWithVisibilityResults | TweetTombstone (absent when unavailable)
  card.legacy                               {name, url, binding_values:[{key, value:{string_value|image_value|boolean_value, type}}]}
  views.count                               "134034" (a string; absent when there is no counter)
  source                                    "<a href=\"…\" rel=\"nofollow\">Twitter for Android</a>"
  edit_control.edit_tweet_ids               more than one id → edited (may also be nested as edit_control.edit_control_initial.edit_tweet_ids)
```

All `indices` are in Unicode code points (Python `str` indices), of the escaped text.

Cards (`card.legacy.name`, sometimes prefixed like `"3691233323:audiospace"` — compare the part after the last `:`):

- `summary`, `summary_large_image`, `player`: binding values `title`, `description`, `domain`, `vanity_url`,
  `card_url` (a t.co link) and images `photo_image_full_size_large` / `summary_photo_image_large` /
  `thumbnail_image_large` / `player_image_large` (`image_value: {url, width, height}`; take the first that exists,
  `summary` prefers `thumbnail_image_large`). `domain` of the card = `vanity_url` or `domain` without a leading
  `www.`. The card's destination = the `expanded_url` of the `entities.urls` entry whose `url` equals `card_url` (or
  `card.legacy.url`), else `card_url`.
- `poll2choice_text_only`, `poll3choice_text_only`, `poll4choice_text_only` (also `…_image`, `…_video`):
  `choice1_label` … `choice4_label`, `choice1_count` … (strings), `end_datetime_utc` (`"2026-11-17T06:48:58Z"`),
  `counts_are_final` (boolean_value).
- Everything else (`unified_card`, `audiospace`, `live_event`, …): no card (`null`).

### 5.3 User

```
User
  __typename                 "User" ("UserUnavailable" → not shown)
  rest_id                    "1800000000000000001"
  core.{name, screen_name, created_at}
  avatar.image_url           "https://pbs.twimg.com/profile_images/…_normal.jpg"
  banner.image_url           (absent when the user has none)
  is_blue_verified           bool
  verification.verified_type "Business" | "Government" | absent
  profile_image_shape        "Circle" | "Square"
  privacy.protected          bool
  relationship_perspectives.{following, followed_by, blocking, blocked_by, muting}
  follow_request_sent        bool
  relationship_counts.{followers, following}
  tweet_counts.{tweets, media_tweets}
  action_counts.favorites_count
  profile_bio.description                    text with t.co links
  profile_bio.entities.description.urls[]    {indices, url, display_url, expanded_url} (also user_mentions/hashtags may appear)
  profile_bio.entities.url.urls[0]           {display_url, expanded_url} of the profile link
  location.location
  pinned_items.tweet_ids_str
  affiliates_highlighted_label.label         {description:"OpenAI", badge:{url:"…"}} (absent or {} otherwise)
```

Older answers (and some REST objects) use `legacy.{name, screen_name, profile_image_url_https, verified,
protected, followers_count, friends_count, statuses_count, description, location, profile_banner_url, created_at,
following, followed_by}`: fall back to those when the new field is missing.

### 5.4 Cursors and the end of a list

`bottom` = value of the last `Bottom` cursor; `top` = value of the `Top` cursor. Set `bottom` to `null` when a
`TimelineTerminateTimeline` with `direction: "Bottom"` was seen, or when the answer produced no item at all.

### 5.5 Notifications

```
itemContent (TimelineNotification)
  id, notification_icon      "heart_icon" | "retweet_icon" | "person_icon" | "recommendation_icon" | "bird_icon" | "bell_icon" | "reply_icon" | "milestone_icon" | "security_alert_icon" | "safety_icon" | …
  rich_message.text          "山田 太郎さんからの最新のポスト"
  rich_message.entities[]    {fromIndex, toIndex, format:"Strong"} (code points)
  template.from_users[]      {user_results.result: User}
  template.target_objects[]  {__typename:"TimelineNotificationTweetRef", tweet_results.result: Tweet}
  timestamp_ms               "2026-11-10T02:19:28.382Z" (ISO 8601; older answers: milliseconds as a string)
  notification_url.url
```

Icon mapping: `heart_icon`→`heart`, `retweet_icon`→`repost`, `person_icon`→`person`,
`recommendation_icon`/`milestone_icon`→`star`, `bird_icon`→`logo`, `reply_icon`→`reply`,
`security_alert_icon`/`safety_icon`→`alert`, everything else→`bell`.

### 5.6 Trends

```
itemContent (TimelineTrend)
  name                                   "デモフェス"
  trend_metadata.domain_context          "エンターテインメント · トレンド"
  trend_metadata.meta_description        "1.2万件のポスト" (may be absent)
  trend_url.url                          "twitter://search/?query=%E3%83%87%E3%83%A2%E3%83%95%E3%82%A7%E3%82%B9&src=trend_click&…"  or "twitter://trending/<id>"
  social_context.text                    "2時間前 · エンターテイメント · 213件のポスト" (AI news items)
  rank                                   may be absent
```

`query` = the decoded `query` parameter of `trend_url.url` when it is a `twitter://search/` link, else `name`.
`context` = `trend_metadata.domain_context`, else `social_context.text`.

## 6. Normalisation rules

### 6.1 Text

Input: the text, its display range and its entities (for a long post: `note_tweet…text` with `entity_set`, range =
whole text; otherwise `legacy.full_text` with `legacy.entities` and `legacy.display_text_range`).

1. Work on code points. Take the part inside the display range. (The range of a reply starts after the leading
   `@mentions`; the range ends before the attached-media link.)
   For a long post that is a reply, drop the same leading mentions: if `legacy.display_text_range[0] > 0` and the
   note text starts with the same characters as `full_text[:start]`, start there.
2. Walk the entities that lie inside the range, in order, skipping any that overlap an earlier one or have bad
   indices:
   - URL → emit its `display_url` (fall back to `expanded_url`, then the t.co link) and record
     `{"k":"url","v": expanded_url or url}`.
   - mention / hashtag / cashtag → emit the original characters and record the entity (`v` = `screen_name` /
     `text` / `text`).
   - media link → emit nothing.
3. Decode `&lt;` `&gt;` `&amp;` (in that order) in the plain parts between entities.
4. Remove a URL entity that ends the text (only whitespace after it) when
   (a) the post has a card and the entity's t.co link is the card's link, or
   (b) the post quotes another post and the entity's `expanded_url` contains `/status/<quoted id>`.
   Then strip trailing whitespace. (Do not strip leading whitespace: offsets would shift.)
5. Entity offsets are UTF-16 code units of the final text: `len(s.encode("utf-16-le")) // 2`.

### 6.2 Tweet

- A repost (`legacy.retweeted_status_result.result` present and normalisable): return the normalised **original**
  with `retweeted_by` = the reposting user and `retweet_id` = the repost's `rest_id`.
- `quote`: normalised `quoted_status_result.result` with its own `quote` forced to `null` and `quote_unavailable`
  to `null`. If the quoted result is a tombstone/unavailable, or `legacy.is_quote_status` is true and there is no
  quoted result: `quote: null`, `quote_unavailable` = the tombstone text or `"このポストは表示できません。"`.
- `reply_to`: when `in_reply_to_status_id_str` is set: `handles` = `in_reply_to_screen_name` followed by the
  screen names of the other mentions that lie entirely before `display_text_range[0]` (no duplicates,
  case-insensitive).
- `media[].video.mp4`: for `video` the MP4 variant with the highest bitrate ≤ 1,300,000; if none, the MP4 with the
  lowest bitrate; for `gif` the only MP4. `hls` = the `application/x-mpegURL` variant.
- `view_count`: `int(views.count)` or `null`. `created_at`: parse `"%a %b %d %H:%M:%S %z %Y"`.
- `source`: `source` with HTML tags removed, or `null`. `edited`: more than one id in `edit_tweet_ids`.
- A result without `legacy`, or without a usable user, is not shown (`None`).

### 6.3 Timeline

- Advertisements (`promotedMetadata` on the item) are dropped.
- A `TimelineTweet` whose result is a tombstone/unavailable → a `tombstone` item (text from the result, fallback
  `"このポストは表示できません。"`); a missing result is dropped.
- `VerticalConversation` module → its posts in order, joined: `above = (not first)`, `below = (not last)`. Cursors
  inside it become `more` items at their position.
- A module whose items are users (`who-to-follow…`) is dropped. Other modules with posts → a `header` item (when
  `content.header.text` is non-empty) followed by the posts as ordinary items. Trend modules → `header` + `trend`
  items.
- `TimelinePinEntry` → that post first, with `context: {"k": "pin", "text": "固定"}` unless its `socialContext`
  already provides one.
- Cursors: `Top`/`Bottom` → `top`/`bottom`; `ShowMoreThreads`, `ShowMoreThreadsPrompt`, `ShowMore` → `more` item
  (`label` = `displayTreatment.actionText` or `"返信をさらに表示"`); `Gap` and others ignored.
- `focal_id` given (post detail): the item whose post id (or `retweet_id`) equals it gets `focal: true`. Stand-alone
  post/tombstone items **before** it are the conversation it answers: each gets `below: true`, all but the first
  `above: true`, and the focal item gets `above: true` when there is at least one.
- Items keep X's order. The same post id is emitted once per answer (first occurrence wins), except that the focal
  post always stays and posts inside a `VerticalConversation` module are always kept (dropping one would break the
  thread line); a later stand-alone copy of a post already shown is still dropped.

## 7. Tests

`python -m unittest discover -s sakura/tests -v` must pass with Python 3.8 and with current Python, on a machine
without network access, without `bs4` and without `x_client_transaction`.

- Fixtures are hand-made (invented users, ids and texts) in X's shapes of §5.
- Cover at least: text rules (escaping, URL replacement, reply prefix, media link, card/quote link removal,
  characters outside the BMP → UTF-16 offsets, bad indices); users (new and `legacy` shape, the three verification
  kinds, square avatar, label); media (photo, video variant choice, gif); quotes (normal, tombstone, missing);
  reposts; cards (summary, large, player, poll, unsupported); long posts; every instruction and entry type of §5.1;
  advertisement removal; thread joining; detail view (`focal`, ancestors); cursors and end detection;
  notifications; trends; explore tabs; the transaction-id vectors; catalog validation and fallback order; every
  route (parameters → X request, validation errors, "already done" codes); the legacy pass-through; gzip output;
  the CGI key check.

## 8. `deploy.sh`

Run on the server from the repository checkout (`sh sakura/deploy.sh`). Steps, stopping at the first failure:

1. `python -m py_compile` on every `.py` under `sakura/app` and on `www/cgi-bin/xrelay.cgi`.
2. `python -m unittest discover -s sakura/tests` (with `PYTHONPATH` including `~/private/xrelay/python`).
3. Copy `sakura/app/xrelay_app` to `~/private/xrelay/app/xrelay_app.new`, then swap it in atomically
   (`mv` the old one aside, `mv` the new one in, remove the old one). Directory mode 700.
4. Copy `www/.htaccess`, `www/requests.ndjson` and `www/cgi-bin/xrelay.cgi` (mode 755) into the document root
   directory given as the first argument (default `~/www/xclient`), creating `cgi-bin` if needed.
5. Smoke test: run the installed CGI with `REQUEST_METHOD=GET QUERY_STRING=__path=/healthz` and require
   `{"status":"ok"}` in its output.

POSIX `sh` only (FreeBSD: no bash-isms, no GNU-only options).

## 9. Translation

- `GET /v2/tweet/translate?id=ID` → REST `GET
  /i/api/1.1/strato/column/None/tweetId=<ID>,destinationLanguage=None,translationSource=Some(Google),feature=None,timeout=None,onlyCached=None/translation/service/translateTweet`
  → `{"translation": "…", "entities": {"urls": […], "user_mentions": […], "hashtags": […], "symbols": […], "media": […]},
  "translationState": "Success", "sourceLanguage": "en", "localizedSourceLanguage": "英語", "destinationLanguage": "ja",
  "translationSource": "Google"}`.
- `GET /v2/user/translate?id=ID` → REST `GET
  /i/api/1.1/strato/column/None/profileUserId=<ID>,destinationLanguage=None,translationSource=Some(Google)/translation/service/translateProfile`
  → `{"profileUserId": "…", "profileTranslation": {"translation": "…", "language": "ja", "entities": {…},
  "sourceLanguage": "en", "localizedSourceLanguage": "英語", "translationSource": "Google"}}`.
- The path (with its commas, `=` and parentheses, exactly as written, not percent-encoded) is also the path used for
  the transaction id.
- `normalize.normalize_translation(data)` → the Translation object of api-v2.md §4, or `None` when there is no
  non-empty `translation` (also when `translationState` is present and not `"Success"`). It accepts both shapes
  (top level, or under `profileTranslation`). Text and entities follow the text rules of §6.1 (whole text as range;
  media entities emit nothing). `None` → the route answers `RelayError(404, "not_found", "翻訳できませんでした。")`.
- `translatable` (Tweet): the final `text` is not empty and (`is_translatable` of the tweet result is true, or
  `legacy.lang` is none of `ja`, `und`, `zxx`, `qme`, `qht`, `qam`, `qct`, `qst`, `art`, empty).
  `bio_translatable` (full user): `bio` not empty and (`is_profile_translatable` is true, or
  `profile_description_language` is set and none of those codes).
