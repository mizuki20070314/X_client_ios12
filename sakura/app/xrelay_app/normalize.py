"""X's web GraphQL JSON -> api-v2 JSON (docs/api-v2.md section 2).

Pure functions: no I/O, no network, no module state. Input that cannot be
understood is skipped, and the public functions answer None or an empty
result instead of raising, so one odd post never breaks a whole timeline.
The shapes of X's answers are in docs/server-design.md section 5, the
rules in section 6.
"""

import calendar
import functools
import re
from urllib.parse import parse_qs, urlsplit

from .textutil import decode_escapes, strip_tags, utf16_len


UNAVAILABLE_TEXT = "このポストは表示できません。"
DELETED_TEXT = "このポストは削除されました。"
PIN_TEXT = "固定"
MORE_TEXT = "返信をさらに表示"

# Errors that mean "this part of X's JSON has an unexpected shape".
_SOFT_ERRORS = (AttributeError, IndexError, KeyError, TypeError, ValueError)

_ICONS = {
    "heart_icon": "heart",
    "retweet_icon": "repost",
    "person_icon": "person",
    "recommendation_icon": "star",
    "milestone_icon": "star",
    "bird_icon": "logo",
    "reply_icon": "reply",
    "security_alert_icon": "alert",
    "safety_icon": "alert",
}
_MORE_CURSORS = ("ShowMoreThreads", "ShowMoreThreadsPrompt", "ShowMore")
_MONTHS = {
    "Jan": 1, "Feb": 2, "Mar": 3, "Apr": 4, "May": 5, "Jun": 6,
    "Jul": 7, "Aug": 8, "Sep": 9, "Oct": 10, "Nov": 11, "Dec": 12,
}
# Entity lists of X's JSON, with the kind they become in api-v2.
_ENTITY_FIELDS = (("urls", "url"), ("user_mentions", "mention"), ("hashtags", "hashtag"), ("symbols", "cashtag"))
# The character each mention/hashtag/cashtag must start with (ASCII and full-width).
_SIGILS = {"mention": "@＠", "hashtag": "#＃", "cashtag": "$＄"}
_CARD_IMAGE_KEYS = (
    "photo_image_full_size_large", "summary_photo_image_large", "thumbnail_image_large",
    "player_image_large", "summary_photo_image", "photo_image_full_size", "thumbnail_image",
    "player_image",
)
_POLL = re.compile(r"poll([234])choice_")
_INT = re.compile(r"-?[0-9]+")
_ISO = re.compile(r"([0-9]{4})-([0-9]{2})-([0-9]{2})[Tt ]([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.[0-9]+)?(Z|z|[+-][0-9]{2}:?[0-9]{2})?")
# "Mon Nov 16 06:48:58 +0000 2026"
_CREATED = re.compile(r"[A-Za-z]{3} ([A-Za-z]{3}) ([0-9]{1,2}) ([0-9]{2}):([0-9]{2}):([0-9]{2}) ([+-][0-9]{4}) ([0-9]{4})")


def _guard(fallback):
    """Make a public function answer fallback() instead of raising on odd input."""
    def wrap(func):
        @functools.wraps(func)
        def guarded(*args, **kwargs):
            try:
                return func(*args, **kwargs)
            except _SOFT_ERRORS:
                return fallback()
        return guarded
    return wrap


# ---------------------------------------------------------------- small helpers

def _dict(value):
    return value if isinstance(value, dict) else {}


def _list(value):
    return value if isinstance(value, list) else []


def _str(value):
    return value if isinstance(value, str) and value else None


def _id(value):
    """Ids are strings; REST answers may carry ints. None when absent."""
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return str(value)
    return _str(value)


def _is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


def _int(value, default=0):
    if isinstance(value, bool):
        return default
    if isinstance(value, int):
        return value
    if isinstance(value, str) and _INT.fullmatch(value.strip()):
        return int(value.strip())
    return default


def _maybe_int(value):
    return _int(value, None)


def _flag(value):
    return value is True


def _first(*values):
    """The first value that is present (not None); X omits or nulls fields it has moved."""
    for value in values:
        if value is not None:
            return value
    return None


def _get(node, *keys):
    for key in keys:
        if not isinstance(node, dict):
            return None
        node = node.get(key)
    return node


def _span(indices, length):
    """(start, end) of an X "indices" pair in code points, or None when it is bad."""
    if not isinstance(indices, list) or len(indices) != 2:
        return None
    start, end = indices
    if not (_is_int(start) and _is_int(end)):
        return None
    if 0 <= start < end <= length:
        return start, end
    return None


# ---------------------------------------------------------------- times

def _parse_iso(value):
    """ISO 8601 ("2026-11-17T06:48:58Z") -> epoch seconds, or None."""
    if not isinstance(value, str):
        return None
    match = _ISO.fullmatch(value.strip())
    if match is None:
        return None
    year, month, day, hour, minute, second = [int(part) for part in match.groups()[:6]]
    seconds = calendar.timegm((year, month, day, hour, minute, second, 0, 0, 0))
    zone = match.group(7)
    if zone and zone not in ("Z", "z"):
        sign = 1 if zone[0] == "+" else -1
        digits = zone[1:].replace(":", "")
        seconds -= sign * (int(digits[:2]) * 3600 + int(digits[2:]) * 60)
    return seconds


