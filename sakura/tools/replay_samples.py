#!/usr/bin/env python3
"""Run normalize.py over captured real answers and check its output (local use only).

usage: python sakura/tools/replay_samples.py <dir or file ...> [--dump <out dir>] [--focal <id>]

Captures (*.json or *.json.gz) hold real people's data: they are never committed, and
--dump refuses a directory inside this repository. Prints per file the item counts,
top/bottom presence and every invariant violation; exits 1 when there is any.
"""

import argparse
import glob
import gzip
import json
import os
import sys
import traceback
from collections import Counter


HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(REPO, "sakura", "app"))

from xrelay_app import normalize  # noqa: E402  (path set up just above)


TWEET_KEYS = [
    "id", "user", "text", "entities", "long", "created_at", "reply_count", "retweet_count",
    "like_count", "quote_count", "bookmark_count", "view_count", "liked", "retweeted",
    "bookmarked", "media", "quote", "quote_unavailable", "card", "reply_to", "conversation_id",
    "retweeted_by", "retweet_id", "lang", "sensitive", "source", "edited", "place", "reply_limited",
]
USER_KEYS = ["id", "name", "handle", "avatar", "verified", "square", "protected", "following",
             "followed_by", "blocking", "muting", "label"]
FULL_USER_KEYS = USER_KEYS + [
    "banner", "bio", "bio_entities", "location", "url", "joined", "followers", "friends", "tweets",
    "media_count", "likes_count", "pinned_ids", "blocked_by", "follow_request_sent",
]
ITEM_KEYS = {
    "tweet": ["t", "tweet", "context", "above", "below", "focal"],
    "more": ["t", "cursor", "label"],
    "header": ["t", "text"],
    "tombstone": ["t", "text", "above", "below"],
    "user": ["t", "user"],
    "notification": ["t", "id", "icon", "text", "bold", "users", "tweet", "time", "url"],
    "trend": ["t", "name", "context", "meta", "query", "rank"],
}
CARD_KEYS = ["type", "url", "domain", "title", "description", "image", "poll"]
MEDIA_KINDS = ("photo", "video", "gif")
CARD_TYPES = ("summary", "summary_large_image", "player", "poll")
ENTITY_KINDS = ("url", "mention", "hashtag", "cashtag")
# Full-width sigils are accepted too (normalize.py does not drop entities that use them).
SIGILS = {"mention": "@＠", "hashtag": "#＃", "cashtag": "$＄"}
VERIFIED = (None, "blue", "business", "government")
TCO = "https://t.co/"


# ---------------------------------------------------------------- loading

def load(path):
    with (gzip.open(path, "rb") if path.endswith(".gz") else open(path, "rb")) as handle:
        return json.loads(handle.read().decode("utf-8"))


def collect(paths):
    files = []
    for path in paths:
        if os.path.isdir(path):
            found = glob.glob(os.path.join(path, "*.json")) + glob.glob(os.path.join(path, "*.json.gz"))
            files.extend(sorted(found))
        else:
            files.append(path)
    return files


def _get(node, *keys):
    for key in keys:
        if not isinstance(node, dict):
            return None
        node = node.get(key)
    return node


def classify(data):
    if _get(data, "data", "explore_page") is not None:
        return "explore"
    if _get(data, "data", "create_tweet") is not None:
        return "created"
    if not normalize.find_instructions(data):
        if _get(data, "data", "viewer", "user_results", "result") is not None or \
                _get(data, "data", "user", "result") is not None:
            return "user"
    return "timeline"


def detail_focal(data):
    """Focal post of a TweetDetail answer: the tweet- entry that conversation threads follow,
    else the last stand-alone tweet- entry."""
    if _get(data, "data", "threaded_conversation_with_injections_v2") is None:
        return None
    entries = []
    for instruction in normalize.find_instructions(data):
        if isinstance(instruction, dict):
            entries.extend(e for e in instruction.get("entries") or [] if isinstance(e, dict))
    for index, entry in enumerate(entries):
        entry_id = str(entry.get("entryId", ""))
        following = entries[index + 1] if index + 1 < len(entries) else {}
        if entry_id.startswith("tweet-") and str(following.get("entryId", "")).startswith("conversationthread-"):
            return entry_id[len("tweet-"):]
    standalone = [str(e.get("entryId", "")) for e in entries
                  if str(e.get("entryId", "")).startswith("tweet-")
                  and _get(e, "content", "entryType") == "TimelineTimelineItem"]
    return standalone[-1][len("tweet-"):] if standalone else None


