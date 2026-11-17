"""The /v2 endpoints of api-v2.md section 3: parameter validation and the X requests of server-design section 4.

Handlers return the payload dict; dispatch returns (200, payload). Errors are RelayError. The "already in that
state" codes of X are a success for the write routes (server-design section 3.8).
"""

import re

from xrelay_app.errors import RelayError

ALREADY_DONE_CODES = frozenset([139, 327, 144, 405])
PAGE = 20
BADGE_PATH = "/i/api/2/badge_count/badge_count.json"
# REST paths of server-design section 9. The commas, "=" and parentheses belong to the path (there is no query
# string): they go out exactly as written, and the same string is the path of the transaction id.
TRANSLATE_TWEET_PATH = ("/i/api/1.1/strato/column/None/tweetId={},destinationLanguage=None,"
                        "translationSource=Some(Google),feature=None,timeout=None,onlyCached=None"
                        "/translation/service/translateTweet")
TRANSLATE_PROFILE_PATH = ("/i/api/1.1/strato/column/None/profileUserId={},destinationLanguage=None,"
                          "translationSource=Some(Google)/translation/service/translateProfile")
ID_RE = re.compile(r"[0-9]{1,25}")
HANDLE_RE = re.compile(r"[A-Za-z0-9_]{1,20}")
TAB_RE = re.compile(r"[A-Za-z0-9_-]{1,40}")
TIMELINE_ID_RE = re.compile(r"[A-Za-z0-9+/=_-]{1,200}")
PRODUCTS = {"top": "Top", "latest": "Latest", "people": "People", "media": "Media"}
FOLLOW_FORM = [
    ("include_profile_interstitial_type", "1"),
    ("include_blocking", "1"),
    ("include_blocked_by", "1"),
    ("include_followed_by", "1"),
    ("include_want_retweets", "1"),
    ("include_mute_edge", "1"),
    ("include_can_dm", "1"),
    ("include_can_media_tag", "1"),
    ("include_ext_is_blue_verified", "1"),
    ("include_ext_verified_type", "1"),
    ("include_ext_profile_image_shape", "1"),
    ("skip_status", "1"),
]


def dispatch(request, client, normalizer=None):
    """(200, payload) for a /v2 request; RelayError for unknown routes, bad parameters and X failures."""
    if normalizer is None:
        # imported here so that tests can pass a fake and never load the real module
        from xrelay_app import normalize as normalizer
    handler = ROUTES.get((request.method, request.path))
    if handler is None:
        if any(path == request.path for _, path in ROUTES):
            raise RelayError(405, "bad_request", "このAPIではそのメソッドは使えません。")
        raise RelayError(404, "not_found", "存在しないAPIです。")
    return 200, handler(request, client, normalizer)


# ---- parameter helpers -------------------------------------------------------------------------

def _bad(message):
    return RelayError(400, "bad_request", message)


def _id_value(value, name):
    if not isinstance(value, str) or ID_RE.fullmatch(value) is None:
        raise _bad("{} は数字だけで指定してください。".format(name))
    return value


def _id_param(request, name, required):
    value = request.param(name)
    if value is None:
        if required:
            raise _bad("{} を指定してください。".format(name))
        return None
    return _id_value(value, name)


def _handle_value(value):
    # a leading "@" is allowed and stripped
    name = value[1:] if value.startswith("@") else value
    if HANDLE_RE.fullmatch(name) is None:
        raise _bad("ハンドルは英数字とアンダースコアだけで、20文字以内にしてください。")
    return name


def _cursor(request):
    value = request.param("cursor")
    if value is None:
        return None
    if not 1 <= len(value) <= 2000:
        raise _bad("cursor の長さが正しくありません。")
    return value


def _with_cursor(variables, cursor):
    if cursor is not None:
        variables["cursor"] = cursor
    return variables


def _choice(value, options, default):
    if value is None:
        return default
    if value not in options:
        raise _bad("指定できない値です。")
    return value


def _query_text(request):
    value = request.param("q")
    if value is None:
        raise _bad("q を指定してください。")
    query = value.strip()
    if not 1 <= len(query) <= 500:
        raise _bad("q は1〜500文字で指定してください。")
    return query


def _body_id(body, key, required=True):
    value = body.get(key)
    if value is None:
        if required:
            raise _bad("{} を指定してください。".format(key))
        return None
    return _id_value(value, key)


def _body_on(body):
    value = body.get("on")
    if not isinstance(value, bool):
        raise _bad("on は true か false で指定してください。")
    return value