def _parse_created_at(value):
    """X's "created_at" ("Mon Nov 16 06:48:58 +0000 2026") -> epoch seconds, or None."""
    if not isinstance(value, str):
        return None
    match = _CREATED.fullmatch(value.strip())
    if match is None:
        return None
    # Parsed by hand: strptime's %a/%b depend on the locale.
    month = _MONTHS.get(match.group(1).title())
    if month is None:
        return None
    day, hour, minute, second = [int(match.group(index)) for index in (2, 3, 4, 5)]
    seconds = calendar.timegm((int(match.group(7)), month, day, hour, minute, second, 0, 0, 0))
    zone = match.group(6)
    sign = 1 if zone[0] == "+" else -1
    seconds -= sign * (int(zone[1:3]) * 3600 + int(zone[3:5]) * 60)
    return seconds


def _time_from_ms(value):
    """Notification timestamp_ms: ISO 8601 text, or milliseconds as int or digit string."""
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value // 1000
    if isinstance(value, str):
        text = value.strip()
        if re.fullmatch(r"-?[0-9]+", text):
            return int(text) // 1000
        return _parse_iso(text)
    return None


# ---------------------------------------------------------------- find_instructions

@_guard(list)
def find_instructions(data):
    """First "instructions" list in data, searched depth-first; [] when there is none."""
    # An explicit stack instead of recursion: deep input must not raise RecursionError.
    stack = [data]
    while stack:
        node = stack.pop()
        if isinstance(node, dict):
            found = node.get("instructions")
            if isinstance(found, list):
                return found
            children = list(node.values())
        elif isinstance(node, list):
            children = node
        else:
            continue
        stack.extend(reversed(children))
    return []


# ---------------------------------------------------------------- text (6.1)

def _raw_entities(source, containers, media_nodes=()):
    """X's entities as dicts with code-point spans, sorted; media links become kind "media"."""
    found = []
    for field, kind in _ENTITY_FIELDS:
        for node in _list(_dict(containers).get(field)):
            node = _dict(node)
            span = _span(node.get("indices"), len(source))
            if span is None:
                continue
            entity = {"s": span[0], "e": span[1], "kind": kind}
            if kind == "url":
                tco = _str(node.get("url"))
                expanded = _str(node.get("expanded_url")) or tco
                if expanded is None:
                    continue
                entity["tco"] = tco
                entity["expanded"] = expanded
                entity["value"] = expanded
                entity["visible"] = _str(node.get("display_url")) or expanded
            else:
                name = _str(node.get("screen_name")) if kind == "mention" else _str(node.get("text"))
                visible = source[span[0]:span[1]]
                # Offsets that do not point at the sigil would highlight the wrong text.
                if name is None or visible[:1] not in _SIGILS[kind]:
                    continue
                entity["value"] = name
            found.append(entity)
    for node in media_nodes:
        span = _span(_dict(node).get("indices"), len(source))
        if span is not None:
            found.append({"s": span[0], "e": span[1], "kind": "media"})
    found.sort(key=lambda entity: (entity["s"], entity["e"]))
    return found


def _render(source, start, end, found, decode):
    """Segments (text, entity or None) of source[start:end]; overlapping or bad entities are skipped."""
    segments = []
    pos = start
    for entity in found:
        if entity["s"] < pos or entity["e"] > end:
            continue
        if entity["s"] > pos:
            segments.append((_plain(source[pos:entity["s"]], decode), None))
        if entity["kind"] != "media":
            segments.append((entity.get("visible") or source[entity["s"]:entity["e"]], entity))
        pos = entity["e"]
    if pos < end:
        segments.append((_plain(source[pos:end], decode), None))
    return segments


def _plain(text, decode):
    return decode_escapes(text) if decode else text


def _repeats_card_or_quote(entity, card_links, quote_id):
    """True when a link at the end of the text only repeats the shown card or quoted post."""
    if entity.get("tco") is not None and entity["tco"] in card_links:
        return True
    if quote_id and entity["kind"] == "url":
        return re.search(r"/status/%s(?![0-9])" % quote_id, entity.get("expanded") or "") is not None
    return False


def _assemble(segments, card_links=(), quote_id=None):
    """Join the segments into (text, entities) with UTF-16 offsets (6.1 steps 4 and 5)."""
    # Step 4: drop a link that ends the text and only repeats the card or the quoted post.
    last = None
    for index in range(len(segments) - 1, -1, -1):
        text, entity = segments[index]
        if entity is not None:
            last = index
            break
        if text.strip():
            break
    if last is not None and segments[last][1]["kind"] == "url" and _repeats_card_or_quote(segments[last][1], card_links, quote_id):
        del segments[last:]

    parts = []
    entities = []
    pos = 0
    for text, entity in segments:
        width = utf16_len(text)
        if entity is not None:
            entities.append({"s": pos, "e": pos + width, "k": entity["kind"], "v": entity["value"]})
        parts.append(text)
        pos += width
    # Only trailing whitespace goes: stripping the start would shift every offset.
    text = "".join(parts).rstrip()
    limit = utf16_len(text)
    return text, [entity for entity in entities if entity["e"] <= limit]


def _note_text(tweet):
    text = _get(tweet, "note_tweet", "note_tweet_results", "result", "text")
    return text if isinstance(text, str) and text else None