def _as_dict(value):
    return value if isinstance(value, dict) else {}


def _as_list(value):
    return value if isinstance(value, list) else []


def raw_post_id(result):
    """Id an output item carries for a raw tweet result: the original's id for a repost."""
    node = _as_dict(result)
    if node.get("__typename") in ("TweetTombstone", "TweetUnavailable"):
        return None
    if node.get("__typename") == "TweetWithVisibilityResults":
        node = _as_dict(node.get("tweet"))
    original = _get(node, "legacy", "retweeted_status_result", "result")
    if original is not None:
        return raw_post_id(original)
    rest_id = node.get("rest_id")
    return str(rest_id) if rest_id else None


def conversation_post_counts(data):
    """How often each post id occurs inside VerticalConversation modules of the raw answer
    (advertisements left out). Only these copies may repeat in the output."""
    counts = Counter()
    conversation_ids = set()

    def count_module_item(module_item):
        content = _as_dict(_as_dict(_as_dict(module_item).get("item")).get("itemContent"))
        if content.get("itemType") != "TimelineTweet" or content.get("promotedMetadata") is not None:
            return
        post_id = raw_post_id(_as_dict(content.get("tweet_results")).get("result"))
        if post_id:
            counts[post_id] += 1

    for instruction in normalize.find_instructions(data):
        instruction = _as_dict(instruction)
        kind = instruction.get("type")
        entries = []
        if kind == "TimelineAddEntries":
            entries = _as_list(instruction.get("entries"))
        elif kind in ("TimelineReplaceEntry", "TimelinePinEntry"):
            entries = [instruction.get("entry")]
        for entry in entries:
            content = _as_dict(_as_dict(entry).get("content"))
            if content.get("entryType") == "TimelineTimelineModule" and                     content.get("displayType") == "VerticalConversation":
                conversation_ids.add(_as_dict(entry).get("entryId"))
                for module_item in _as_list(content.get("items")):
                    count_module_item(module_item)
        if kind == "TimelineAddToModule" and instruction.get("moduleEntryId") in conversation_ids:
            for module_item in _as_list(instruction.get("moduleItems")):
                count_module_item(module_item)
    return counts


def check_repeats(post_ids, conversation_counts, problems):
    """A post id may repeat only as copies inside VerticalConversation modules of the capture:
    at most one stand-alone copy plus one per conversation copy."""
    for post_id, count in post_ids.items():
        allowed = 1 + conversation_counts.get(post_id, 0)
        if count > allowed:
            problems.append("post id %s appears %d times (at most %d allowed)" % (post_id, count, allowed))


# ---------------------------------------------------------------- UTF-16 helpers

def utf16_boundaries(text):
    """Offsets where a code point starts or ends; an entity edge elsewhere splits a character."""
    marks = {0}
    pos = 0
    for char in text:
        pos += len(char.encode("utf-16-le", "surrogatepass")) // 2
        marks.add(pos)
    return marks


def utf16_slice(text, start, end):
    raw = text.encode("utf-16-le", "surrogatepass")
    return raw[2 * start:2 * end].decode("utf-16-le", "surrogatepass")


def utf16_len(text):
    return len(text.encode("utf-16-le", "surrogatepass")) // 2


# ---------------------------------------------------------------- invariant checks

def check_keys(node, keys, where, problems):
    if not isinstance(node, dict):
        problems.append("%s: not an object" % where)
        return False
    missing = [key for key in keys if key not in node]
    extra = [key for key in node if key not in keys]
    if missing:
        problems.append("%s: missing keys %s" % (where, ", ".join(missing)))
    if extra:
        problems.append("%s: unexpected keys %s" % (where, ", ".join(extra)))
    return not missing


