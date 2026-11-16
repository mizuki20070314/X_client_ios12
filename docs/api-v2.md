# Relay API v2 (contract between the CGI and the iOS app)

This is the single source of truth for the JSON that the Python CGI (`sakura/`) returns and the iOS app (`ios/`)
reads. The CGI talks to X's web GraphQL/REST API and converts X's (frequently changing) JSON into the stable shapes
below, so that a change on X's side is fixed on the server without rebuilding the app.

## 1. Transport

- Base: `<relay base URL>/v2/...` (for example `https://example.sakura.ne.jp/xclient/v2/home`).
- Authentication: header `X-Relay-Key: <CGI key>` (the app also sends `Authorization: Bearer <CGI key>`; some hosts
  strip `Authorization`, so `X-Relay-Key` is the one that counts). Optional header `X-Profile-Name: <profile>`.
- `GET` endpoints take their parameters in the query string. `POST` endpoints take a JSON object body
  (`Content-Type: application/json`).
- Responses are `application/json; charset=utf-8`, never cached (`Cache-Control: no-store`), and gzip-compressed when
  the request has `Accept-Encoding: gzip`.
- Unknown keys must be ignored by the app; the server may add keys. Keys documented as nullable are always present
  (value `null`), so the app can tell "absent" from "not sent" only by `null`.

### Errors

Any non-2xx answer of a `/v2/` route has this body:

```json
{"error": {"code": "rate_limited", "message": "…Japanese text for the user…", "x_code": 88, "retry_after": 600}}
```

| HTTP | `code`          | meaning |
|------|-----------------|---------|
| 400  | `bad_request`   | a parameter is missing or malformed |
| 401  | `unauthorized`  | the CGI key is missing or wrong |
| 403  | `x_auth`        | X rejected the stored login session (cookies expired / account locked) |
| 404  | `not_found`     | unknown route, or X says the post/user does not exist |
| 429  | `rate_limited`  | X rate limit; `retry_after` = seconds until the window resets (may be null) |
| 502  | `x_error`       | any other failure reported by X, or X could not be reached |
| 503  | `unavailable`   | the server is not set up (no config, missing dependency) |
| 500  | `internal`      | bug in the CGI |

`x_code` is X's numeric error code when there is one, else `null`. `retry_after` is `null` unless rate limited.

The older routes (`/healthz`, `/profiles`, `/requests.ndjson`, `/i/api/graphql/...`) keep their old error body
`{"error": "text"}`.

## 2. Objects

All ids are strings. All times are integers: seconds since the Unix epoch (UTC). Counts are integers.
Text offsets are **UTF-16 code units** (what `NSString`/`NSRange` use), half-open `[s, e)`.

### 2.1 User

```json
{
  "id": "1800000000000000001",
  "name": "Display Name",
  "handle": "screen_name",
  "avatar": "https://pbs.twimg.com/profile_images/123/abc_normal.jpg",
  "verified": null,
  "square": false,
  "protected": false,
  "following": false,
  "followed_by": false,
  "blocking": false,
  "muting": false,
  "label": null
}
```

- `handle` has no `@`.
- `avatar`: URL of the 48 px `_normal` image or `null`. The app derives other sizes by replacing `_normal`
  (`_bigger` 73 px, `_200x200`, `_400x400`).
- `verified`: `"blue"`, `"business"` (gold badge), `"government"` (grey badge) or `null`.
- `square`: the avatar is shown as a rounded square (business accounts) instead of a circle.
- `following`: the logged-in account follows this user. `followed_by`: this user follows the logged-in account.
- `label`: `null` or `{"text": "OpenAI", "badge": "https://…/x_bigger.jpg"}` (affiliation badge shown after the name).

A **full user** (profile screens, `/v2/me`, `/v2/user`, items of kind `user`) has all of the above plus:

```json
{
  "banner": "https://pbs.twimg.com/profile_banners/123/1700000000",
  "bio": "plain text of the profile description",
  "bio_entities": [{"s": 0, "e": 8, "k": "mention", "v": "demo_team"}],
  "location": "Tokyo",
  "url": {"display": "example.com", "expanded": "https://example.com/"},
  "joined": 1653520380,
  "followers": 8393,
  "friends": 5745,
  "tweets": 44410,
  "media_count": 7627,
  "likes_count": 94149,
  "pinned_ids": ["1900000000000000009"],
  "blocked_by": false,
  "follow_request_sent": false
}
```

- `banner`, `url`, `joined` may be `null`. `friends` is the number of accounts this user follows.
- The app appends `/600x200` or `/1500x500` to `banner`.

### 2.2 Entity

```json
{"s": 12, "e": 35, "k": "url", "v": "https://example.com/page"}
```

`k` is one of:

| `k`        | visible text in `[s,e)`      | `v` |
|------------|------------------------------|-----|
| `url`      | the short display form (`example.com/pa…`) | the full destination URL |
| `mention`  | `@name`                      | the handle without `@` |
| `hashtag`  | `#tag`                       | the tag without `#` |
| `cashtag`  | `$SYM`                       | the symbol without `$` |