def _display_range(legacy, length):
    value = legacy.get("display_text_range")
    return _span(value, length)


def _tweet_text(tweet, legacy, reply, card_links, quote_id):
    """(text, entities) as shown: decoded, t.co replaced by display URLs (6.1)."""
    full = legacy.get("full_text") if isinstance(legacy.get("full_text"), str) else ""
    display = _display_range(legacy, len(full))
    note = _note_text(tweet)
    if note is not None:
        # Long post: the note holds the whole text; the media stays in legacy.
        source = note
        start, end = 0, len(note)
        if reply and display is not None and display[0] > 0:
            # The note repeats the leading @mentions that the display range hides.
            prefix = full[:display[0]]
            if prefix and note.startswith(prefix):
                start = len(prefix)
        containers = _get(tweet, "note_tweet", "note_tweet_results", "result", "entity_set")
        found = _raw_entities(source, containers)
    else:
        source = full
        start, end = display if display is not None else (0, len(full))
        containers = legacy.get("entities")
        media = _list(_get(legacy, "extended_entities", "media")) or _list(_get(legacy, "entities", "media"))
        found = _raw_entities(source, containers, media)
    segments = _render(source, start, end, found, decode=True)
    return _assemble(segments, card_links, quote_id)


# ---------------------------------------------------------------- cards (5.2, 2.4)

def _binding_values(card_legacy):
    """binding_values as {key: value dict}; X sends a list of {key, value}."""
    raw = card_legacy.get("binding_values")
    values = {}
    if isinstance(raw, list):
        for binding in raw:
            binding = _dict(binding)
            key = _str(binding.get("key"))
            if key:
                values[key] = _dict(binding.get("value"))
    elif isinstance(raw, dict):
        for key, binding in raw.items():
            binding = _dict(binding)
            values[key] = _dict(binding.get("value")) if "value" in binding else binding
    return values


def _bv_str(values, key):
    return _str(_dict(values.get(key)).get("string_value"))


def _bv_flag(values, key):
    return _dict(values.get(key)).get("boolean_value") is True


def _card_image(values, keys):
    for key in keys:
        image = _dict(_dict(values.get(key)).get("image_value"))
        url = _str(image.get("url"))
        if url:
            return {"url": url, "w": _int(image.get("width")), "h": _int(image.get("height"))}
    return None


def _strip_www(domain):
    return domain[4:] if domain.startswith("www.") else domain


def _host(url):
    try:
        return urlsplit(url).hostname or ""
    except ValueError:
        return ""


def _poll_card(values, match):
    count = int(match.group(1))
    choices = []
    for index in range(1, count + 1):
        choices.append({
            "label": _bv_str(values, "choice%d_label" % index) or "",
            "count": _int(_bv_str(values, "choice%d_count" % index)),
        })
    poll = {
        "choices": choices,
        "total": sum(choice["count"] for choice in choices),
        "ends_at": _parse_iso(_bv_str(values, "end_datetime_utc")) or 0,
        "final": _bv_flag(values, "counts_are_final"),
    }
    return {"type": "poll", "url": "", "domain": "", "title": "", "description": "", "image": None, "poll": poll}


def _card(card_node, legacy):
    """(card or None, t.co links that the shown card already repeats). Other card types are not shown."""
    card_legacy = _dict(_dict(card_node).get("legacy"))
    name = _str(card_legacy.get("name"))
    if name is None:
        return None, set()
    # Names can carry a prefix such as "3691233323:audiospace"; the last part is the type.
    name = name.split(":")[-1]
    values = _binding_values(card_legacy)
    card_url = _bv_str(values, "card_url")
    links = set(link for link in (card_url, _str(card_legacy.get("url"))) if link)
    poll = _POLL.match(name)
    if poll:
        return _poll_card(values, poll), links
    if name not in ("summary", "summary_large_image", "player"):
        return None, set()

    # The destination is the expanded form of the card's t.co link when the post has one.
    destination = None
    for node in _list(_get(legacy, "entities", "urls")):
        node = _dict(node)
        expanded = _str(node.get("expanded_url"))
        if expanded and _str(node.get("url")) in links:
            destination = expanded
            break
    if destination is None:
        destination = card_url or _str(card_legacy.get("url")) or ""

    domain = _bv_str(values, "vanity_url") or _bv_str(values, "domain") or _host(destination)
    if name == "summary":
        preferred = ("thumbnail_image_large",)
    elif name == "player":
        preferred = ("player_image_large",)
    else:
        preferred = ()
    card = {
        "type": name,
        "url": destination,
        "domain": _strip_www(domain),
        "title": _bv_str(values, "title") or "",
        "description": _bv_str(values, "description") or "",
        "image": _card_image(values, preferred + _CARD_IMAGE_KEYS),
        "poll": None,
    }
    return card, links


# ---------------------------------------------------------------- media (2.3, 6.2)

_MEDIA_TYPES = {"photo": "photo", "video": "video", "animated_gif": "gif"}