def check_user(user, full, where, problems):
    if user is None:
        return
    if not check_keys(user, FULL_USER_KEYS if full else USER_KEYS, where, problems):
        return
    for key in ("id", "name", "handle"):
        if not isinstance(user[key], str) or not user[key]:
            problems.append("%s: %s empty" % (where, key))
    if user["handle"].startswith("@"):
        problems.append("%s: handle has an @" % where)
    for key in ("square", "protected", "following", "followed_by", "blocking", "muting"):
        if not isinstance(user[key], bool):
            problems.append("%s: %s is not a bool" % (where, key))
    if user["verified"] not in VERIFIED:
        problems.append("%s: verified %r" % (where, user["verified"]))
    if user["avatar"] is not None and not isinstance(user["avatar"], str):
        problems.append("%s: avatar type" % where)
    label = user["label"]
    if label is not None and not (isinstance(label, dict) and isinstance(label.get("text"), str)
                                  and isinstance(label.get("badge"), str)):
        problems.append("%s: label shape" % where)
    if not full:
        return
    if not isinstance(user["bio"], str) or not isinstance(user["location"], str):
        problems.append("%s: bio/location not strings" % where)
    for key in ("followers", "friends", "tweets", "media_count", "likes_count"):
        if not isinstance(user[key], int):
            problems.append("%s: %s not an int" % (where, key))
    if user["joined"] is not None and not isinstance(user["joined"], int):
        problems.append("%s: joined type" % where)
    if user["url"] is not None and not (isinstance(user["url"], dict) and
                                        {"display", "expanded"} <= set(user["url"])):
        problems.append("%s: url shape" % where)
    if not isinstance(user["pinned_ids"], list):
        problems.append("%s: pinned_ids not a list" % where)
    check_entities(user["bio_entities"], user["bio"], where + ".bio", problems)


def check_entities(entities, text, where, problems):
    """Offsets inside the UTF-16 text, sorted, not overlapping, sigils match, boundaries are real."""
    length = utf16_len(text)
    marks = utf16_boundaries(text)
    previous_end = 0
    for index, entity in enumerate(entities):
        here = "%s[%d]" % (where, index)
        if not check_keys(entity, ["s", "e", "k", "v"], here, problems):
            continue
        start, end = entity["s"], entity["e"]
        if not (isinstance(start, int) and isinstance(end, int)):
            problems.append("%s: offsets not ints" % here)
            continue
        if not (0 <= start < end <= length):
            problems.append("%s: offsets %d..%d outside text of %d units" % (here, start, end, length))
            continue
        if start < previous_end:
            problems.append("%s: overlaps or is unsorted" % here)
        previous_end = end
        if start not in marks or end not in marks:
            problems.append("%s: offset splits a character" % here)
        if entity["k"] not in ENTITY_KINDS:
            problems.append("%s: kind %r" % (here, entity["k"]))
            continue
        if entity["k"] in SIGILS:
            covered = utf16_slice(text, start, end)
            if covered[:1] not in SIGILS[entity["k"]]:
                problems.append("%s: %s covers %r" % (here, entity["k"], covered))
        if not isinstance(entity["v"], str) or not entity["v"]:
            problems.append("%s: empty v" % here)


def check_tweet(tweet, where, problems, depth=0):
    if not check_keys(tweet, TWEET_KEYS, where, problems):
        return
    if not isinstance(tweet["id"], str) or not tweet["id"]:
        problems.append("%s: empty id" % where)
    check_user(tweet["user"], False, where + ".user", problems)
    if tweet["retweeted_by"] is not None:
        check_user(tweet["retweeted_by"], False, where + ".retweeted_by", problems)
    text = tweet["text"]
    if not isinstance(text, str):
        problems.append("%s: text not a string" % where)
        return
    check_entities(tweet["entities"], text, where + ".entities", problems)
    for bad in ("&amp;", "&lt;", "&gt;"):
        if bad in text:
            problems.append("%s: text still has %s" % (where, bad))
    # A t.co link may stay only as the visible text of a URL entity.
    url_spans = [(e["s"], e["e"]) for e in tweet["entities"] if isinstance(e, dict) and e.get("k") == "url"]
    index = text.find(TCO)
    while index != -1:
        start = utf16_len(text[:index])
        end = start + utf16_len(TCO)
        if not any(s <= start and end <= e for s, e in url_spans):
            problems.append("%s: raw t.co link in text at %d" % (where, start))
        index = text.find(TCO, index + len(TCO))
    if not isinstance(tweet["created_at"], int):
        problems.append("%s: created_at type" % where)
    for key in ("reply_count", "retweet_count", "like_count", "quote_count", "bookmark_count"):
        if not isinstance(tweet[key], int):
            problems.append("%s: %s not an int" % (where, key))
    if tweet["view_count"] is not None and not isinstance(tweet["view_count"], int):
        problems.append("%s: view_count type" % where)
    for key in ("long", "liked", "retweeted", "bookmarked", "sensitive", "edited", "reply_limited"):
        if not isinstance(tweet[key], bool):
            problems.append("%s: %s not a bool" % (where, key))
    if not isinstance(tweet["conversation_id"], str) or not tweet["conversation_id"]:
        problems.append("%s: conversation_id" % where)
    if not isinstance(tweet["lang"], str):
        problems.append("%s: lang type" % where)
    if tweet["reply_to"] is not None:
        if check_keys(tweet["reply_to"], ["id", "handles"], where + ".reply_to", problems):
            if not all(isinstance(h, str) and h for h in tweet["reply_to"]["handles"]):
                problems.append("%s: reply_to handles" % where)
    for index, media in enumerate(tweet["media"]):
        check_media(media, "%s.media[%d]" % (where, index), problems)
    if tweet["card"] is not None:
        check_card(tweet["card"], where + ".card", problems)
    if depth > 0 and (tweet["quote"] is not None or tweet["quote_unavailable"] is not None):
        # A quoted post never carries a quote of its own (one level only).
        problems.append("%s: quoted post has its own quote or quote_unavailable" % where)
    if tweet["quote"] is not None:
        if tweet["quote_unavailable"] is not None:
            problems.append("%s: quote and quote_unavailable both set" % where)
        check_tweet(tweet["quote"], where + ".quote", problems, depth + 1)
    if tweet["quote_unavailable"] is not None and not isinstance(tweet["quote_unavailable"], str):
        problems.append("%s: quote_unavailable type" % where)
    if tweet["source"] is not None and not isinstance(tweet["source"], str):
        problems.append("%s: source type" % where)
    if tweet["place"] is not None and not isinstance(tweet["place"], str):
        problems.append("%s: place type" % where)