def _body_text(body):
    value = body.get("text")
    if not isinstance(value, str):
        raise _bad("text を指定してください。")
    text = value.strip()
    if not 1 <= len(text) <= 4000:
        raise _bad("text は1〜4000文字で指定してください。")
    return text


def _body_media_ids(body):
    value = body.get("media_ids")
    if value is None:
        return []
    if not isinstance(value, list):
        raise _bad("media_ids は配列で指定してください。")
    return [_id_value(item, "media_ids") for item in value]


def _write(call):
    """The answer of a write call, or None when X says the state is already the requested one."""
    try:
        return call()
    except RelayError as error:
        if error.x_code in ALREADY_DONE_CODES:
            return None
        raise


def _count(answer, key):
    value = answer.get(key) if isinstance(answer, dict) else None
    if isinstance(value, int) and not isinstance(value, bool) and value >= 0:
        return value
    return 0


def _dig(value, *keys):
    for key in keys:
        if not isinstance(value, dict):
            return None
        value = value.get(key)
    return value


# ---- read routes -------------------------------------------------------------------------------

def _me(request, client, normalizer):
    viewer = client.graphql("Viewer", {"withCommunitiesMemberships": True},
                            field_toggles={"isDelegate": False, "withAuxiliaryUserLabels": True})
    user = normalizer.normalize_user_response(viewer)
    if user is None:
        raise RelayError(502, "x_error", "アカウント情報を読み取れませんでした。")
    # the badges are secondary: a failed badge request answers zeros, the route still succeeds
    return {"user": user, "badges": _badges_of(client, required=False)}


def _badges(request, client, normalizer):
    return _badges_of(client, required=True)


def _badges_of(client, required):
    try:
        answer = client.rest("GET", BADGE_PATH, params={"supports_ntab_urt": "1"})
    except RelayError:
        if required:
            raise
        return {"notifications": 0, "messages": 0}
    return {"notifications": _count(answer, "ntab_unread_count"),
            "messages": _count(answer, "dm_unread_count")}


def _home(request, client, normalizer):
    tab = _choice(request.param("tab"), ("foryou", "following"), "foryou")
    cursor = _cursor(request)
    variables = {"count": PAGE, "includePromotedContent": True, "withCommunity": True}
    name = "HomeTimeline"
    if tab == "following":
        name = "HomeLatestTimeline"
        variables["latestControlAvailable"] = True
    if cursor is None:
        variables["requestContext"] = "launch"
    _with_cursor(variables, cursor)
    answer = client.graphql(name, variables, field_toggles={"withPayments": False})
    return normalizer.normalize_timeline(answer)


def _tweet_detail(request, client, normalizer):
    focal_id = _id_param(request, "id", required=True)
    cursor = _cursor(request)
    variables = {
        "focalTweetId": focal_id,
        "with_rux_injections": False,
        "rankingMode": "Relevance",
        "includePromotedContent": True,
        "withCommunity": True,
        "withQuickPromoteEligibilityTweetFields": True,
        "withBirdwatchNotes": True,
        "withVoice": True,
    }
    if cursor is not None:
        variables["referrer"] = "tweet"
    _with_cursor(variables, cursor)
    answer = client.graphql("TweetDetail", variables, field_toggles={
        "withArticleRichContentState": True,
        "withArticlePlainText": False,
        "withGrokAnalyze": False,
        "withDisallowedReplyControls": False,
    })
    if cursor is None:
        return normalizer.normalize_timeline(answer, focal_id=focal_id)
    return normalizer.normalize_timeline(answer)  # later pages are only more replies


def _search(request, client, normalizer):
    query = _query_text(request)
    mode = _choice(request.param("mode"), tuple(PRODUCTS), "top")
    variables = {"rawQuery": query, "count": PAGE, "querySource": "typed_query",
                 "product": PRODUCTS[mode], "withGrokTranslatedBio": False}
    _with_cursor(variables, _cursor(request))
    return normalizer.normalize_timeline(client.graphql("SearchTimeline", variables))


def _user(request, client, normalizer):
    handle = request.param("handle")
    user_id = request.param("id")
    if (handle is None) == (user_id is None):
        raise _bad("handle か id のどちらか一方を指定してください。")
    toggles = {"withPayments": False, "withAuxiliaryUserLabels": True}
    if handle is not None:
        answer = client.graphql("UserByScreenName",
                                {"screen_name": _handle_value(handle), "withGrokTranslatedBio": False},
                                field_toggles=toggles)
    else:
        answer = client.graphql("UserByRestId", {"userId": _id_value(user_id, "id")}, field_toggles=toggles)
    user = normalizer.normalize_user_response(answer)
    if user is None:
        raise RelayError(404, "not_found", "ユーザーが見つかりませんでした。")
    return {"user": user}