def _video(node, kind):
    info = _dict(node.get("video_info"))
    variants = [_dict(variant) for variant in _list(info.get("variants"))]
    mp4 = [variant for variant in variants
           if variant.get("content_type") == "video/mp4" and _str(variant.get("url"))]
    hls = [variant for variant in variants
           if variant.get("content_type") == "application/x-mpegURL" and _str(variant.get("url"))]
    mp4_url = None
    if mp4:
        if kind == "gif":
            # An animated gif has a single MP4.
            mp4_url = mp4[0]["url"]
        else:
            # The best MP4 that is not above 1.3 Mbps; when all are above, the smallest.
            fitting = [variant for variant in mp4 if _int(variant.get("bitrate")) <= 1300000]
            if fitting:
                mp4_url = max(fitting, key=lambda variant: _int(variant.get("bitrate")))["url"]
            else:
                mp4_url = min(mp4, key=lambda variant: _int(variant.get("bitrate")))["url"]
    aspect = _list(info.get("aspect_ratio"))
    if len(aspect) == 2 and all(_is_int(part) for part in aspect):
        ratio = [aspect[0], aspect[1]]
    else:
        ratio = [0, 0]
    return {
        "mp4": mp4_url,
        "hls": hls[0]["url"] if hls else None,
        "duration_ms": _int(info.get("duration_millis")),
        "aspect": ratio,
    }


def _media(legacy):
    nodes = _list(_get(legacy, "extended_entities", "media")) or _list(_get(legacy, "entities", "media"))
    media = []
    for node in nodes:
        node = _dict(node)
        kind = _MEDIA_TYPES.get(node.get("type"))
        url = _str(node.get("media_url_https"))
        if kind is None or url is None:
            continue
        original = _dict(node.get("original_info"))
        media.append({
            "type": kind,
            "url": url,
            "w": _int(original.get("width")),
            "h": _int(original.get("height")),
            "alt": _str(node.get("ext_alt_text")),
            "video": _video(node, kind) if kind in ("video", "gif") else None,
        })
    return media


# ---------------------------------------------------------------- users (5.3, 2.1)

def _profile_text(user, legacy):
    """(bio text, bio entities): t.co replaced like post text, but NOT HTML-decoded (X sends "&" raw here)."""
    bio = user.get("profile_bio")
    if isinstance(bio, dict):
        description = bio.get("description")
        containers = _get(bio, "entities", "description")
    else:
        description = legacy.get("description")
        containers = _get(legacy, "entities", "description")
    text = description if isinstance(description, str) else ""
    found = _raw_entities(text, containers)
    return _assemble(_render(text, 0, len(text), found, decode=False))


def _profile_url(user, legacy):
    nodes = _list(_get(user, "profile_bio", "entities", "url", "urls")) or _list(_get(legacy, "entities", "url", "urls"))
    for node in nodes:
        node = _dict(node)
        expanded = _str(node.get("expanded_url")) or _str(node.get("url"))
        if expanded:
            return {"display": _str(node.get("display_url")) or expanded, "expanded": expanded}
    return None


def _label(user):
    label = _dict(_get(user, "affiliates_highlighted_label", "label"))
    description = _str(label.get("description"))
    if description is None:
        return None
    return {"text": description, "badge": _str(_get(label, "badge", "url")) or ""}


def _verified(user, legacy):
    kind = (_str(_get(user, "verification", "verified_type")) or _str(legacy.get("verified_type")) or "").lower()
    if kind == "government":
        return "government"
    if kind == "business":
        return "business"
    if _flag(_first(user.get("is_blue_verified"), legacy.get("verified"))):
        return "blue"
    return None


@_guard(lambda: None)
def normalize_user(result, full=False):
    """X's User object -> api-v2 User, or FullUser when full is true; None when it cannot be shown."""
    user = _dict(result)
    if user.get("__typename") not in (None, "User"):
        return None  # "UserUnavailable" and the like
    legacy = _dict(user.get("legacy"))
    core = _dict(user.get("core"))
    uid = _id(user.get("rest_id")) or _id(legacy.get("id_str"))
    handle = _str(core.get("screen_name")) or _str(legacy.get("screen_name"))
    if uid is None or handle is None:
        return None
    relations = _dict(user.get("relationship_perspectives"))
    out = {
        "id": uid,
        "name": _str(core.get("name")) or _str(legacy.get("name")) or handle,
        "handle": handle,
        "avatar": _str(_get(user, "avatar", "image_url")) or _str(legacy.get("profile_image_url_https")),
        "verified": _verified(user, legacy),
        "square": user.get("profile_image_shape") == "Square",
        "protected": _flag(_first(_get(user, "privacy", "protected"), legacy.get("protected"))),
        "following": _flag(_first(relations.get("following"), legacy.get("following"))),
        "followed_by": _flag(_first(relations.get("followed_by"), legacy.get("followed_by"))),
        "blocking": _flag(_first(relations.get("blocking"), legacy.get("blocking"))),
        "muting": _flag(_first(relations.get("muting"), legacy.get("muting"))),
        "label": _label(user),
    }
    if not full:
        return out

    bio, bio_entities = _profile_text(user, legacy)
    location = _first(_get(user, "location", "location"), legacy.get("location"))
    pinned = _first(_get(user, "pinned_items", "tweet_ids_str"), legacy.get("pinned_tweet_ids_str"))
    created = _str(_get(user, "core", "created_at")) or _str(legacy.get("created_at"))
    out.update({
        "banner": _str(_get(user, "banner", "image_url")) or _str(legacy.get("profile_banner_url")),
        "bio": bio,
        "bio_entities": bio_entities,
        "location": location.strip() if isinstance(location, str) else "",
        "url": _profile_url(user, legacy),
        "joined": _parse_created_at(created),
        "followers": _int(_first(_get(user, "relationship_counts", "followers"), legacy.get("followers_count"))),
        "friends": _int(_first(_get(user, "relationship_counts", "following"), legacy.get("friends_count"))),
        "tweets": _int(_first(_get(user, "tweet_counts", "tweets"), legacy.get("statuses_count"))),
        "media_count": _int(_first(_get(user, "tweet_counts", "media_tweets"), legacy.get("media_count"))),
        "likes_count": _int(_first(_get(user, "action_counts", "favorites_count"), legacy.get("favourites_count"))),
        "pinned_ids": [pid for pid in (_id(item) for item in _list(pinned)) if pid],
        "blocked_by": _flag(_first(relations.get("blocked_by"), legacy.get("blocked_by"))),
        "follow_request_sent": _flag(_first(user.get("follow_request_sent"), legacy.get("follow_request_sent"))),
    })
    return out