def check_media(media, where, problems):
    if not check_keys(media, ["type", "url", "w", "h", "alt", "video"], where, problems):
        return
    if media["type"] not in MEDIA_KINDS:
        problems.append("%s: type %r" % (where, media["type"]))
    if not isinstance(media["url"], str) or not media["url"]:
        problems.append("%s: media without url" % where)
    if not isinstance(media["w"], int) or not isinstance(media["h"], int):
        problems.append("%s: size not ints" % where)
    if media["alt"] is not None and not isinstance(media["alt"], str):
        problems.append("%s: alt type" % where)
    if media["type"] in ("video", "gif"):
        video = media["video"]
        if not check_keys(video, ["mp4", "hls", "duration_ms", "aspect"], where + ".video", problems):
            return
        if not (video["mp4"] or video["hls"]):
            problems.append("%s: video has neither mp4 nor hls" % where)
        if not (isinstance(video["aspect"], list) and len(video["aspect"]) == 2):
            problems.append("%s: aspect shape" % where)
        if not isinstance(video["duration_ms"], int):
            problems.append("%s: duration_ms type" % where)
    elif media["video"] is not None:
        problems.append("%s: photo with a video object" % where)


def check_card(card, where, problems):
    if not check_keys(card, CARD_KEYS, where, problems):
        return
    if card["type"] not in CARD_TYPES:
        problems.append("%s: type %r" % (where, card["type"]))
    if card["type"] == "poll":
        if card["poll"] is None or not isinstance(card["poll"].get("choices"), list):
            problems.append("%s: poll without choices" % where)
        if card["url"] != "" or card["image"] is not None:
            problems.append("%s: poll should have empty url and null image" % where)
    else:
        if card["poll"] is not None:
            problems.append("%s: poll object on a %s card" % (where, card["type"]))
        for key in ("url", "domain", "title", "description"):
            if not isinstance(card[key], str):
                problems.append("%s: %s not a string" % (where, key))
    if card["image"] is not None and not (isinstance(card["image"], dict) and isinstance(card["image"].get("url"), str)):
        problems.append("%s: image shape" % where)