def _user_timeline(request, client, normalizer):
    user_id = _id_param(request, "id", required=True)
    tab = _choice(request.param("tab"), ("posts", "replies", "media", "likes"), "posts")
    if tab == "posts":
        name = "UserTweets"
        variables = {"userId": user_id, "count": PAGE, "includePromotedContent": True,
                     "withQuickPromoteEligibilityTweetFields": True, "withVoice": True}
    elif tab == "replies":
        name = "UserTweetsAndReplies"
        variables = {"userId": user_id, "count": PAGE, "includePromotedContent": True,
                     "withCommunity": True, "withVoice": True}
    else:
        name = "UserMedia" if tab == "media" else "Likes"
        variables = {"userId": user_id, "count": PAGE, "includePromotedContent": False,
                     "withClientEventToken": False, "withBirdwatchNotes": False, "withVoice": True}
    _with_cursor(variables, _cursor(request))
    answer = client.graphql(name, variables, field_toggles={"withArticlePlainText": False})
    return normalizer.normalize_timeline(answer)


def _user_follows(request, client, normalizer):
    user_id = _id_param(request, "id", required=True)
    kind = _choice(request.param("kind"), ("following", "followers"), "following")
    variables = {"userId": user_id, "count": PAGE, "includePromotedContent": False,
                 "withGrokTranslatedBio": False}
    _with_cursor(variables, _cursor(request))
    name = "Following" if kind == "following" else "Followers"
    return normalizer.normalize_timeline(client.graphql(name, variables))


def _notifications(request, client, normalizer):
    tab = _choice(request.param("tab"), ("all", "mentions"), "all")
    variables = {"timeline_type": "All" if tab == "all" else "Mentions", "count": PAGE}
    _with_cursor(variables, _cursor(request))
    return normalizer.normalize_timeline(client.graphql("NotificationsTimeline", variables))


def _bookmarks(request, client, normalizer):
    variables = {"count": PAGE, "includePromotedContent": True}
    _with_cursor(variables, _cursor(request))
    return normalizer.normalize_timeline(client.graphql("Bookmarks", variables))


def _explore(request, client, normalizer):
    tab = request.param("tab")
    if tab is not None and TAB_RE.fullmatch(tab) is None:
        raise _bad("tab が正しくありません。")
    first = client.graphql("ExplorePage", {"cursor": ""})
    page = normalizer.normalize_explore(first)
    if tab is None or tab == page.get("tab"):
        return page
    timeline_id = _explore_timeline_id(first, tab)
    second = client.graphql("GenericTimelineById", {"timelineId": timeline_id, "count": PAGE,
                                                    "withQuickPromoteEligibilityTweetFields": True})
    timeline = normalizer.normalize_timeline(second)
    return {"tabs": page.get("tabs"), "tab": tab, "items": timeline.get("items"),
            "top": timeline.get("top"), "bottom": timeline.get("bottom")}


def _explore_timeline_id(answer, tab):
    timelines = _dig(answer, "data", "explore_page", "body", "timelines")
    if not isinstance(timelines, list):
        timelines = []
    for entry in timelines:
        if isinstance(entry, dict) and entry.get("id") == tab:
            timeline_id = _dig(entry, "timeline", "id")
            if isinstance(timeline_id, str) and TIMELINE_ID_RE.fullmatch(timeline_id):
                return timeline_id
    raise _bad("指定されたタブはありません。")


# ---- translation (server-design section 9) ------------------------------------------------------

def _tweet_translate(request, client, normalizer):
    tweet_id = _id_param(request, "id", required=True)
    return _translation(normalizer, client.rest("GET", TRANSLATE_TWEET_PATH.format(tweet_id)))


def _user_translate(request, client, normalizer):
    user_id = _id_param(request, "id", required=True)
    return _translation(normalizer, client.rest("GET", TRANSLATE_PROFILE_PATH.format(user_id)))


def _translation(normalizer, answer):
    translation = normalizer.normalize_translation(answer)
    if translation is None:
        raise RelayError(404, "not_found", "翻訳できませんでした。")
    return translation


# ---- write routes ------------------------------------------------------------------------------

def _graphql_write(client, name, variables):
    _write(lambda: client.graphql(name, variables))
    return {"ok": True}