# ---------------------------------------------------------------- tweets (5.2, 6.2)

def _unwrap(result):
    """(Tweet dict or None, wrapper dict or None). TweetWithVisibilityResults gives its .tweet."""
    node = _dict(result)
    if node.get("__typename") in ("TweetTombstone", "TweetUnavailable"):
        return None, None
    if node.get("__typename") == "TweetWithVisibilityResults" or "tweet" in node:
        inner = _dict(node.get("tweet"))
        return (inner or None), node
    return (node or None), None


def _is_unavailable(result):
    return _dict(result).get("__typename") in ("TweetTombstone", "TweetUnavailable")


def _unavailable_text(result):
    text = _get(result, "tombstone", "text")
    if isinstance(text, dict):
        text = text.get("text")
    return _str(text) or UNAVAILABLE_TEXT


def _rest_id(result):
    inner, _ = _unwrap(result)
    return _id(_dict(inner).get("rest_id"))


def _quoted_result(tweet, quote_id):
    result = _get(tweet, "quoted_status_result", "result")
    if result is not None:
        return result
    # Some answers put the full quoted post here instead; the reference (quotedRefResult) has no body.
    nested = _get(tweet, "nested_quoted_tweet_results", "result")
    if nested is not None and (quote_id is None or _rest_id(nested) == quote_id):
        return nested
    return None


def _reply_to(legacy, full_text, display):
    reply_id = _str(legacy.get("in_reply_to_status_id_str"))
    if reply_id is None:
        return None
    limit = display[0] if display is not None else 0
    handles = []
    primary = _str(legacy.get("in_reply_to_screen_name"))
    if primary:
        handles.append(primary)
    for node in _list(_get(legacy, "entities", "user_mentions")):
        node = _dict(node)
        span = _span(node.get("indices"), len(full_text))
        name = _str(node.get("screen_name"))
        # Only the hidden leading mentions count: they end before the display range starts.
        if span is None or name is None or span[1] > limit:
            continue
        if name.lower() not in [handle.lower() for handle in handles]:
            handles.append(name)
    return {"id": reply_id, "handles": handles}


def _tweet(result, allow_repost=True, allow_quote=True):
    tweet, wrapper = _unwrap(result)
    if tweet is None:
        return None
    legacy = _dict(tweet.get("legacy"))
    tid = _id(tweet.get("rest_id"))
    if not legacy or tid is None:
        return None
    author = normalize_user(_get(tweet, "core", "user_results", "result"))
    if author is None:
        return None

    if allow_repost:
        original = _get(legacy, "retweeted_status_result", "result")
        if original is not None:
            # A repost shows the original post; the text of the repost itself is only "RT @x: ...".
            shown = _tweet(original, allow_repost=False, allow_quote=allow_quote)
            if shown is None:
                return None
            shown["retweeted_by"] = author
            shown["retweet_id"] = tid
            return shown

    full_text = legacy.get("full_text") if isinstance(legacy.get("full_text"), str) else ""
    display = _display_range(legacy, len(full_text))
    quote_id = _str(legacy.get("quoted_status_id_str"))
    reply_id = _str(legacy.get("in_reply_to_status_id_str"))
    card, card_links = _card(tweet.get("card"), legacy)

    quote = None
    quote_unavailable = None
    if allow_quote:
        quoted = _quoted_result(tweet, quote_id)
        if quoted is not None:
            if _is_unavailable(quoted):
                quote_unavailable = _unavailable_text(quoted)
            else:
                quote = _tweet(quoted, allow_repost=True, allow_quote=False)
                if quote is None:
                    quote_unavailable = UNAVAILABLE_TEXT
        elif _flag(legacy.get("is_quote_status")) or quote_id:
            quote_unavailable = UNAVAILABLE_TEXT

    text, entities = _tweet_text(
        tweet, legacy, reply=reply_id is not None, card_links=card_links,
        quote_id=quote_id if allow_quote else None,
    )

    # Edited when either list of edit ids has more than one entry (X sends it at both places).
    edit_lists = [_list(_get(tweet, "edit_control", "edit_tweet_ids")),
                  _list(_get(tweet, "edit_control", "edit_control_initial", "edit_tweet_ids"))]
    source_html = _str(tweet.get("source")) or _str(legacy.get("source"))
    source = (strip_tags(source_html) or None) if source_html else None
    restricted = wrapper is not None and wrapper.get("limitedActionResults") is not None
    restricted = restricted or bool(_dict(legacy.get("conversation_control")))
    place = _str(_get(tweet, "place", "full_name")) or _str(_get(legacy, "place", "full_name"))
    lang = _str(legacy.get("lang")) or "und"

    return {
        "id": tid,
        "user": author,
        "text": text,
        "entities": entities,
        "long": _note_text(tweet) is not None,
        "created_at": _first(_parse_created_at(legacy.get("created_at")), 0),
        "reply_count": _int(legacy.get("reply_count")),
        "retweet_count": _int(legacy.get("retweet_count")),
        "like_count": _int(legacy.get("favorite_count")),
        "quote_count": _int(legacy.get("quote_count")),
        "bookmark_count": _int(legacy.get("bookmark_count")),
        "view_count": _maybe_int(_get(tweet, "views", "count")),
        "liked": _flag(legacy.get("favorited")),
        "retweeted": _flag(legacy.get("retweeted")),
        "bookmarked": _flag(legacy.get("bookmarked")),
        "media": _media(legacy),
        "quote": quote,
        "quote_unavailable": quote_unavailable,
        "card": card,
        "reply_to": _reply_to(legacy, full_text, display),
        "conversation_id": _str(legacy.get("conversation_id_str")) or tid,
        "retweeted_by": None,
        "retweet_id": None,
        "lang": lang,
        "sensitive": _flag(legacy.get("possibly_sensitive")),
        "source": source,
        "edited": any(len(ids) > 1 for ids in edit_lists),
        "place": place,
        "reply_limited": restricted,
    }