def check_item(item, index, problems):
    where = "items[%d]" % index
    kind = item.get("t") if isinstance(item, dict) else None
    if kind not in ITEM_KEYS:
        problems.append("%s: unknown t %r" % (where, kind))
        return None
    if not check_keys(item, ITEM_KEYS[kind], where, problems):
        return kind
    if kind == "tweet":
        check_tweet(item["tweet"], where + ".tweet", problems)
        for key in ("above", "below", "focal"):
            if not isinstance(item[key], bool):
                problems.append("%s: %s not a bool" % (where, key))
        if item["context"] is not None and not (isinstance(item["context"], dict)
                                                and item["context"].get("k") in ("pin", "text")
                                                and isinstance(item["context"].get("text"), str)):
            problems.append("%s: context shape" % where)
    elif kind == "more":
        if not (isinstance(item["cursor"], str) and item["cursor"]):
            problems.append("%s: empty cursor" % where)
    elif kind == "header" or kind == "tombstone":
        if not (isinstance(item["text"], str) and item["text"]):
            problems.append("%s: empty text" % where)
        if kind == "tombstone":
            for key in ("above", "below"):
                if not isinstance(item[key], bool):
                    problems.append("%s: %s not a bool" % (where, key))
    elif kind == "user":
        check_user(item["user"], True, where + ".user", problems)
    elif kind == "notification":
        if not (isinstance(item["id"], str) and item["id"]):
            problems.append("%s: notification without id" % where)
        if item["icon"] not in ("heart", "repost", "person", "star", "bell", "reply", "logo", "alert"):
            problems.append("%s: icon %r" % (where, item["icon"]))
        for pair in item["bold"]:
            if not (isinstance(pair, list) and len(pair) == 2 and pair[0] < pair[1] <= utf16_len(item["text"])):
                problems.append("%s: bold range %r outside text" % (where, pair))
        for position, user in enumerate(item["users"]):
            check_user(user, False, "%s.users[%d]" % (where, position), problems)
        if len(item["users"]) > 8:
            problems.append("%s: more than 8 users" % where)
        if item["tweet"] is not None:
            check_tweet(item["tweet"], where + ".tweet", problems)
        if item["time"] is not None and not isinstance(item["time"], int):
            problems.append("%s: time type" % where)
    elif kind == "trend":
        if not (isinstance(item["name"], str) and item["name"]):
            problems.append("%s: trend without name" % where)
        if not (isinstance(item["query"], str) and item["query"]):
            problems.append("%s: trend without query" % where)
        if item["rank"] is not None and not isinstance(item["rank"], int):
            problems.append("%s: rank type" % where)
    return kind


def check_timeline(result, focal_id, problems, conversation_counts):
    if not check_keys(result, ["items", "top", "bottom"], "timeline", problems):
        return
    for key in ("top", "bottom"):
        if result[key] is not None and not isinstance(result[key], str):
            problems.append("timeline.%s type" % key)
    if not isinstance(result["items"], list):
        problems.append("timeline.items not a list")
        return
    focal_count = 0
    ids = Counter()
    for index, item in enumerate(result["items"]):
        kind = check_item(item, index, problems)
        if kind == "tweet":
            ids[item["tweet"]["id"]] += 1
            if item["focal"]:
                focal_count += 1
    check_repeats(ids, conversation_counts, problems)
    if focal_id is not None and focal_count != 1:
        problems.append("no focal item for id %s (found %d)" % (focal_id, focal_count))
    if focal_id is None and focal_count:
        problems.append("focal set without a focal id")


def check_explore(result, problems, conversation_counts):
    if not check_keys(result, ["tabs", "tab", "items", "top", "bottom"], "explore", problems):
        return
    for index, tab in enumerate(result["tabs"]):
        check_keys(tab, ["id", "label"], "tabs[%d]" % index, problems)
    if result["top"] is not None or result["bottom"] is not None:
        problems.append("explore top/bottom must be null")
    ids = [tab["id"] for tab in result["tabs"]]
    if result["tab"] and result["tab"] not in ids:
        problems.append("explore tab %r is not among the tabs" % result["tab"])
    ids = Counter()
    for index, item in enumerate(result["items"]):
        if check_item(item, index, problems) == "tweet":
            ids[item["tweet"]["id"]] += 1
    check_repeats(ids, conversation_counts, problems)


# ---------------------------------------------------------------- report

def count_kinds(items):
    counts = Counter(item.get("t") for item in items if isinstance(item, dict))
    return counts


def tweet_stats(items):
    stats = Counter()
    for item in items:
        if not isinstance(item, dict) or item.get("t") != "tweet":
            continue
        tweet = item["tweet"]
        stats["quotes"] += 1 if tweet.get("quote") else 0
        stats["quote_unavailable"] += 1 if tweet.get("quote_unavailable") else 0
        stats["reposts"] += 1 if tweet.get("retweeted_by") else 0
        stats["long"] += 1 if tweet.get("long") else 0
        stats["media"] += len(tweet.get("media") or [])
        stats["cards"] += 1 if tweet.get("card") else 0
        stats["focal"] += 1 if item.get("focal") else 0
    return stats