Entities are sorted by `s` and never overlap.

### 2.3 Media

```json
{
  "type": "photo",
  "url": "https://pbs.twimg.com/media/AbCdEfGhIjKlMnO.jpg",
  "w": 1164,
  "h": 2048,
  "alt": null,
  "video": null
}
```

- `type`: `"photo"`, `"video"` or `"gif"` (X's `animated_gif`: a short looping silent MP4).
- `url`: for photos the image; for video/gif the poster frame. For `pbs.twimg.com/media/<key>.<ext>` URLs the app
  asks for a size with `https://pbs.twimg.com/media/<key>?format=<ext>&name=small|medium|large` (680 / 1200 / 2048 px).
- `w`, `h`: original pixel size, `0` when unknown.
- `video` (only for `video`/`gif`, else `null`):
  `{"mp4": "https://video.twimg.com/…/720x720/x.mp4", "hls": "https://video.twimg.com/…/x.m3u8", "duration_ms": 35134, "aspect": [16, 9]}`.
  `mp4` is one progressive file of moderate bitrate (may be `null`), `hls` the adaptive playlist (may be `null`).

### 2.4 Card

```json
{
  "type": "summary_large_image",
  "url": "https://www.dsogaming.com/news/…",
  "domain": "dsogaming.com",
  "title": "Gran Turismo Sport Unofficial PC Port Available for Download",
  "description": "Thanks to the rise of …",
  "image": {"url": "https://pbs.twimg.com/card_img/…?format=jpg&name=800x419", "w": 800, "h": 419},
  "poll": null
}
```

- `type`: `"summary"` (small thumbnail on the left), `"summary_large_image"`, `"player"` (shown like
  `summary_large_image` with a play mark) or `"poll"`.
- `image` may be `null`.
- `poll` (only for `type == "poll"`, else `null`):
  `{"choices": [{"label": "Yes", "count": 10}, {"label": "No", "count": 5}], "total": 15, "ends_at": 1794800000, "final": false}`.
  For a poll, `url`, `domain`, `title`, `description` are empty strings and `image` is `null`.

### 2.5 Tweet

```json
{
  "id": "1900000000000000001",
  "user": { "…": "User" },
  "text": "ふむ",
  "entities": [],
  "long": false,
  "created_at": 1794800000,
  "reply_count": 4,
  "retweet_count": 112,
  "like_count": 1272,
  "quote_count": 8,
  "bookmark_count": 215,
  "view_count": 134034,
  "liked": false,
  "retweeted": false,
  "bookmarked": false,
  "media": [],
  "quote": null,
  "quote_unavailable": null,
  "card": null,
  "reply_to": null,
  "conversation_id": "1900000000000000001",
  "retweeted_by": null,
  "retweet_id": null,
  "lang": "ja",
  "sensitive": false,
  "source": null,
  "edited": false,
  "place": null,
  "reply_limited": false
}
```

- `text` is ready to display: HTML entities are decoded, `t.co` links are replaced by their display form, the
  attached-media link, the leading `@mentions` of a reply and a trailing link that only repeats the card or the
  quoted post are removed. `entities` refer to this text.
- `long`: a long ("note") post. `text` is the whole text; timelines show the first part with a "さらに表示" link.
- `view_count` may be `null` (no view counter).
- `quote`: a Tweet whose own `quote` is always `null` (one level only), or `null`.
- `quote_unavailable`: when the post quotes something that cannot be shown, the notice to display in the quote box
  (for example "このポストは表示できません。"); otherwise `null`.
- `reply_to`: `null`, or `{"id": "1900000000000000002", "handles": ["hanako_demo"]}`. `handles[0]` is the author of
  the post replied to; further entries are the other accounts addressed by the hidden leading mentions.
- `retweeted_by` / `retweet_id`: set when the timeline entry is a repost. Then every other field (id, user, text,
  counts, …) describes the **original** post, `retweeted_by` is the reposting user and `retweet_id` the id of the
  repost. Both are `null` otherwise.
- `source`: the client name (`"Twitter for Android"`) when X sends it, else `null`.
- `place`: place name (`"東京 世田谷区"`) or `null`.
- `reply_limited`: the author restricted who can reply.

### 2.6 Timeline

Every list endpoint answers:

```json
{"items": [ … ], "top": "cursor or null", "bottom": "cursor or null"}
```

- `bottom`: pass it back as `cursor` to get the next (older) page; `null` means there is no further page.
- `top`: cursor for newer entries (the app normally just reloads the first page instead).
- The app drops an item whose post id it already shows.

Each item is an object with a discriminator `t`:

| `t`            | shape |
|----------------|-------|
| `tweet`        | `{"t":"tweet","tweet":Tweet,"context":Context or null,"above":false,"below":false,"focal":false}` |
| `more`         | `{"t":"more","cursor":"…","label":"返信をさらに表示"}` — a "show more" row; the app loads that cursor from the same endpoint and replaces the row with the result |
| `header`       | `{"t":"header","text":"もっと見つける"}` — a section title |
| `tombstone`    | `{"t":"tombstone","text":"このポストは削除されました。","above":false,"below":false}` — placeholder for an unavailable post |
| `user`         | `{"t":"user","user":FullUser}` |
| `notification` | see 2.7 |
| `trend`        | see 2.8 |

- `above` / `below`: draw the conversation line above / below the avatar (the post is connected to the previous /
  next row).
- `focal`: only in `/v2/tweet`: the post that was asked for (shown in the large layout).
- `Context`: `{"k": "pin", "text": "固定"}` or `{"k": "text", "text": "…"}` — a small grey line above the post.
  (Reposts are not a context: the app builds "…さんがリポスト" from `retweeted_by`.)

Unknown `t` values must be skipped by the app.

### 2.7 Notification item

```json
{
  "t": "notification",
  "id": "notification-demo-1",
  "icon": "star",
  "text": "山田 太郎さんからの最新のポスト",
  "bold": [[0, 7]],
  "users": [ {"…": "User"} ],
  "tweet": null,
  "time": 1794277168,
  "url": "https://twitter.com/taro_demo/status/1900000000000000003"
}
```

- `icon`: `"heart"`, `"repost"`, `"person"`, `"star"`, `"bell"`, `"reply"`, `"logo"`, `"alert"` (anything else is
  shown as `"bell"`).
- `bold`: UTF-16 ranges of `text` to show in bold.
- `users`: up to 8 users whose avatars are shown. `tweet`: the post the notification is about, or `null`.
- `time` and `url` may be `null`.

Replies and mentions arrive as ordinary `tweet` items in the notification timelines.

### 2.8 Trend item

```json
{"t": "trend", "name": "デモフェス", "context": "エンターテインメント · トレンド", "meta": "1.2万件のポスト", "query": "デモフェス", "rank": null}
```

`context`, `meta`, `rank` may be `null`. `query` is what to search for when the row is tapped.

## 3. Endpoints

### 3.1 Read

| Route | Parameters | Answer |
|-------|------------|--------|
| `GET /v2/me` | — | `{"user": FullUser, "badges": {"notifications": 5, "messages": 0}}` |
| `GET /v2/badges` | — | `{"notifications": 5, "messages": 0}` |
| `GET /v2/home` | `tab` = `foryou` (default) \| `following`; `cursor` | Timeline |
| `GET /v2/tweet` | `id` (required); `cursor` | Timeline; exactly one `tweet` item has `focal: true` on the first page |
| `GET /v2/search` | `q` (required); `mode` = `top` (default) \| `latest` \| `people` \| `media`; `cursor` | Timeline (`people`: `user` items) |
| `GET /v2/user` | `handle` or `id` (one required) | `{"user": FullUser}` |
| `GET /v2/user/timeline` | `id` (required); `tab` = `posts` (default) \| `replies` \| `media` \| `likes`; `cursor` | Timeline |
| `GET /v2/user/follows` | `id` (required); `kind` = `following` (default) \| `followers`; `cursor` | Timeline of `user` items |
| `GET /v2/notifications` | `tab` = `all` (default) \| `mentions`; `cursor` | Timeline |
| `GET /v2/bookmarks` | `cursor` | Timeline |
| `GET /v2/explore` | `tab` (id from `tabs`, default: the first) | `{"tabs": [{"id": "for_you", "label": "話題を検索"}, …], "tab": "for_you", "items": [ … ], "top": null, "bottom": null}` |

`/v2/tweet` item order on the first page: the posts the focal post replies to (oldest first, `below: true`), the focal
post, then reply threads (each thread = consecutive items joined by `above`/`below`), optional `more` rows, optional
`header` + related posts. Later pages (with `cursor`) contain only further replies.

### 3.2 Write

All take a JSON body and answer `{"ok": true}` plus the keys listed.

| Route | Body | Extra answer keys |
|-------|------|-------------------|
| `POST /v2/tweet/create` | `{"text": "…", "reply_to": "id" or null, "quote": "id" or null, "media_ids": []}` | `"tweet": Tweet or null` (the new post) |
| `POST /v2/tweet/delete` | `{"id": "…"}` | — |
| `POST /v2/tweet/like` | `{"id": "…", "on": true}` | — |
| `POST /v2/tweet/retweet` | `{"id": "…", "on": true}` | — |
| `POST /v2/tweet/bookmark` | `{"id": "…", "on": true}` | — |
| `POST /v2/user/follow` | `{"id": "user id", "on": true}` | — |
| `POST /v2/user/mute` | `{"id": "user id", "on": true}` | — |
| `POST /v2/user/block` | `{"id": "user id", "on": true}` | — |

- `on: false` undoes the action. Repeating an action that is already in effect is a success (`{"ok": true}`).
- `id` of like/retweet/bookmark is always the id of the original post (`Tweet.id`), also to undo a repost.
- `text`: 1…4000 characters after trimming; X decides the real limit (280 weighted) and its refusal is passed on as
  `x_error`.

### 3.3 Kept from v1

| Route | Answer |
|-------|--------|
| `GET /healthz` | `{"status": "ok"}` (no key needed) |
| `GET /profiles` | `{"profiles": ["account1"]}` (used by the app's connection test) |