@_guard(lambda: None)
def normalize_tweet(result):
    """X's tweet result -> api-v2 Tweet; None when the post cannot be shown."""
    return _tweet(result)


# ---------------------------------------------------------------- timeline (5.1, 6.3)

def _row(item, post_id=None, retweet_id=None, is_post=False, block=None, pinned=False):
    """One candidate item plus what finish() needs to know about it."""
    return {
        "item": item,
        "post_id": post_id,
        "retweet_id": retweet_id,
        "is_post": is_post,
        "block": block,
        "pinned": pinned,
    }


def _context(item, tweet, pinned):
    """The small grey line above a post. Reposts get none: the app builds that line from retweeted_by."""
    social = _dict(item.get("socialContext"))
    text = _str(social.get("text"))
    is_pin = social.get("contextType") == "Pin"
    if pinned:
        return {"k": "pin", "text": text if is_pin and text else PIN_TEXT}
    if is_pin and text:
        return {"k": "pin", "text": text}
    if text and tweet["retweeted_by"] is None:
        return {"k": "text", "text": text}
    return None


def _notification_item(item):
    """TimelineNotification -> api-v2 notification item (2.7)."""
    nid = _str(item.get("id"))
    if nid is None:
        return None
    message = _dict(item.get("rich_message"))
    text = message.get("text") if isinstance(message.get("text"), str) else ""
    bold = []
    for entity in _list(message.get("entities")):
        entity = _dict(entity)
        span = _span([entity.get("fromIndex"), entity.get("toIndex")], len(text))
        if entity.get("format") == "Strong" and span is not None:
            # The app wants UTF-16 offsets; X counts code points.
            bold.append([utf16_len(text[:span[0]]), utf16_len(text[:span[1]])])
    template = _dict(item.get("template"))
    users = []
    for reference in _list(template.get("from_users")):
        if len(users) >= 8:
            break
        user = normalize_user(_get(reference, "user_results", "result"))
        if user is not None:
            users.append(user)
    tweet = None
    for reference in _list(template.get("target_objects")):
        tweet = normalize_tweet(_get(reference, "tweet_results", "result"))
        if tweet is not None:
            break
    return {
        "t": "notification",
        "id": nid,
        "icon": _ICONS.get(item.get("notification_icon"), "bell"),
        "text": text,
        "bold": bold,
        "users": users,
        "tweet": tweet,
        "time": _time_from_ms(item.get("timestamp_ms")),
        "url": _str(_get(item, "notification_url", "url")),
    }


def _trend_query(url, name):
    """The search for a trend: the query parameter of a twitter://search link, else the name."""
    if url and url.startswith("twitter://search"):
        values = parse_qs(urlsplit(url).query).get("query")
        if values and values[0]:
            return values[0]
    return name


def _trend_item(item):
    """TimelineTrend -> api-v2 trend item (2.8)."""
    name = _str(item.get("name"))
    if name is None:
        return None
    meta = _dict(item.get("trend_metadata"))
    url = _str(_get(item, "trend_url", "url")) or _str(_get(meta, "url", "url"))
    return {
        "t": "trend",
        "name": name,
        "context": _str(meta.get("domain_context")) or _str(_get(item, "social_context", "text")),
        "meta": _str(meta.get("meta_description")),
        "query": _trend_query(url, name),
        "rank": _maybe_int(item.get("rank")),
    }