def _rest_write(client, path, form):
    _write(lambda: client.rest("POST", path, form=form))
    return {"ok": True}


def _tweet_create(request, client, normalizer):
    body = request.json()
    text = _body_text(body)
    reply_to = _body_id(body, "reply_to", required=False)
    quote = _body_id(body, "quote", required=False)
    media_ids = _body_media_ids(body)
    variables = {
        "tweet_text": text,
        "dark_request": False,
        "media": {"media_entities": [{"media_id": item, "tagged_users": []} for item in media_ids],
                  "possibly_sensitive": False},
        "semantic_annotation_ids": [],
        "disallowed_reply_options": None,
    }
    if reply_to is not None:
        variables["reply"] = {"in_reply_to_tweet_id": reply_to, "exclude_reply_user_ids": []}
    if quote is not None:
        variables["attachment_url"] = "https://x.com/i/status/" + quote
    answer = _write(lambda: client.graphql("CreateTweet", variables))
    if answer is None:
        return {"ok": True, "tweet": None}
    return {"ok": True, "tweet": normalizer.normalize_created_tweet(answer)}


def _tweet_delete(request, client, normalizer):
    tweet_id = _body_id(request.json(), "id")
    return _graphql_write(client, "DeleteTweet", {"tweet_id": tweet_id, "dark_request": False})


def _tweet_like(request, client, normalizer):
    body = request.json()
    tweet_id = _body_id(body, "id")
    name = "FavoriteTweet" if _body_on(body) else "UnfavoriteTweet"
    return _graphql_write(client, name, {"tweet_id": tweet_id})


def _tweet_retweet(request, client, normalizer):
    body = request.json()
    tweet_id = _body_id(body, "id")
    if _body_on(body):
        return _graphql_write(client, "CreateRetweet", {"tweet_id": tweet_id, "dark_request": False})
    # the undo names the source post, the same id as the one given
    return _graphql_write(client, "DeleteRetweet", {"source_tweet_id": tweet_id, "dark_request": False})


def _tweet_bookmark(request, client, normalizer):
    body = request.json()
    tweet_id = _body_id(body, "id")
    name = "CreateBookmark" if _body_on(body) else "DeleteBookmark"
    return _graphql_write(client, name, {"tweet_id": tweet_id})


def _user_follow(request, client, normalizer):
    body = request.json()
    user_id = _body_id(body, "id")
    form = dict(FOLLOW_FORM)
    form["user_id"] = user_id
    path = "/i/api/1.1/friendships/create.json" if _body_on(body) else "/i/api/1.1/friendships/destroy.json"
    return _rest_write(client, path, form)


def _user_mute(request, client, normalizer):
    body = request.json()
    user_id = _body_id(body, "id")
    path = "/i/api/1.1/mutes/users/create.json" if _body_on(body) else "/i/api/1.1/mutes/users/destroy.json"
    return _rest_write(client, path, {"user_id": user_id})


def _user_block(request, client, normalizer):
    body = request.json()
    user_id = _body_id(body, "id")
    path = "/i/api/1.1/blocks/create.json" if _body_on(body) else "/i/api/1.1/blocks/destroy.json"
    return _rest_write(client, path, {"user_id": user_id})


ROUTES = {
    ("GET", "/v2/me"): _me,
    ("GET", "/v2/badges"): _badges,
    ("GET", "/v2/home"): _home,
    ("GET", "/v2/tweet"): _tweet_detail,
    ("GET", "/v2/search"): _search,
    ("GET", "/v2/user"): _user,
    ("GET", "/v2/user/timeline"): _user_timeline,
    ("GET", "/v2/user/follows"): _user_follows,
    ("GET", "/v2/notifications"): _notifications,
    ("GET", "/v2/bookmarks"): _bookmarks,
    ("GET", "/v2/explore"): _explore,
    ("GET", "/v2/tweet/translate"): _tweet_translate,
    ("GET", "/v2/user/translate"): _user_translate,
    ("POST", "/v2/tweet/create"): _tweet_create,
    ("POST", "/v2/tweet/delete"): _tweet_delete,
    ("POST", "/v2/tweet/like"): _tweet_like,
    ("POST", "/v2/tweet/retweet"): _tweet_retweet,
    ("POST", "/v2/tweet/bookmark"): _tweet_bookmark,
    ("POST", "/v2/user/follow"): _user_follow,
    ("POST", "/v2/user/mute"): _user_mute,
    ("POST", "/v2/user/block"): _user_block,
}