def process(path, focal_override, dump_dir):
    data = load(path)
    kind = classify(data)
    problems = []
    name = os.path.basename(path)
    focal = focal_override or detail_focal(data)
    if kind == "explore":
        result = normalize.normalize_explore(data)
        check_explore(result, problems, conversation_post_counts(data))
        summary = "tabs=%d tab=%s items=%d" % (len(result["tabs"]), result["tab"], len(result["items"]))
        kinds = count_kinds(result["items"])
        stats = tweet_stats(result["items"])
        top_bottom = "top=%s bottom=%s" % ("yes" if result["top"] else "no", "yes" if result["bottom"] else "no")
    elif kind == "user":
        result = normalize.normalize_user_response(data)
        check_user(result, True, "user", problems)
        summary = "user=%s" % ("none" if result is None else "@" + result["handle"])
        kinds = Counter()
        stats = Counter()
        top_bottom = "-"
        if result is None:
            problems.append("user answer produced no user")
    elif kind == "created":
        result = normalize.normalize_created_tweet(data)
        if result is not None:
            check_tweet(result, "created", problems)
        summary = "created=%s" % ("none" if result is None else result["id"])
        kinds = Counter()
        stats = Counter()
        top_bottom = "-"
    else:
        result = normalize.normalize_timeline(data, focal)
        check_timeline(result, focal, problems, conversation_post_counts(data))
        kinds = count_kinds(result["items"])
        stats = tweet_stats(result["items"])
        summary = "items=%d" % len(result["items"])
        top_bottom = "top=%s bottom=%s" % ("yes" if result["top"] else "no", "yes" if result["bottom"] else "no")

    print("== %s  [%s]  focal=%s  %s  %s" % (name, kind, focal or "-", summary, top_bottom))
    if kind == "timeline" or kind == "explore":
        print("   kinds: " + (", ".join("%s=%d" % (k, v) for k, v in sorted(kinds.items())) or "none"))
        shown = ", ".join("%s=%d" % (k, v) for k, v in sorted(stats.items()) if v)
        print("   tweets: " + (shown or "none"))
        repeats = Counter(item["tweet"]["id"] for item in result["items"] if item.get("t") == "tweet")
        repeated = ["%s x%d" % (post_id, count) for post_id, count in sorted(repeats.items()) if count > 1]
        if repeated:
            print("   repeated post ids: " + ", ".join(repeated))
    print("   violations: %d" % len(problems))
    for problem in problems:
        print("     - " + problem)

    if dump_dir:
        stem = name[:-len(".json.gz")] if name.endswith(".json.gz") else os.path.splitext(name)[0]
        target = os.path.join(dump_dir, stem + ".normalized.json")
        with open(target, "w", encoding="utf-8") as handle:
            json.dump(result, handle, ensure_ascii=False, indent=1)
            handle.write("\n")
    return len(problems)


def main(argv):
    parser = argparse.ArgumentParser(description="Replay captured X answers through normalize.py.")
    parser.add_argument("paths", nargs="+", help="capture files or directories")
    parser.add_argument("--dump", metavar="DIR", help="write the normalised JSON here (outside the repository)")
    parser.add_argument("--focal", metavar="ID", help="focal post id for a TweetDetail answer")
    args = parser.parse_args(argv)

    dump_dir = None
    if args.dump:
        dump_dir = os.path.abspath(args.dump)
        if dump_dir == REPO or dump_dir.startswith(REPO + os.sep):
            print("refusing to dump inside the repository: %s" % dump_dir, file=sys.stderr)
            return 2
        os.makedirs(dump_dir, exist_ok=True)

    files = collect(args.paths)
    if not files:
        print("no capture files found", file=sys.stderr)
        return 2
    total = 0
    failed = 0
    for path in files:
        if not os.path.isfile(path):
            failed += 1
            print("== %s  ERROR: not a file" % path)
            continue
        try:
            total += process(path, args.focal, dump_dir)
        except Exception:
            failed += 1
            print("== %s  ERROR" % os.path.basename(path))
            traceback.print_exc()
    print("files: %d  violations: %d  errors: %d" % (len(files), total, failed))
    return 1 if (total or failed) else 0


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    sys.exit(main(sys.argv[1:]))