class _Timeline(object):
    """Collects the rows of one answer in X's order; finish() applies pin, dedupe, threads and focal."""

    def __init__(self):
        self.rows = []
        self.pinned = []
        self.blocks = {}          # block index -> True for a VerticalConversation module
        self.module_blocks = {}   # module entryId -> block index (for TimelineAddToModule)
        self.top = None
        self.bottom = None
        self.bottom_ended = False

    def new_block(self, conversation):
        index = len(self.blocks)
        self.blocks[index] = conversation
        return index

    def in_thread(self, row):
        """True for a row inside a VerticalConversation module."""
        return row["block"] is not None and bool(self.blocks.get(row["block"]))

    def add(self, rows, pinned=False):
        (self.pinned if pinned else self.rows).extend(rows)

    def add_entry(self, entry, pinned=False):
        entry = _dict(entry)
        content = _dict(entry.get("content"))
        kind = content.get("entryType") or content.get("__typename")
        if kind == "TimelineTimelineItem":
            self.add(self.item_rows(_dict(content.get("itemContent")), None, pinned), pinned)
        elif kind == "TimelineTimelineModule":
            self.add_module(entry.get("entryId"), content)
        elif kind == "TimelineTimelineCursor":
            self.add(self.cursor_rows(content, None))

    def add_module(self, entry_id, content):
        conversation = content.get("displayType") == "VerticalConversation"
        block = self.new_block(conversation)
        rows = []
        for module_item in _list(content.get("items")):
            item = _dict(_get(module_item, "item", "itemContent"))
            rows.extend(self.item_rows(item, block, pinned=False))
        if not rows:
            return
        # A module of users (who to follow) yields no rows and so disappears; a header only heads real content.
        if any(row["item"]["t"] != "more" for row in rows):
            header = _str(_get(content, "header", "text"))
            if header:
                rows.insert(0, _row({"t": "header", "text": header}, block=block))
        entry_id = _str(entry_id)
        if entry_id:
            self.module_blocks[entry_id] = block
        self.rows.extend(rows)

    def add_to_module(self, instruction):
        module_id = _str(instruction.get("moduleEntryId"))
        block = self.module_blocks.get(module_id) if module_id else None
        if block is None:
            block = self.new_block(conversation=False)
        for module_item in _list(instruction.get("moduleItems")):
            item = _dict(_get(module_item, "item", "itemContent"))
            self.rows.extend(self.item_rows(item, block, pinned=False))

    def cursor_rows(self, content, block):
        """Top/Bottom cursors set the answer's cursors; show-more cursors become rows; the rest is ignored."""
        kind = content.get("cursorType")
        value = _str(content.get("value"))
        if value is None:
            return []
        if kind == "Top":
            self.top = value
            return []
        if kind == "Bottom":
            self.bottom = value
            return []
        if kind in _MORE_CURSORS:
            label = _str(_get(content, "displayTreatment", "actionText")) or MORE_TEXT
            return [_row({"t": "more", "cursor": value, "label": label}, block=block)]
        return []

    def item_rows(self, item, block, pinned):
        """Rows for one itemContent; [] for an advertisement or anything that cannot be shown."""
        if not item or item.get("promotedMetadata") is not None:
            return []
        kind = item.get("itemType") or item.get("__typename")
        try:
            return self._rows_of_kind(kind, item, block, pinned)
        except _SOFT_ERRORS:
            return []

    def _rows_of_kind(self, kind, item, block, pinned):
        if kind == "TimelineTweet":
            return self.tweet_rows(item, block, pinned)
        if kind == "TimelineUser":
            if block is not None:
                return []  # users inside a module are suggestions, which the app does not show
            user = normalize_user(_get(item, "user_results", "result"), full=True)
            return [] if user is None else [_row({"t": "user", "user": user}, pinned=pinned)]
        if kind == "TimelineNotification":
            return _wrap(_notification_item(item), block, pinned)
        if kind == "TimelineTrend":
            return _wrap(_trend_item(item), block, pinned)
        if kind == "TimelineTimelineCursor":
            return self.cursor_rows(item, block)
        if kind == "TimelineTombstone":
            text = _str(_get(item, "tombstoneInfo", "richText", "text")) or _str(_get(item, "tombstoneInfo", "text"))
            return [_row({"t": "tombstone", "text": text or DELETED_TEXT, "above": False, "below": False},
                         is_post=True, block=block, pinned=pinned)]
        if kind == "TimelineLabel":
            text = _str(item.get("text"))
            return _wrap({"t": "header", "text": text} if text else None, block, pinned)
        return []  # prompts, event summaries, communities and anything new

    def tweet_rows(self, item, block, pinned):
        result = _get(item, "tweet_results", "result")
        if result is None:
            return []
        if _is_unavailable(result):
            return [self._tombstone(result, block, pinned)]
        inner, _ = _unwrap(result)
        if inner is None:
            return []
        original = _get(inner, "legacy", "retweeted_status_result", "result")
        if original is not None and _is_unavailable(original):
            return [self._tombstone(original, block, pinned)]
        tweet = _tweet(result)
        if tweet is None:
            return []
        out = {
            "t": "tweet",
            "tweet": tweet,
            "context": _context(item, tweet, pinned),
            "above": False,
            "below": False,
            "focal": False,
        }
        return [_row(out, post_id=tweet["id"], retweet_id=tweet["retweet_id"], is_post=True,
                     block=block, pinned=pinned)]

    def _tombstone(self, result, block, pinned):
        out = {"t": "tombstone", "text": _unavailable_text(result), "above": False, "below": False}
        return _row(out, is_post=True, block=block, pinned=pinned)

    def finish(self, focal_id):
        rows = self.pinned + self.rows

        # The focal post is a tweet row with that id (a repost matches on its own id too).
        # A stand-alone row is preferred: a copy inside a module is only a related post.
        focal_row = None
        if focal_id:
            matches = [row for row in rows
                       if row["item"]["t"] == "tweet" and focal_id in (row["post_id"], row["retweet_id"])]
            standalone = [row for row in matches if row["block"] is None]
            if standalone or matches:
                focal_row = (standalone or matches)[0]

        # Each post id once per answer: the first occurrence wins. Two exceptions. The focal post
        # is shown once, in the focal position, so other copies of it go. A post inside a
        # VerticalConversation module is always kept, because dropping it would break the thread
        # line. Every kept post still counts as shown, so a later stand-alone copy is dropped.
        focal_post = focal_row["post_id"] if focal_row is not None else None
        seen = set()
        kept = []
        for row in rows:
            post_id = row["post_id"]
            if post_id is None:
                kept.append(row)
                continue
            if row is focal_row:
                keep = True
            elif post_id == focal_post:
                keep = False
            elif self.in_thread(row):
                keep = True
            else:
                keep = post_id not in seen
            if keep:
                seen.add(post_id)
                kept.append(row)

        # Posts of one VerticalConversation module are joined by the line above/below the avatar.
        threads = {}
        for row in kept:
            if row["is_post"] and self.in_thread(row):
                threads.setdefault(row["block"], []).append(row)
        for members in threads.values():
            for index, row in enumerate(members):
                row["item"]["above"] = index > 0
                row["item"]["below"] = index < len(members) - 1

        # In a post detail, the stand-alone posts before the focal one are what it answers.
        if focal_row is not None:
            position = next(index for index, row in enumerate(kept) if row is focal_row)
            ancestors = [row for row in kept[:position]
                         if row["is_post"] and row["block"] is None and not row["pinned"]]
            for index, row in enumerate(ancestors):
                row["item"]["below"] = True
                row["item"]["above"] = index > 0
            focal_row["item"]["focal"] = True
            if ancestors:
                focal_row["item"]["above"] = True

        items = [row["item"] for row in kept]
        # Nothing at all, or X said there is nothing further down: no bottom cursor.
        bottom = None if (self.bottom_ended or not items) else self.bottom
        return {"items": items, "top": self.top, "bottom": bottom}


def _wrap(item, block, pinned):
    return [] if item is None else [_row(item, block=block, pinned=pinned)]


def _empty_timeline():
    return {"items": [], "top": None, "bottom": None}


def _timeline(instructions, focal_id=None):
    builder = _Timeline()
    for instruction in instructions:
        instruction = _dict(instruction)
        kind = instruction.get("type")
        if kind == "TimelineAddEntries":
            for entry in _list(instruction.get("entries")):
                builder.add_entry(entry)
        elif kind == "TimelineReplaceEntry":
            builder.add_entry(instruction.get("entry"))
        elif kind == "TimelinePinEntry":
            builder.add_entry(instruction.get("entry"), pinned=True)
        elif kind == "TimelineAddToModule":
            builder.add_to_module(instruction)
        elif kind == "TimelineTerminateTimeline":
            if instruction.get("direction") == "Bottom":
                builder.bottom_ended = True
        # TimelineClearCache, unread markers and anything new are ignored.
    return builder.finish(_str(focal_id))


@_guard(_empty_timeline)
def normalize_timeline(data, focal_id=None):
    """Whole timeline answer -> {"items": [...], "top": cursor or None, "bottom": cursor or None}."""
    return _timeline(find_instructions(data), focal_id)


# ---------------------------------------------------------------- other answers

def _empty_explore():
    return {"tabs": [], "tab": "", "items": [], "top": None, "bottom": None}


@_guard(_empty_explore)
def normalize_explore(data):
    """ExplorePage answer -> tabs, the first tab's id and items; no cursors (the app reloads a tab)."""
    body = _dict(_get(data, "data", "explore_page", "body"))
    tabs = []
    for tab in _list(body.get("timelines")):
        tab = _dict(tab)
        tab_id = _str(tab.get("id"))
        if tab_id:
            tabs.append({"id": tab_id, "label": _str(tab.get("labelText")) or ""})
    initial = _dict(body.get("initialTimeline"))
    tab = _str(initial.get("id")) or (tabs[0]["id"] if tabs else "")
    items = _timeline(find_instructions(initial))["items"]
    return {"tabs": tabs, "tab": tab, "items": items, "top": None, "bottom": None}


@_guard(lambda: None)
def normalize_user_response(data):
    """Viewer / UserByScreenName / UserByRestId answer -> FullUser, or None."""
    for node in (_get(data, "data", "viewer", "user_results", "result"), _get(data, "data", "user", "result")):
        if node is not None:
            return normalize_user(node, full=True)
    return None


@_guard(lambda: None)
def normalize_created_tweet(data):
    """CreateTweet answer -> the new Tweet, or None."""
    return normalize_tweet(_get(data, "data", "create_tweet", "tweet_results", "result"))
