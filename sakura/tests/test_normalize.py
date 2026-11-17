"""Tests for xrelay_app.normalize (X's JSON -> api-v2), server-design.md section 7.

Every expected value below was worked out from the X-shaped input by hand (UTF-16
offsets, epoch seconds, ...), not copied from the implementation's output.
Fixtures are invented: names, ids and texts are made up for these tests.
"""

import json
import sys
import unittest
from pathlib import Path


APP_DIR = Path(__file__).resolve().parents[1] / "app"
FIXTURES = Path(__file__).resolve().parent / "fixtures"
sys.path.insert(0, str(APP_DIR))

from xrelay_app import normalize as n  # noqa: E402  (the path is set up just above)


# api-v2.md section 2, key by key.
TWEET_KEYS = [
    "id", "user", "text", "entities", "long", "created_at", "reply_count", "retweet_count",
    "like_count", "quote_count", "bookmark_count", "view_count", "liked", "retweeted",
    "bookmarked", "media", "quote", "quote_unavailable", "card", "reply_to", "conversation_id",
    "retweeted_by", "retweet_id", "lang", "sensitive", "source", "edited", "place", "reply_limited",
    "translatable",
]
USER_KEYS = ["id", "name", "handle", "avatar", "verified", "square", "protected", "following",
             "followed_by", "blocking", "muting", "label"]
FULL_USER_KEYS = USER_KEYS + [
    "banner", "bio", "bio_entities", "location", "url", "joined", "followers", "friends", "tweets",
    "media_count", "likes_count", "pinned_ids", "blocked_by", "follow_request_sent", "bio_translatable",
]
UNAVAILABLE = "このポストは表示できません。"


def u16(text):
    """UTF-16 code units of text (what api-v2 offsets count)."""
    return len(text.encode("utf-16-le")) // 2


def load_fixture(name):
    with open(str(FIXTURES / name), encoding="utf-8") as handle:
        return json.load(handle)


# ---------------------------------------------------------------- builders (X's shapes)

def user_result(uid="1000000000000000001", name="Alice Example", handle="alice_example", **extra):
    node = {
        "__typename": "User",
        "rest_id": uid,
        "core": {"name": name, "screen_name": handle, "created_at": "Tue Mar 04 10:00:00 +0000 2014"},
        "avatar": {"image_url": "https://pbs.twimg.com/profile_images/1/alice_normal.jpg"},
        "is_blue_verified": False,
        "verification": {"verified": False},
        "profile_image_shape": "Circle",
        "privacy": {"protected": False},
        "relationship_perspectives": {"following": False, "followed_by": False, "blocking": False,
                                      "blocked_by": False, "muting": False},
        "follow_request_sent": False,
        "relationship_counts": {"followers": 10, "following": 5},
        "tweet_counts": {"tweets": 20, "media_tweets": 3},
        "action_counts": {"favorites_count": 7},
        "profile_bio": {"description": "", "entities": {"description": {}}},
        "location": {"location": ""},
        "pinned_items": {},
        "affiliates_highlighted_label": {},
    }
    node.update(extra)
    return node


def legacy(text, **extra):
    node = {
        "full_text": text,
        "display_text_range": [0, len(text)],
        "entities": {"urls": [], "user_mentions": [], "hashtags": [], "symbols": [], "media": []},
        "created_at": "Mon Nov 16 06:48:58 +0000 2026",
        "conversation_id_str": "2000000000000000100",
        "favorite_count": 11, "retweet_count": 12, "reply_count": 13, "quote_count": 14,
        "bookmark_count": 15, "favorited": False, "retweeted": False, "bookmarked": False,
        "lang": "en", "possibly_sensitive": False, "is_quote_status": False,
    }
    node.update(extra)
    return node


def tweet_result(text="Hello", tid="2000000000000000100", author=None, leg=None, typename="Tweet", **extra):
    node = {
        "__typename": typename,
        "rest_id": tid,
        "core": {"user_results": {"result": author if author is not None else user_result()}},
        "legacy": leg if leg is not None else legacy(text),
    }
    if typename is None:
        node.pop("__typename")  # the inner tweet of TweetWithVisibilityResults has none
    node.update(extra)
    return node


def url_entity(text, sub, tco, expanded, display):
    start = text.index(sub)
    return {"indices": [start, start + len(sub)], "url": tco, "display_url": display, "expanded_url": expanded}


def media_node(kind="photo", url="https://pbs.twimg.com/media/ABCDEF.jpg", **extra):
    node = {"type": kind, "media_url_https": url, "url": "https://t.co/M1", "indices": [0, 1],
            "original_info": {"width": 800, "height": 600}, "ext_alt_text": None}
    node.update(extra)
    return node


def tweet_item(result, **extra):
    content = {"itemType": "TimelineTweet", "__typename": "TimelineTweet", "tweetDisplayType": "Tweet",
               "tweet_results": {"result": result}}
    content.update(extra)
    return content


def entry(entry_id, content):
    return {"entryId": entry_id, "sortIndex": "1000", "content": content}


def item_entry(entry_id, item_content):
    return entry(entry_id, {"entryType": "TimelineTimelineItem", "__typename": "TimelineTimelineItem",
                            "itemContent": item_content})


def cursor_entry(entry_id, cursor_type, value, **extra):
    content = {"entryType": "TimelineTimelineCursor", "__typename": "TimelineTimelineCursor",
               "cursorType": cursor_type, "value": value}
    content.update(extra)
    return entry(entry_id, content)


def module_entry(entry_id, display_type, items, header=None):
    content = {"entryType": "TimelineTimelineModule", "__typename": "TimelineTimelineModule",
               "displayType": display_type, "items": items}
    if header is not None:
        content["header"] = header
    return entry(entry_id, content)


def module_item(entry_id, item_content):
    return {"entryId": entry_id, "item": {"itemContent": item_content}}


def answer(*instructions):
    """A TimelineAddEntries-style answer as the home endpoint sends it."""
    return {"data": {"home": {"home_timeline_urt": {"instructions": list(instructions)}}}}


def add(*entries):
    return {"type": "TimelineAddEntries", "entries": list(entries)}


def items_of(result):
    return result["items"]


def tweet_ids(result):
    return [item["tweet"]["id"] for item in result["items"] if item["t"] == "tweet"]


def normalized_tweet(text, leg=None, **extra):
    return n.normalize_tweet(tweet_result(text, leg=leg if leg is not None else legacy(text), **extra))


# ---------------------------------------------------------------- text (6.1)

class TextRuleTests(unittest.TestCase):

    def test_offsets_are_utf16_after_characters_outside_the_bmp(self):
        # "😀" is one code point but two UTF-16 units: the mention starts at 2 + 1 = 3.
        text = "\U0001F600 @bob x"
        tweet = normalized_tweet(text, leg=legacy(text, entities={
            "user_mentions": [{"indices": [2, 6], "screen_name": "bob"}]}))
        self.assertEqual(tweet["text"], "\U0001F600 @bob x")
        self.assertEqual(tweet["entities"], [{"s": 3, "e": 7, "k": "mention", "v": "bob"}])

    def test_url_after_emoji_gets_utf16_offsets_of_the_display_form(self):
        text = "\U0001F600\U0001F600 https://t.co/AAAAAAAAAA"
        tweet = normalized_tweet(text, leg=legacy(text, entities={"urls": [url_entity(
            text, "https://t.co/AAAAAAAAAA", "https://t.co/AAAAAAAAAA", "https://example.com/a", "example.com/a")]}))
        self.assertEqual(tweet["text"], "\U0001F600\U0001F600 example.com/a")
        # two emoji (4 units) and a space (1) come first; "example.com/a" is 13 units
        self.assertEqual(tweet["entities"], [{"s": 5, "e": 18, "k": "url", "v": "https://example.com/a"}])

    def test_escapes_are_decoded_once(self):
        tweet = normalized_tweet("A &amp; B &lt;tag&gt; &amp;lt;")
        self.assertEqual(tweet["text"], "A & B <tag> &lt;")

    def test_link_in_the_middle_is_replaced_and_kept(self):
        text = "see https://t.co/AAAAAAAAAA now"
        tweet = normalized_tweet(text, leg=legacy(text, entities={"urls": [url_entity(
            text, "https://t.co/AAAAAAAAAA", "https://t.co/AAAAAAAAAA", "https://example.com/a", "example.com/a")]}))
        self.assertEqual(tweet["text"], "see example.com/a now")
        self.assertEqual(tweet["entities"], [{"s": 4, "e": 17, "k": "url", "v": "https://example.com/a"}])

    def test_leading_reply_mentions_are_hidden_and_feed_reply_to(self):
        text = "@alice_example @carol_test thanks!"
        leg = legacy(text, in_reply_to_status_id_str="2000000000000000099",
                     in_reply_to_screen_name="alice_example", display_text_range=[27, 34],
                     entities={"user_mentions": [
                         {"indices": [0, 14], "screen_name": "alice_example"},
                         {"indices": [15, 26], "screen_name": "carol_test"}]})
        tweet = n.normalize_tweet(tweet_result(text, leg=leg))
        self.assertEqual(tweet["text"], "thanks!")
        self.assertEqual(tweet["entities"], [])
        self.assertEqual(tweet["reply_to"], {"id": "2000000000000000099",
                                             "handles": ["alice_example", "carol_test"]})

    def test_attached_media_link_is_not_shown(self):
        text = "photo here https://t.co/MMMMMMMMMM"
        media = media_node(indices=[11, 34])
        leg = legacy(text, display_text_range=[0, 11], extended_entities={"media": [media]})
        tweet = n.normalize_tweet(tweet_result(text, leg=leg))
        self.assertEqual(tweet["text"], "photo here")
        self.assertEqual(tweet["entities"], [])
        self.assertEqual(tweet["media"][0]["type"], "photo")

    def test_media_link_inside_the_range_emits_nothing(self):
        text = "photo here https://t.co/MMMMMMMMMM"
        media = media_node(indices=[11, 34])
        leg = legacy(text, extended_entities={"media": [media]})  # range covers the whole text
        tweet = n.normalize_tweet(tweet_result(text, leg=leg))
        self.assertEqual(tweet["text"], "photo here")
        self.assertEqual(tweet["entities"], [])

    def test_card_link_at_the_end_is_dropped_but_a_link_in_the_middle_stays(self):
        card = {"legacy": {"name": "summary", "binding_values": [
            {"key": "card_url", "value": {"string_value": "https://t.co/CCCCCCCCCC", "type": "STRING"}}]}}
        text = "Headline here https://t.co/CCCCCCCCCC"
        leg = legacy(text, entities={"urls": [url_entity(
            text, "https://t.co/CCCCCCCCCC", "https://t.co/CCCCCCCCCC",
            "https://news.example.com/story", "news.example.com/story")]})
        tweet = n.normalize_tweet(tweet_result(text, leg=leg, card=card))
        self.assertEqual(tweet["text"], "Headline here")
        self.assertEqual(tweet["entities"], [])
        self.assertEqual(tweet["card"]["type"], "summary")

        text = "see https://t.co/CCCCCCCCCC for more"
        leg = legacy(text, entities={"urls": [url_entity(
            text, "https://t.co/CCCCCCCCCC", "https://t.co/CCCCCCCCCC",
            "https://news.example.com/story", "news.example.com/story")]})
        tweet = n.normalize_tweet(tweet_result(text, leg=leg, card=card))
        self.assertEqual(tweet["text"], "see news.example.com/story for more")
        # "news.example.com/story" is 22 units long
        self.assertEqual(tweet["entities"], [{"s": 4, "e": 26, "k": "url", "v": "https://news.example.com/story"}])

    def test_quote_link_at_the_end_is_dropped_only_for_the_quoted_post(self):
        quoted = tweet_result("quoted body", tid="2000000000000000001")
        text = "look https://t.co/QQQQQQQQQQ"
        leg = legacy(text, is_quote_status=True, quoted_status_id_str="2000000000000000001",
                     entities={"urls": [url_entity(text, "https://t.co/QQQQQQQQQQ", "https://t.co/QQQQQQQQQQ",
                                                   "https://x.com/someone/status/2000000000000000001",
                                                   "x.com/someone/sta…")]})
        tweet = n.normalize_tweet(tweet_result(text, leg=leg, quoted_status_result={"result": quoted}))
        self.assertEqual(tweet["text"], "look")
        self.assertEqual(tweet["entities"], [])
        self.assertEqual(tweet["quote"]["text"], "quoted body")

        # A longer status id only starts with the quoted id: that link is not the quote.
        display = "x.com/someone/sta…"
        leg = legacy(text, is_quote_status=True, quoted_status_id_str="2000000000000000001",
                     entities={"urls": [url_entity(text, "https://t.co/QQQQQQQQQQ", "https://t.co/QQQQQQQQQQ",
                                                   "https://x.com/someone/status/20000000000000000019", display)]})
        tweet = n.normalize_tweet(tweet_result(text, leg=leg, quoted_status_result={"result": quoted}))
        self.assertEqual(tweet["text"], "look " + display)
        self.assertEqual(tweet["entities"], [{"s": 5, "e": 5 + u16(display), "k": "url",
                                              "v": "https://x.com/someone/status/20000000000000000019"}])

    def test_bad_indices_and_overlaps_are_skipped(self):
        text = "hello @bob and #tag"
        leg = legacy(text, entities={
            "user_mentions": [{"indices": [6, 10], "screen_name": "bob"},
                              {"indices": [6, 13], "screen_name": "longer"}],
            "hashtags": [{"indices": [15, 19], "text": "tag"}],
            "urls": [{"indices": [9, 3], "url": "https://t.co/x", "expanded_url": "https://bad.example/", "display_url": "bad"},
                     {"indices": [0, 999], "url": "https://t.co/y", "expanded_url": "https://bad.example/", "display_url": "bad"}],
        })
        tweet = n.normalize_tweet(tweet_result(text, leg=leg))
        self.assertEqual(tweet["text"], text)
        self.assertEqual(tweet["entities"], [
            {"s": 6, "e": 10, "k": "mention", "v": "bob"},
            {"s": 15, "e": 19, "k": "hashtag", "v": "tag"},
        ])

    def test_entity_whose_text_lacks_its_sigil_is_skipped(self):
        tweet = normalized_tweet("bob x", leg=legacy("bob x", entities={
            "user_mentions": [{"indices": [0, 3], "screen_name": "bob"}]}))
        self.assertEqual(tweet["text"], "bob x")
        self.assertEqual(tweet["entities"], [])

    def test_long_post_uses_the_note_text_and_its_entity_set(self):
        note = "A long note \U0001F4DD about #topic and more words here."
        short = "A long note \U0001F4DD about #topic https://t.co/LONGLINK1"
        tweet = n.normalize_tweet(tweet_result(
            short, leg=legacy(short, display_text_range=[0, 40]),
            note_tweet={"is_expandable": True, "note_tweet_results": {"result": {
                "id": "n1", "text": note,
                "entity_set": {"hashtags": [{"indices": [20, 26], "text": "topic"}],
                               "urls": [], "user_mentions": [], "symbols": []}}}}))
        self.assertTrue(tweet["long"])
        self.assertEqual(tweet["text"], note)
        # "A long note 📝 about " is 21 units (the emoji counts twice)
        self.assertEqual(tweet["entities"], [{"s": 21, "e": 27, "k": "hashtag", "v": "topic"}])

    def test_long_post_keeps_its_media_from_the_legacy_part(self):
        short = "see the picture https://t.co/LONGLINK1"
        leg = legacy(short, display_text_range=[0, len(short)],
                     extended_entities={"media": [media_node(url="https://pbs.twimg.com/media/LONG.jpg")]})
        tweet = n.normalize_tweet(tweet_result(
            short, leg=leg,
            note_tweet={"note_tweet_results": {"result": {"id": "n3", "text": "the whole long text",
                                                          "entity_set": {"hashtags": [], "urls": [],
                                                                         "user_mentions": [], "symbols": []}}}}))
        self.assertTrue(tweet["long"])
        self.assertEqual(tweet["text"], "the whole long text")
        self.assertEqual([m["url"] for m in tweet["media"]], ["https://pbs.twimg.com/media/LONG.jpg"])

    def test_long_reply_drops_the_mentions_the_note_repeats(self):
        short = "@alice_example long reply"
        note = "@alice_example long reply body"
        tweet = n.normalize_tweet(tweet_result(
            short, leg=legacy(short, in_reply_to_status_id_str="2000000000000000099",
                              in_reply_to_screen_name="alice_example", display_text_range=[15, 25]),
            note_tweet={"note_tweet_results": {"result": {"id": "n2", "text": note,
                                                          "entity_set": {"hashtags": [], "urls": [],
                                                                         "user_mentions": [], "symbols": []}}}}))
        self.assertEqual(tweet["text"], "long reply body")
        self.assertTrue(tweet["long"])

    def test_source_is_reduced_to_its_text(self):
        source = '<a href="https://example.com/app" rel="nofollow">Example App</a>'
        self.assertEqual(normalized_tweet("x", source=source)["source"], "Example App")
        self.assertIsNone(normalized_tweet("x")["source"])

    def test_odd_types_in_legacy_do_not_stop_the_tweet(self):
        leg = legacy("hi there", display_text_range="abc", entities=None,
                     user_mentions="nope")
        tweet = n.normalize_tweet(tweet_result("hi there", leg=leg))
        self.assertEqual(tweet["text"], "hi there")
        self.assertEqual(tweet["entities"], [])
        self.assertIsNone(tweet["reply_to"])


# ---------------------------------------------------------------- tweet fields

class TweetFieldTests(unittest.TestCase):

    def test_every_documented_key_is_present(self):
        tweet = normalized_tweet("hello")
        self.assertEqual(sorted(tweet.keys()), sorted(TWEET_KEYS))
        self.assertEqual(sorted(tweet["user"].keys()), sorted(USER_KEYS))

    def test_counts_flags_and_times(self):
        tweet = normalized_tweet("hello")
        self.assertEqual((tweet["reply_count"], tweet["retweet_count"], tweet["like_count"],
                          tweet["quote_count"], tweet["bookmark_count"]), (13, 12, 11, 14, 15))
        self.assertEqual(tweet["created_at"], 1794811738)  # Mon Nov 16 06:48:58 +0000 2026
        self.assertEqual(tweet["view_count"], None)
        leg = legacy("hello", favorited=True, retweeted=True, bookmarked=True, possibly_sensitive=True)
        tweet = n.normalize_tweet(tweet_result("hello", leg=leg, views={"count": "134034"}))
        self.assertEqual((tweet["liked"], tweet["retweeted"], tweet["bookmarked"], tweet["sensitive"]),
                         (True, True, True, True))
        self.assertEqual(tweet["view_count"], 134034)

    def test_created_at_with_a_zone_offset(self):
        leg = legacy("hello", created_at="Tue Nov 17 09:00:00 +0900 2026")
        self.assertEqual(n.normalize_tweet(tweet_result("hello", leg=leg))["created_at"], 1794873600)

    def test_edited_when_more_than_one_id(self):
        self.assertFalse(normalized_tweet("x")["edited"])
        edited = tweet_result("x", edit_control={"edit_tweet_ids": ["2000000000000000100", "2000000000000000101"]})
        self.assertTrue(n.normalize_tweet(edited)["edited"])
        nested = tweet_result("x", edit_control={"edit_tweet_ids": ["2000000000000000100"],
                                                 "edit_control_initial": {"edit_tweet_ids": ["2000000000000000100", "2000000000000000101"]}})
        self.assertTrue(n.normalize_tweet(nested)["edited"])

    def test_place_and_language(self):
        tweet = n.normalize_tweet(tweet_result("x", place={"full_name": "東京 世田谷区"}))
        self.assertEqual(tweet["place"], "東京 世田谷区")
        self.assertEqual(n.normalize_tweet(tweet_result("x", leg=legacy("x", lang="ja")))["lang"], "ja")
        self.assertEqual(normalized_tweet("x")["lang"], "en")
        self.assertIsNone(normalized_tweet("x")["place"])

    def test_restricted_replies(self):
        wrapped = {"__typename": "TweetWithVisibilityResults",
                   "tweet": tweet_result("x", typename=None),
                   "limitedActionResults": {"limited_actions": [{"action": "Reply"}]}}
        self.assertTrue(n.normalize_tweet(wrapped)["reply_limited"])
        self.assertFalse(normalized_tweet("x")["reply_limited"])

    def test_visibility_wrapper_gives_the_tweet(self):
        wrapped = {"__typename": "TweetWithVisibilityResults", "tweet": tweet_result("inside", typename=None)}
        tweet = n.normalize_tweet(wrapped)
        self.assertEqual(tweet["text"], "inside")
        self.assertEqual(tweet["id"], "2000000000000000100")

    def test_unshowable_results_are_none(self):
        self.assertIsNone(n.normalize_tweet({"__typename": "TweetTombstone", "tombstone": {"text": {"text": "x"}}}))
        self.assertIsNone(n.normalize_tweet({"__typename": "TweetUnavailable", "reason": "Protected"}))
        without_legacy = tweet_result("x")
        without_legacy["legacy"] = None
        self.assertIsNone(n.normalize_tweet(without_legacy))
        without_user = tweet_result("x")
        without_user["core"] = {}
        self.assertIsNone(n.normalize_tweet(without_user))
        unavailable_user = tweet_result("x", author={"__typename": "UserUnavailable", "rest_id": "5"})
        self.assertIsNone(n.normalize_tweet(unavailable_user))


# ---------------------------------------------------------------- users (5.3, 2.1)

class UserTests(unittest.TestCase):

    def test_new_shape_fields(self):
        out = n.normalize_user(user_result(is_blue_verified=True))
        self.assertEqual(sorted(out.keys()), sorted(USER_KEYS))
        self.assertEqual(out["id"], "1000000000000000001")
        self.assertEqual(out["name"], "Alice Example")
        self.assertEqual(out["handle"], "alice_example")
        self.assertEqual(out["avatar"], "https://pbs.twimg.com/profile_images/1/alice_normal.jpg")
        self.assertEqual(out["verified"], "blue")
        self.assertFalse(out["square"])
        self.assertFalse(out["following"])
        self.assertIsNone(out["label"])

    def test_verification_kinds(self):
        cases = [
            (user_result(is_blue_verified=True), "blue"),
            (user_result(is_blue_verified=True, verification={"verified": False, "verified_type": "Business"}), "business"),
            (user_result(is_blue_verified=False, verification={"verified": False, "verified_type": "Government"}), "government"),
            (user_result(is_blue_verified=False), None),
            ({"rest_id": "1", "legacy": {"screen_name": "old", "name": "Old", "verified": True}}, "blue"),
            ({"rest_id": "2", "legacy": {"screen_name": "biz", "name": "Biz", "verified": True, "verified_type": "Business"}}, "business"),
        ]
        for node, expected in cases:
            self.assertEqual(n.normalize_user(node)["verified"], expected, node)

    def test_square_avatar_for_business_accounts(self):
        self.assertTrue(n.normalize_user(user_result(profile_image_shape="Square"))["square"])
        self.assertFalse(n.normalize_user(user_result(profile_image_shape="Circle"))["square"])
        self.assertFalse(n.normalize_user(user_result(profile_image_shape=None))["square"])

    def test_affiliate_label(self):
        label = {"label": {"description": "OpenAI", "badge": {"url": "https://pbs.twimg.com/x_bigger.jpg"},
                           "url": {"url": "https://twitter.com/OpenAI"}}}
        out = n.normalize_user(user_result(affiliates_highlighted_label=label))
        self.assertEqual(out["label"], {"text": "OpenAI", "badge": "https://pbs.twimg.com/x_bigger.jpg"})
        self.assertIsNone(n.normalize_user(user_result(affiliates_highlighted_label={}))["label"])
        self.assertIsNone(n.normalize_user(user_result(affiliates_highlighted_label={"label": {"badge": {"url": "x"}}}))["label"])

    def test_legacy_shape_for_full_users(self):
        node = {"rest_id": "1000000000000000005", "legacy": {
            "name": "Legacy Name", "screen_name": "legacy_user",
            "profile_image_url_https": "https://pbs.twimg.com/profile_images/5/l_normal.jpg",
            "verified": True, "protected": True, "followers_count": 42, "friends_count": 7,
            "statuses_count": 99, "media_count": 4, "favourites_count": 5, "description": "Legacy bio",
            "location": "Osaka", "profile_banner_url": "https://pbs.twimg.com/profile_banners/5/1",
            "created_at": "Tue Mar 04 10:00:00 +0000 2014", "following": True, "followed_by": False,
            "pinned_tweet_ids_str": ["2000000000000000100"]}}
        out = n.normalize_user(node, full=True)
        self.assertEqual(sorted(out.keys()), sorted(FULL_USER_KEYS))
        self.assertEqual((out["name"], out["handle"], out["verified"], out["protected"]),
                         ("Legacy Name", "legacy_user", "blue", True))
        self.assertEqual((out["following"], out["followed_by"]), (True, False))
        self.assertEqual((out["followers"], out["friends"], out["tweets"], out["media_count"], out["likes_count"]),
                         (42, 7, 99, 4, 5))
        self.assertEqual((out["bio"], out["location"]), ("Legacy bio", "Osaka"))
        self.assertEqual(out["banner"], "https://pbs.twimg.com/profile_banners/5/1")
        self.assertEqual(out["joined"], 1393927200)
        self.assertEqual(out["pinned_ids"], ["2000000000000000100"])

    def test_full_user_bio_links_and_counts(self):
        bio = "Writer & coder, see https://t.co/BIOLINK123"
        node = user_result(
            profile_bio={"description": bio, "entities": {
                "description": {"urls": [{"indices": [20, 43], "url": "https://t.co/BIOLINK123",
                                          "display_url": "example.org/me", "expanded_url": "https://example.org/me"}]},
                "url": {"urls": [{"indices": [0, 23], "url": "https://t.co/PROFILE",
                                  "display_url": "example.org", "expanded_url": "https://example.org/"}]}}},
            location={"location": "  Osaka  "},
            banner={"image_url": "https://pbs.twimg.com/profile_banners/1/2"},
            relationship_counts={"followers": 1200, "following": 34},
            tweet_counts={"tweets": 5000, "media_tweets": 300},
            action_counts={"favorites_count": 77},
            pinned_items={"tweet_ids_str": ["2000000000000000100"]},
            follow_request_sent=True)
        out = n.normalize_user(node, full=True)
        self.assertEqual(sorted(out.keys()), sorted(FULL_USER_KEYS))
        # "&" stays: profile text is not HTML-escaped by X. The link is replaced by its display form.
        self.assertEqual(out["bio"], "Writer & coder, see example.org/me")
        self.assertEqual(out["bio_entities"], [{"s": 20, "e": 34, "k": "url", "v": "https://example.org/me"}])
        self.assertEqual(out["url"], {"display": "example.org", "expanded": "https://example.org/"})
        self.assertEqual(out["location"], "Osaka")
        self.assertEqual(out["banner"], "https://pbs.twimg.com/profile_banners/1/2")
        self.assertEqual((out["followers"], out["friends"], out["tweets"], out["media_count"], out["likes_count"]),
                         (1200, 34, 5000, 300, 77))
        self.assertEqual(out["pinned_ids"], ["2000000000000000100"])
        self.assertTrue(out["follow_request_sent"])
        self.assertEqual(out["joined"], 1393927200)

    def test_unusable_users_are_none(self):
        self.assertIsNone(n.normalize_user({"__typename": "UserUnavailable", "rest_id": "5"}))
        self.assertIsNone(n.normalize_user({"core": {"screen_name": "no_id", "name": "No Id"}}))
        self.assertIsNone(n.normalize_user({"rest_id": "5", "core": {"name": "no handle"}}))
        self.assertIsNone(n.normalize_user(None))
        self.assertIsNone(n.normalize_user("text"))


# ---------------------------------------------------------------- media (2.3, 6.2)

class MediaTests(unittest.TestCase):

    def media_of(self, *nodes, **legacy_extra):
        leg = legacy("pictures", extended_entities={"media": list(nodes)}, **legacy_extra)
        return n.normalize_tweet(tweet_result("pictures", leg=leg))["media"]

    def test_photo(self):
        media = self.media_of(media_node(alt_text=None, ext_alt_text="A cat"))
        self.assertEqual(media, [{"type": "photo", "url": "https://pbs.twimg.com/media/ABCDEF.jpg",
                                  "w": 800, "h": 600, "alt": "A cat", "video": None}])

    def test_video_takes_the_best_mp4_under_1_3_mbps(self):
        info = {"aspect_ratio": [16, 9], "duration_millis": 19919, "variants": [
            {"content_type": "application/x-mpegURL", "url": "https://video.twimg.com/a/pl/x.m3u8"},
            {"bitrate": 320000, "content_type": "video/mp4", "url": "https://video.twimg.com/a/320.mp4"},
            {"bitrate": 832000, "content_type": "video/mp4", "url": "https://video.twimg.com/a/832.mp4"},
            {"bitrate": 2176000, "content_type": "video/mp4", "url": "https://video.twimg.com/a/2176.mp4"},
        ]}
        media = self.media_of(media_node("video", video_info=info))
        self.assertEqual(media[0]["type"], "video")
        self.assertEqual(media[0]["video"], {"mp4": "https://video.twimg.com/a/832.mp4",
                                             "hls": "https://video.twimg.com/a/pl/x.m3u8",
                                             "duration_ms": 19919, "aspect": [16, 9]})

    def test_video_above_the_ceiling_takes_the_lowest_mp4(self):
        info = {"aspect_ratio": [9, 16], "variants": [
            {"bitrate": 2176000, "content_type": "video/mp4", "url": "https://video.twimg.com/a/big.mp4"},
            {"bitrate": 1500000, "content_type": "video/mp4", "url": "https://video.twimg.com/a/mid.mp4"},
        ]}
        media = self.media_of(media_node("video", video_info=info))
        self.assertEqual(media[0]["video"]["mp4"], "https://video.twimg.com/a/mid.mp4")
        self.assertIsNone(media[0]["video"]["hls"])
        self.assertEqual(media[0]["video"]["duration_ms"], 0)

    def test_animated_gif_has_one_mp4(self):
        info = {"aspect_ratio": [1, 1], "variants": [
            {"bitrate": 0, "content_type": "video/mp4", "url": "https://video.twimg.com/tweet_video/X.mp4"}]}
        media = self.media_of(media_node("animated_gif", video_info=info))
        self.assertEqual(media[0]["type"], "gif")
        self.assertEqual(media[0]["video"]["mp4"], "https://video.twimg.com/tweet_video/X.mp4")

    def test_extended_entities_win_and_unknown_media_is_skipped(self):
        plain = media_node(url="https://pbs.twimg.com/media/PLAIN.jpg")
        leg = legacy("pictures", entities={"media": [plain]},
                     extended_entities={"media": [media_node(url="https://pbs.twimg.com/media/A.jpg"),
                                                  media_node(url="https://pbs.twimg.com/media/B.jpg"),
                                                  media_node(kind="chart", url="https://pbs.twimg.com/media/C.jpg"),
                                                  media_node(url="")]})
        media = n.normalize_tweet(tweet_result("pictures", leg=leg))["media"]
        self.assertEqual([m["url"] for m in media],
                         ["https://pbs.twimg.com/media/A.jpg", "https://pbs.twimg.com/media/B.jpg"])

    def test_plain_entities_media_is_used_without_extended(self):
        leg = legacy("pictures", entities={"media": [media_node(url="https://pbs.twimg.com/media/P.jpg")]})
        media = n.normalize_tweet(tweet_result("pictures", leg=leg))["media"]
        self.assertEqual(media[0]["url"], "https://pbs.twimg.com/media/P.jpg")


# ---------------------------------------------------------------- quotes and reposts (6.2)

class QuoteAndRepostTests(unittest.TestCase):

    def quoting(self, quoted_result=None, **extra):
        text = "my take https://t.co/QQQQQQQQQQ"
        leg = legacy(text, is_quote_status=True, quoted_status_id_str="2000000000000000002",
                     entities={"urls": [url_entity(text, "https://t.co/QQQQQQQQQQ", "https://t.co/QQQQQQQQQQ",
                                                   "https://x.com/bob_sample/status/2000000000000000002",
                                                   "x.com/bob_sample/sta…")]})
        node = tweet_result(text, leg=leg, **extra)
        if quoted_result is not None:
            node["quoted_status_result"] = {"result": quoted_result}
        return n.normalize_tweet(node)

    def test_normal_quote(self):
        bob = user_result(uid="1000000000000000002", name="Bob Sample", handle="bob_sample")
        quoted = tweet_result("quoted post", tid="2000000000000000002", author=bob)
        tweet = self.quoting(quoted)
        self.assertEqual(tweet["text"], "my take")
        self.assertEqual(tweet["quote"]["id"], "2000000000000000002")
        self.assertEqual(tweet["quote"]["user"]["handle"], "bob_sample")
        self.assertIsNone(tweet["quote"]["quote"])
        self.assertIsNone(tweet["quote"]["quote_unavailable"])
        self.assertIsNone(tweet["quote_unavailable"])

    def test_tombstoned_quote_gives_the_tombstone_text(self):
        tombstone = {"__typename": "TweetTombstone", "tombstone": {"text": {"text": "削除されたポスト"}}}
        tweet = self.quoting(tombstone)
        self.assertIsNone(tweet["quote"])
        self.assertEqual(tweet["quote_unavailable"], "削除されたポスト")

    def test_missing_quote_is_unavailable(self):
        tweet = self.quoting(None)
        self.assertIsNone(tweet["quote"])
        self.assertEqual(tweet["quote_unavailable"], UNAVAILABLE)

    def test_quote_of_a_quote_is_only_one_level(self):
        inner = tweet_result("inner", tid="2000000000000000003")
        middle = tweet_result("middle", tid="2000000000000000002")
        middle["quoted_status_result"] = {"result": inner}
        tweet = self.quoting(middle)
        self.assertEqual(tweet["quote"]["text"], "middle")
        self.assertIsNone(tweet["quote"]["quote"])
        self.assertIsNone(tweet["quote"]["quote_unavailable"])

    def test_full_quote_under_nested_quoted_tweet_results_is_used(self):
        # Some answers carry the quoted post here and only a reference under quotedRefResult.
        text = "my take https://t.co/QQQQQQQQQQ"
        leg = legacy(text, is_quote_status=True, quoted_status_id_str="2000000000000000002",
                     entities={"urls": [url_entity(text, "https://t.co/QQQQQQQQQQ", "https://t.co/QQQQQQQQQQ",
                                                   "https://x.com/bob_sample/status/2000000000000000002",
                                                   "x.com/bob_sample/sta…")]})
        node = tweet_result(text, leg=leg)
        node["quotedRefResult"] = {"result": {"__typename": "Tweet", "rest_id": "2000000000000000002"}}
        node["nested_quoted_tweet_results"] = {"result": tweet_result("nested body", tid="2000000000000000002")}
        tweet = n.normalize_tweet(node)
        self.assertEqual(tweet["quote"]["text"], "nested body")
        self.assertIsNone(tweet["quote_unavailable"])

    def test_nested_result_with_another_id_is_not_taken(self):
        node = tweet_result("my take", leg=legacy("my take", is_quote_status=True, quoted_status_id_str="2000000000000000002"))
        node["nested_quoted_tweet_results"] = {"result": tweet_result("other", tid="2000000000000000009")}
        tweet = n.normalize_tweet(node)
        self.assertIsNone(tweet["quote"])
        self.assertEqual(tweet["quote_unavailable"], UNAVAILABLE)

    def test_repost_shows_the_original_with_retweeted_by(self):
        original = tweet_result("Original text", tid="2000000000000000004",
                                author=user_result(uid="1000000000000000002", name="Bob Sample", handle="bob_sample"))
        dave = user_result(uid="1000000000000000004", name="Dave Demo", handle="dave_demo")
        repost = tweet_result("RT @bob_sample: Original tex…", tid="2000000000000000005", author=dave,
                              leg=legacy("RT @bob_sample: Original tex…",
                                         retweeted_status_result={"result": original},
                                         favorite_count=900))
        tweet = n.normalize_tweet(repost)
        self.assertEqual(tweet["id"], "2000000000000000004")
        self.assertEqual(tweet["text"], "Original text")
        self.assertEqual(tweet["user"]["handle"], "bob_sample")
        self.assertEqual(tweet["retweeted_by"]["handle"], "dave_demo")
        self.assertEqual(tweet["retweet_id"], "2000000000000000005")
        self.assertEqual(tweet["like_count"], 11)  # the original's counts, not the repost's

    def test_repost_of_a_tombstone_is_not_shown(self):
        repost = tweet_result("RT @x: gone", tid="2000000000000000005",
                              leg=legacy("RT @x: gone", retweeted_status_result={"result": {
                                  "__typename": "TweetTombstone", "tombstone": {"text": {"text": "消えた"}}}}))
        self.assertIsNone(n.normalize_tweet(repost))
        result = n.normalize_timeline(answer(add(item_entry("tweet-5", tweet_item(repost)))))
        self.assertEqual(result["items"], [{"t": "tombstone", "text": "消えた", "above": False, "below": False}])


# ---------------------------------------------------------------- cards (5.2, 2.4)

def card_of(name, bindings, legacy_url=None, rest_id="2000000000000000050"):
    card = {"legacy": {"name": name, "binding_values": bindings}, "rest_id": rest_id}
    if legacy_url is not None:
        card["legacy"]["url"] = legacy_url
    return card


def bv_string(key, value):
    return {"key": key, "value": {"string_value": value, "type": "STRING"}}


def bv_image(key, url, width, height):
    return {"key": key, "value": {"image_value": {"url": url, "width": width, "height": height}, "type": "IMAGE"}}


class CardTests(unittest.TestCase):
    TCO = "https://t.co/CCCCCCCCCC"

    def card_tweet(self, card, text="Read this"):
        leg = legacy(text + " " + self.TCO, entities={"urls": [url_entity(
            text + " " + self.TCO, self.TCO, self.TCO, "https://www.example.org/news/1", "example.org/news/1")]})
        return n.normalize_tweet(tweet_result(text + " " + self.TCO, leg=leg, card=card))

    def test_summary_prefers_the_large_thumbnail(self):
        card = card_of("summary", [
            bv_string("card_url", self.TCO),
            bv_string("title", "A title"),
            bv_string("description", "A description"),
            bv_string("vanity_url", "example.org"),
            bv_image("photo_image_full_size_large", "https://pbs.twimg.com/card_img/1/full?format=jpg&name=800x419", 800, 419),
            bv_image("thumbnail_image_large", "https://pbs.twimg.com/card_img/1/thumb?format=jpg&name=800x320_1", 569, 320),
        ])
        shown = self.card_tweet(card)["card"]
        self.assertEqual(shown, {"type": "summary", "url": "https://www.example.org/news/1",
                                 "domain": "example.org", "title": "A title", "description": "A description",
                                 "image": {"url": "https://pbs.twimg.com/card_img/1/thumb?format=jpg&name=800x320_1",
                                           "w": 569, "h": 320},
                                 "poll": None})

    def test_summary_large_image_prefers_the_full_size_photo(self):
        card = card_of("summary_large_image", [
            bv_string("card_url", self.TCO),
            bv_string("domain", "www.example.org"),
            bv_image("summary_photo_image_large", "https://pbs.twimg.com/card_img/2/s?format=jpg&name=800x419", 800, 419),
            bv_image("photo_image_full_size_large", "https://pbs.twimg.com/card_img/2/p?format=jpg&name=800x419", 800, 419),
        ])
        shown = self.card_tweet(card)["card"]
        self.assertEqual(shown["type"], "summary_large_image")
        self.assertEqual(shown["domain"], "example.org")  # www. is dropped
        self.assertEqual(shown["image"]["url"], "https://pbs.twimg.com/card_img/2/p?format=jpg&name=800x419")

    def test_player_card(self):
        card = card_of("player", [
            bv_string("card_url", self.TCO),
            bv_string("player_url", "https://www.youtube.com/embed/xyz"),
            bv_string("vanity_url", "youtube.com"),
            bv_image("player_image_large", "https://pbs.twimg.com/card_img/3/p?format=jpg&name=800x320_1", 569, 320),
        ])
        shown = self.card_tweet(card)["card"]
        self.assertEqual(shown["type"], "player")
        self.assertEqual(shown["domain"], "youtube.com")
        self.assertEqual(shown["image"]["w"], 569)

    def test_domain_falls_back_to_the_destination_host_without_www(self):
        card = card_of("summary", [bv_string("card_url", self.TCO)])
        shown = self.card_tweet(card)["card"]
        self.assertEqual(shown["domain"], "example.org")  # host www.example.org, www. dropped
        self.assertIsNone(shown["image"])

    def test_poll(self):
        card = card_of("poll2choice_text_only", [
            bv_string("choice1_label", "Yes"), bv_string("choice1_count", "10"),
            bv_string("choice2_label", "No"), bv_string("choice2_count", "5"),
            bv_string("end_datetime_utc", "2026-11-17T06:48:58Z"),
            {"key": "counts_are_final", "value": {"boolean_value": True, "type": "BOOLEAN"}},
        ])
        shown = self.card_tweet(card)["card"]
        self.assertEqual(shown, {"type": "poll", "url": "", "domain": "", "title": "", "description": "",
                                 "image": None,
                                 "poll": {"choices": [{"label": "Yes", "count": 10}, {"label": "No", "count": 5}],
                                          "total": 15, "ends_at": 1794898138, "final": True}})

    def test_poll_with_four_choices_and_prefixed_name(self):
        bindings = []
        for index in range(1, 5):
            bindings.append(bv_string("choice%d_label" % index, "c%d" % index))
            bindings.append(bv_string("choice%d_count" % index, str(index)))
        shown = self.card_tweet(card_of("3691233323:poll4choice_image", bindings))["card"]
        self.assertEqual(len(shown["poll"]["choices"]), 4)
        self.assertEqual(shown["poll"]["total"], 10)
        self.assertEqual(shown["poll"]["ends_at"], 0)
        self.assertFalse(shown["poll"]["final"])

    def test_prefixed_summary_name_is_recognised(self):
        card = card_of("3691233323:summary", [bv_string("card_url", self.TCO)])
        self.assertEqual(self.card_tweet(card)["card"]["type"], "summary")

    def test_other_card_types_are_not_shown(self):
        self.assertIsNone(self.card_tweet(card_of("unified_card", [bv_string("card_url", self.TCO)]))["card"])
        self.assertIsNone(self.card_tweet(card_of("3691233323:audiospace", []))["card"])

    def test_card_reference_without_a_body_is_not_shown(self):
        self.assertIsNone(self.card_tweet({"rest_id": "https://t.co/xyz"})["card"])


# ---------------------------------------------------------------- timeline (5.1, 6.3)

class TimelineTests(unittest.TestCase):

    def test_pinned_post_comes_first_with_the_pin_context(self):
        pinned = tweet_result("pinned", tid="2000000000000000201")
        other = tweet_result("other", tid="2000000000000000202")
        social = {"type": "TimelineGeneralContext", "contextType": "Pin", "text": "固定"}
        data = answer(add(item_entry("tweet-202", tweet_item(other))),
                      {"type": "TimelinePinEntry", "entry": item_entry("tweet-201", tweet_item(pinned, socialContext=social))})
        result = n.normalize_timeline(data)
        self.assertEqual(tweet_ids(result), ["2000000000000000201", "2000000000000000202"])
        self.assertEqual(result["items"][0]["context"], {"k": "pin", "text": "固定"})
        self.assertIsNone(result["items"][1]["context"])

    def test_pin_without_social_context_still_gets_the_pin_line(self):
        pinned = tweet_result("pinned", tid="2000000000000000201")
        data = answer({"type": "TimelinePinEntry", "entry": item_entry("tweet-201", tweet_item(pinned))})
        self.assertEqual(n.normalize_timeline(data)["items"][0]["context"], {"k": "pin", "text": "固定"})

    def test_other_social_context_becomes_a_text_line_unless_it_is_a_repost(self):
        social = {"type": "TimelineGeneralContext", "contextType": "Like", "text": "Bob liked this"}
        liked = tweet_result("liked", tid="2000000000000000301")
        result = n.normalize_timeline(answer(add(item_entry("tweet-301", tweet_item(liked, socialContext=social)))))
        self.assertEqual(result["items"][0]["context"], {"k": "text", "text": "Bob liked this"})

        original = tweet_result("orig", tid="2000000000000000302")
        repost = tweet_result("RT @x: orig", tid="2000000000000000303",
                              leg=legacy("RT @x: orig", retweeted_status_result={"result": original}))
        result = n.normalize_timeline(answer(add(item_entry("tweet-303", tweet_item(repost, socialContext=social)))))
        self.assertIsNone(result["items"][0]["context"])
        self.assertEqual(result["items"][0]["tweet"]["retweeted_by"]["handle"], "alice_example")

    def test_add_to_module_continues_a_conversation(self):
        first = tweet_result("first", tid="2000000000000000401")
        second = tweet_result("second", tid="2000000000000000402")
        data = answer(
            add(module_entry("home-conversation-1", "VerticalConversation",
                             [module_item("c1-a", tweet_item(first))])),
            {"type": "TimelineAddToModule", "moduleEntryId": "home-conversation-1",
             "moduleItems": [module_item("c1-b", tweet_item(second))]})
        items = items_of(n.normalize_timeline(data))
        self.assertEqual([item["tweet"]["id"] for item in items], ["2000000000000000401", "2000000000000000402"])
        self.assertEqual((items[0]["above"], items[0]["below"]), (False, True))
        self.assertEqual((items[1]["above"], items[1]["below"]), (True, False))

    def test_replace_entry_replaces_the_cursor_and_last_wins(self):
        data = answer(add(cursor_entry("cursor-bottom-1", "Bottom", "B1"),
                          item_entry("tweet-501", tweet_item(tweet_result("x", tid="2000000000000000501")))),
                      {"type": "TimelineReplaceEntry", "entry": cursor_entry("cursor-bottom-2", "Bottom", "B2")})
        self.assertEqual(n.normalize_timeline(data)["bottom"], "B2")

    def test_terminate_bottom_clears_the_bottom_cursor(self):
        data = answer(add(cursor_entry("t", "Top", "T1"), cursor_entry("b", "Bottom", "B1"),
                          item_entry("tweet-601", tweet_item(tweet_result("x", tid="2000000000000000601")))),
                      {"type": "TimelineTerminateTimeline", "direction": "Bottom"})
        result = n.normalize_timeline(data)
        self.assertIsNone(result["bottom"])
        self.assertEqual(result["top"], "T1")
        self.assertEqual(len(result["items"]), 1)

    def test_terminate_top_leaves_the_top_cursor_as_sent(self):
        data = answer(add(cursor_entry("t", "Top", "T1"),
                          item_entry("tweet-602", tweet_item(tweet_result("x", tid="2000000000000000602")))),
                      {"type": "TimelineTerminateTimeline", "direction": "Top"})
        self.assertEqual(n.normalize_timeline(data)["top"], "T1")

    def test_show_more_cursors_become_rows_and_others_are_ignored(self):
        data = answer(add(
            cursor_entry("more-1", "ShowMoreThreads", "M1", displayTreatment={"actionText": "もっと見る"}),
            cursor_entry("more-2", "ShowMore", "M2"),
            cursor_entry("gap", "Gap", "G1"),
            cursor_entry("empty", "ShowMore", ""),
            cursor_entry("top-empty", "Top", ""),
            item_entry("tweet-701", tweet_item(tweet_result("x", tid="2000000000000000701")))))
        items = items_of(n.normalize_timeline(data))
        self.assertEqual(items[0], {"t": "more", "cursor": "M1", "label": "もっと見る"})
        self.assertEqual(items[1], {"t": "more", "cursor": "M2", "label": "返信をさらに表示"})
        self.assertEqual(items[2]["t"], "tweet")
        self.assertEqual(len(items), 3)

    def test_module_header_only_heads_real_content(self):
        post = tweet_result("module post", tid="2000000000000000801")
        with_content = module_entry("vertical-1", "Vertical", [module_item("v-1", tweet_item(post))],
                                    header={"text": "おすすめ投稿"})
        only_ads = module_entry("vertical-2", "Vertical", [module_item("v-2", tweet_item(post, promotedMetadata={}))],
                                header={"text": "広告の見出し"})
        users = module_entry("who-to-follow-1", "Vertical", [module_item("u-1", {
            "itemType": "TimelineUser", "__typename": "TimelineUser", "user_results": {"result": user_result()}})],
            header={"text": "おすすめユーザー"})
        items = items_of(n.normalize_timeline(answer(add(with_content, only_ads, users))))
        self.assertEqual([item["t"] for item in items], ["header", "tweet"])
        self.assertEqual(items[0], {"t": "header", "text": "おすすめ投稿"})

    def test_conversation_module_is_joined_and_grid_is_plain(self):
        a = tweet_result("a", tid="2000000000000000811")
        b = tweet_result("b", tid="2000000000000000812")
        c = tweet_result("c", tid="2000000000000000813")
        data = answer(add(
            module_entry("profile-conversation-1", "VerticalConversation",
                         [module_item("pc-a", tweet_item(a)), cursor_item("pc-more", "ShowMore", "MORE"),
                          module_item("pc-b", tweet_item(b))]),
            module_entry("profile-grid-1", "VerticalGrid", [module_item("pg-c", tweet_item(c))])))
        items = items_of(n.normalize_timeline(data))
        self.assertEqual([item["t"] for item in items], ["tweet", "more", "tweet", "tweet"])
        self.assertEqual((items[0]["above"], items[0]["below"]), (False, True))
        self.assertEqual((items[2]["above"], items[2]["below"]), (True, False))
        self.assertEqual((items[3]["above"], items[3]["below"]), (False, False))

    def test_ads_are_dropped_at_the_top_and_inside_modules(self):
        ad = tweet_result("buy", tid="2000000000000000821")
        organic = tweet_result("organic", tid="2000000000000000822")
        data = answer(add(
            item_entry("promoted-tweet-821", tweet_item(ad, promotedMetadata={"advertiser_results": {}})),
            module_entry("home-conversation-2", "VerticalConversation", [
                module_item("hc-ad", tweet_item(ad, promotedMetadata={})),
                module_item("hc-org", tweet_item(organic))]),
            module_entry("conversationthread-3", "VerticalConversation", [
                module_item("ct-ad", tweet_item(ad, promotedMetadata={}))]),
        ))
        result = n.normalize_timeline(data)
        self.assertEqual(tweet_ids(result), ["2000000000000000822"])
        self.assertEqual(len(result["items"]), 1)
        self.assertEqual((result["items"][0]["above"], result["items"][0]["below"]), (False, False))

    def test_tombstones_and_missing_results(self):
        deleted = {"__typename": "TweetTombstone", "tombstone": {"text": {"text": "このポストは削除されました。"}}}
        unavailable = {"__typename": "TweetUnavailable", "reason": "Protected"}
        data = answer(add(
            item_entry("tweet-901", tweet_item(deleted)),
            item_entry("tweet-902", tweet_item(unavailable)),
            item_entry("tweet-903", tweet_item(None)),
            item_entry("tweet-904", {"itemType": "TimelineTweet", "__typename": "TimelineTweet"}),
            item_entry("tombstone-905", {"itemType": "TimelineTombstone", "__typename": "TimelineTombstone",
                                         "tombstoneInfo": {"richText": {"text": "リッチな削除"}}}),
            item_entry("tombstone-906", {"itemType": "TimelineTombstone", "__typename": "TimelineTombstone"}),
        ))
        items = items_of(n.normalize_timeline(data))
        self.assertEqual([item["text"] for item in items], [
            "このポストは削除されました。", UNAVAILABLE, "リッチな削除", "このポストは削除されました。"])
        self.assertTrue(all(item["t"] == "tombstone" and item["above"] is False and item["below"] is False
                            for item in items))

    def test_visibility_wrapper_and_restricted_replies(self):
        wrapped = {"__typename": "TweetWithVisibilityResults", "tweet": tweet_result("wrapped", typename=None),
                   "limitedActionResults": {"limited_actions": [{"action": "Reply"}]}}
        items = items_of(n.normalize_timeline(answer(add(item_entry("tweet-911", tweet_item(wrapped))))))
        self.assertEqual(items[0]["tweet"]["text"], "wrapped")
        self.assertTrue(items[0]["tweet"]["reply_limited"])

    def test_top_level_users_are_full_users(self):
        data = answer(add(item_entry("user-921", {"itemType": "TimelineUser", "__typename": "TimelineUser",
                                                  "userDisplayType": "User",
                                                  "user_results": {"result": user_result(uid="1000000000000000921")}})))
        item = items_of(n.normalize_timeline(data))[0]
        self.assertEqual(item["t"], "user")
        self.assertEqual(sorted(item["user"].keys()), sorted(FULL_USER_KEYS))

    def test_label_is_a_header_and_prompts_are_ignored(self):
        data = answer(add(
            item_entry("label-1", {"itemType": "TimelineLabel", "__typename": "TimelineLabel", "text": "見出し"}),
            item_entry("prompt-1", {"itemType": "TimelinePrompt", "__typename": "TimelinePrompt"}),
            item_entry("community-1", {"itemType": "TimelineCommunity", "__typename": "TimelineCommunity"}),
        ))
        self.assertEqual(items_of(n.normalize_timeline(data)), [{"t": "header", "text": "見出し"}])

    def test_post_ids_are_emitted_once_and_the_focal_copy_wins(self):
        one = tweet_result("one", tid="2000000000000000931")
        two = tweet_result("two", tid="2000000000000000932")
        data = answer(add(item_entry("tweet-931", tweet_item(one)),
                          item_entry("tweet-932", tweet_item(two)),
                          item_entry("tweet-931-again", tweet_item(one))))
        self.assertEqual(tweet_ids(n.normalize_timeline(data)), ["2000000000000000931", "2000000000000000932"])

        # A copy in a module comes before the stand-alone focal post: the stand-alone one is the focal.
        other = tweet_result("other", tid="2000000000000000933")
        data = answer(add(
            module_entry("related-1", "Vertical", [module_item("r-1", tweet_item(two)),
                                                   module_item("r-2", tweet_item(other))]),
            item_entry("tweet-932-focal", tweet_item(two))))
        result = n.normalize_timeline(data, focal_id="2000000000000000932")
        self.assertEqual(tweet_ids(result), ["2000000000000000933", "2000000000000000932"])
        self.assertTrue(result["items"][1]["focal"])
        self.assertFalse(result["items"][0]["focal"])

    def test_focal_post_gets_the_conversation_above_and_below(self):
        a1 = tweet_result("ancestor one", tid="2000000000000000941")
        a2 = {"__typename": "TweetTombstone", "tombstone": {"text": {"text": "削除済み"}}}
        focal = tweet_result("focal", tid="2000000000000000942")
        r1 = tweet_result("reply one", tid="2000000000000000943")
        r2 = tweet_result("reply two", tid="2000000000000000944")
        r3 = tweet_result("single reply", tid="2000000000000000945")
        data = answer(add(
            item_entry("tweet-941", tweet_item(a1)),
            item_entry("tweet-tomb", tweet_item(a2)),
            item_entry("tweet-942", tweet_item(focal)),
            module_entry("conversationthread-943", "VerticalConversation",
                         [module_item("ct-1", tweet_item(r1)), module_item("ct-2", tweet_item(r2))]),
            module_entry("conversationthread-945", "VerticalConversation", [module_item("ct-3", tweet_item(r3))]),
            cursor_entry("more", "ShowMoreThreads", "SHOW", displayTreatment={"actionText": "返信を表示"}),
        ))
        result = n.normalize_timeline(data, focal_id="2000000000000000942")
        flags = [(item["t"], item.get("above"), item.get("below"), item.get("focal")) for item in result["items"]]
        self.assertEqual(flags, [
            ("tweet", False, True, False),   # ancestor one: the first, linked below
            ("tombstone", True, True, None),  # the tombstone ancestor: linked both ways
            ("tweet", True, False, True),    # focal: linked above to its ancestors
            ("tweet", False, True, False),   # reply one: thread start
            ("tweet", True, False, False),   # reply two: thread end
            ("tweet", False, False, False),  # single reply
            ("more", None, None, None),
        ])
        self.assertEqual(result["items"][-1], {"t": "more", "cursor": "SHOW", "label": "返信を表示"})

    def test_without_focal_id_nothing_is_marked(self):
        a1 = tweet_result("ancestor", tid="2000000000000000951")
        focal = tweet_result("focal", tid="2000000000000000952")
        data = answer(add(item_entry("tweet-951", tweet_item(a1)), item_entry("tweet-952", tweet_item(focal))))
        result = n.normalize_timeline(data)
        self.assertTrue(all(item["focal"] is False for item in result["items"]))
        self.assertFalse(result["items"][0]["below"])

    def test_empty_answers(self):
        self.assertEqual(n.normalize_timeline(answer()), {"items": [], "top": None, "bottom": None})
        only_cursor = answer(add(cursor_entry("b", "Bottom", "B1")))
        self.assertEqual(n.normalize_timeline(only_cursor), {"items": [], "top": None, "bottom": None})

    def test_cursors_come_from_the_timeline(self):
        data = answer(add(cursor_entry("top", "Top", "TOP-V"),
                          item_entry("tweet-961", tweet_item(tweet_result("x", tid="2000000000000000961"))),
                          cursor_entry("bottom", "Bottom", "BOTTOM-V")))
        result = n.normalize_timeline(data)
        self.assertEqual((result["top"], result["bottom"]), ("TOP-V", "BOTTOM-V"))

    def test_clear_cache_and_unread_markers_are_ignored(self):
        data = answer({"type": "TimelineClearCache"},
                      {"type": "TimelineClearEntriesUnreadState"},
                      {"type": "TimelineMarkEntriesUnreadGreaterThanSortIndex", "sortIndex": "5"},
                      add(item_entry("tweet-971", tweet_item(tweet_result("x", tid="2000000000000000971")))))
        self.assertEqual(tweet_ids(n.normalize_timeline(data)), ["2000000000000000971"])

    def test_find_instructions_is_depth_first_and_returns_the_first_match(self):
        data = {"a": {"x": [1, {"instructions": ["first"]}]}, "b": {"instructions": ["second"]}}
        self.assertEqual(n.find_instructions(data), ["first"])
        self.assertEqual(n.find_instructions({"nothing": [1, 2]}), [])
        self.assertEqual(n.find_instructions(None), [])

    def test_find_instructions_copes_with_very_deep_input(self):
        node = {"instructions": [7]}
        for _ in range(5000):
            node = [node]
        self.assertEqual(n.find_instructions(node), [7])


class ConversationRepeatTests(unittest.TestCase):
    """A post inside a VerticalConversation module is always kept; other repeats are dropped."""
    P = "2000000000000000201"   # original post by Bob
    Q = "2000000000000000203"   # reply by Carol, in the same module as P
    REPOST = "2000000000000000202"  # Dave's stand-alone repost of P

    def test_module_copy_is_kept_after_a_stand_alone_repost_of_the_same_post(self):
        items = items_of(n.normalize_timeline(load_fixture("n_repost_then_conversation.json")))
        self.assertEqual([item["tweet"]["id"] for item in items], [self.P, self.P, self.Q])
        repost, module_post, reply = items
        self.assertEqual(repost["tweet"]["retweet_id"], self.REPOST)
        self.assertEqual(repost["tweet"]["retweeted_by"]["handle"], "dave_demo")
        self.assertEqual((repost["above"], repost["below"]), (False, False))
        self.assertIsNone(module_post["tweet"]["retweeted_by"])
        self.assertEqual((module_post["above"], module_post["below"]), (False, True))
        self.assertEqual((reply["above"], reply["below"]), (True, False))

    def test_stand_alone_copies_after_the_conversation_are_dropped(self):
        items = items_of(n.normalize_timeline(load_fixture("n_conversation_then_standalone.json")))
        self.assertEqual([item["tweet"]["id"] for item in items], [self.P, self.Q])
        self.assertIsNone(items[0]["tweet"]["retweeted_by"])
        self.assertEqual((items[0]["above"], items[0]["below"]), (False, True))
        self.assertEqual((items[1]["above"], items[1]["below"]), (True, False))

    def test_only_a_conversation_module_is_exempt(self):
        # A VerticalGrid copy of a post already shown is a repeat like any other.
        post = tweet_result("grid copy", tid=self.P)
        data = answer(add(item_entry("tweet-p", tweet_item(post)),
                          module_entry("profile-grid-1", "VerticalGrid", [module_item("g-p", tweet_item(post))])))
        self.assertEqual(tweet_ids(n.normalize_timeline(data)), [self.P])

    def test_each_conversation_module_keeps_its_copy(self):
        post = tweet_result("shared", tid=self.P)
        data = answer(add(
            module_entry("conversationthread-a", "VerticalConversation", [module_item("a-p", tweet_item(post))]),
            module_entry("conversationthread-b", "VerticalConversation", [module_item("b-p", tweet_item(post))])))
        self.assertEqual(tweet_ids(n.normalize_timeline(data)), [self.P, self.P])

    def test_focal_post_is_shown_once_even_when_a_thread_repeats_it(self):
        # Decision: the focal post keeps its focal position alone; a copy inside a thread is dropped.
        focal = tweet_result("focal", tid=self.P)
        reply = tweet_result("reply", tid=self.Q)
        data = answer(add(
            item_entry("tweet-p", tweet_item(focal)),
            module_entry("conversationthread-1", "VerticalConversation",
                         [module_item("ct-p", tweet_item(focal)), module_item("ct-q", tweet_item(reply))])))
        items = items_of(n.normalize_timeline(data, focal_id=self.P))
        self.assertEqual([item["tweet"]["id"] for item in items], [self.P, self.Q])
        self.assertTrue(items[0]["focal"])
        self.assertEqual((items[1]["above"], items[1]["below"]), (False, False))


def cursor_item(entry_id, cursor_type, value):
    """A cursor as it appears inside a module's items."""
    return module_item(entry_id, {"itemType": "TimelineTimelineCursor", "__typename": "TimelineTimelineCursor",
                                  "cursorType": cursor_type, "value": value})


# ---------------------------------------------------------------- notifications and trends

class NotificationTests(unittest.TestCase):

    def notification(self, **extra):
        node = {
            "__typename": "TimelineNotification", "id": "EiQ2070UwAAAAAABIJN04N8Yva8goWtL53c",
            "itemType": "TimelineNotification", "notification_icon": "heart_icon",
            "rich_message": {"text": "\U0001F600 Carol liked your post", "rtl": False,
                             "entities": [{"fromIndex": 2, "toIndex": 7, "format": "Strong"}]},
            "template": {"__typename": "TimelineNotificationAggregateUserActions",
                         "from_users": [{"__typename": "TimelineNotificationUserRef",
                                         "user_results": {"result": user_result(uid="1000000000000000003",
                                                                                name="Carol Test", handle="carol_test")}}],
                         "target_objects": [{"__typename": "TimelineNotificationTweetRef",
                                             "tweet_results": {"result": tweet_result("liked text", tid="2000000000000000981")}}]},
            "timestamp_ms": "2026-11-10T02:19:28.382Z",
            "notification_url": {"url": "https://x.com/alice_example/status/2000000000000000981", "urlType": "ExternalUrl"},
        }
        node.update(extra)
        return node

    def first(self, node):
        return items_of(n.normalize_timeline(answer(add(item_entry("notification-" + node["id"], node)))))[0]

    def test_notification_item(self):
        item = self.first(self.notification())
        self.assertEqual(sorted(item.keys()), sorted(["t", "id", "icon", "text", "bold", "users", "tweet", "time", "url"]))
        self.assertEqual(item["t"], "notification")
        self.assertEqual(item["icon"], "heart")
        self.assertEqual(item["text"], "\U0001F600 Carol liked your post")
        self.assertEqual(item["bold"], [[3, 8]])  # code points 2..7 are units 3..8 after the emoji
        self.assertEqual([user["handle"] for user in item["users"]], ["carol_test"])
        self.assertEqual(item["tweet"]["text"], "liked text")
        self.assertEqual(item["time"], 1794277168)
        self.assertEqual(item["url"], "https://x.com/alice_example/status/2000000000000000981")

    def test_icon_mapping_and_default(self):
        expected = {"heart_icon": "heart", "retweet_icon": "repost", "person_icon": "person",
                    "recommendation_icon": "star", "milestone_icon": "star", "bird_icon": "logo",
                    "reply_icon": "reply", "security_alert_icon": "alert", "safety_icon": "alert",
                    "bell_icon": "bell", "something_new": "bell"}
        for icon, shown in expected.items():
            self.assertEqual(self.first(self.notification(notification_icon=icon))["icon"], shown, icon)

    def test_users_are_capped_at_eight(self):
        refs = [{"user_results": {"result": user_result(uid=str(1000000000000000100 + i), handle="u%d" % i)}}
                for i in range(10)]
        node = self.notification()
        node["template"]["from_users"] = refs
        self.assertEqual(len(self.first(node)["users"]), 8)

    def test_time_forms(self):
        self.assertEqual(self.first(self.notification(timestamp_ms=1794277168383))["time"], 1794277168)
        self.assertEqual(self.first(self.notification(timestamp_ms="1794277168383"))["time"], 1794277168)
        self.assertIsNone(self.first(self.notification(timestamp_ms="soon"))["time"])
        self.assertIsNone(self.first(self.notification(timestamp_ms=None))["time"])

    def test_notification_without_id_is_skipped(self):
        node = self.notification()
        node.pop("id")
        self.assertEqual(n.normalize_timeline(answer(add(item_entry("notification-x", node))))["items"], [])


class TrendTests(unittest.TestCase):

    def trend(self, **extra):
        node = {"__typename": "TimelineTrend", "itemType": "TimelineTrend", "name": "EBiDANフェス",
                "trend_metadata": {"domain_context": "エンターテインメント · トレンド",
                                   "meta_description": "1.2万件のポスト"},
                "trend_url": {"url": "twitter://search/?query=EBiDAN%E3%83%95%E3%82%A7%E3%82%B9&src=trend_click",
                              "urlType": "DeepLink"}}
        node.update(extra)
        return node

    def first(self, node):
        return items_of(n.normalize_timeline(answer(add(item_entry("trend-1", node)))))[0]

    def test_trend_fields_and_decoded_query(self):
        item = self.first(self.trend(rank="3"))
        self.assertEqual(item, {"t": "trend", "name": "EBiDANフェス", "context": "エンターテインメント · トレンド",
                                "meta": "1.2万件のポスト", "query": "EBiDANフェス", "rank": 3})

    def test_trending_link_searches_the_name(self):
        node = self.trend(trend_url={"url": "twitter://trending/2000000000000000042", "urlType": "DeepLink"})
        item = self.first(node)
        self.assertEqual(item["query"], "EBiDANフェス")
        self.assertEqual(item["meta"], "1.2万件のポスト")

    def test_context_falls_back_to_social_context_and_rank_may_be_absent(self):
        node = self.trend(trend_metadata={"url": {"url": "twitter://trending/1"}},
                          social_context={"text": "3時間前 · テスト分野 · 42件のポスト", "type": "TimelineGeneralContext"})
        item = self.first(node)
        self.assertEqual(item["context"], "3時間前 · テスト分野 · 42件のポスト")
        self.assertIsNone(item["rank"])
        self.assertIsNone(item["meta"])

    def test_trend_without_name_is_skipped(self):
        node = self.trend()
        node.pop("name")
        self.assertEqual(n.normalize_timeline(answer(add(item_entry("trend-1", node))))["items"], [])


# ---------------------------------------------------------------- explore and user answers

class ExploreTests(unittest.TestCase):

    def test_explore_fixture(self):
        result = n.normalize_explore(load_fixture("n_explore.json"))
        self.assertEqual(sorted(result.keys()), sorted(["tabs", "tab", "items", "top", "bottom"]))
        self.assertEqual(result["tabs"], [{"id": "for_you", "label": "話題を検索"},
                                          {"id": "trending", "label": "トレンド"},
                                          {"id": "news", "label": "ニュース"}])
        self.assertEqual(result["tab"], "for_you")
        self.assertIsNone(result["top"])
        self.assertIsNone(result["bottom"])
        self.assertEqual([item["t"] for item in result["items"]], ["header", "trend", "trend", "header", "tweet"])
        self.assertEqual(result["items"][0], {"t": "header", "text": "本日のニュース"})
        story, search = result["items"][1], result["items"][2]
        self.assertEqual(story["name"], "A news trend")
        self.assertEqual(story["context"], "3時間前 · テスト分野 · 42件のポスト")
        self.assertEqual(story["query"], "A news trend")
        self.assertEqual(search["query"], "#Hashtag topic")
        self.assertEqual(search["meta"], "1.2万件のポスト")
        self.assertEqual(result["items"][3], {"t": "header", "text": "おすすめ投稿"})
        self.assertEqual(result["items"][4]["tweet"]["text"], "Popular post in explore")

    def test_explore_without_tabs_is_empty(self):
        self.assertEqual(n.normalize_explore({"data": {"explore_page": {"body": {}}}}),
                         {"tabs": [], "tab": "", "items": [], "top": None, "bottom": None})


class UserResponseTests(unittest.TestCase):

    def test_viewer_answer(self):
        viewer = {"data": {"viewer": {"user_results": {"result": user_result(uid="1000000000000000777")}}}}
        out = n.normalize_user_response(viewer)
        self.assertEqual(out["id"], "1000000000000000777")
        self.assertEqual(sorted(out.keys()), sorted(FULL_USER_KEYS))

    def test_user_by_screen_name_answer(self):
        out = n.normalize_user_response({"data": {"user": {"result": user_result(uid="1000000000000000778")}}})
        self.assertEqual(out["id"], "1000000000000000778")

    def test_unavailable_user_is_none(self):
        self.assertIsNone(n.normalize_user_response({"data": {"user": {"result": {"__typename": "UserUnavailable"}}}}))
        self.assertIsNone(n.normalize_user_response({"data": {}}))

    def test_created_tweet(self):
        answer_data = {"data": {"create_tweet": {"tweet_results": {"result": tweet_result("posted", tid="2000000000000000990")}}}}
        created = n.normalize_created_tweet(answer_data)
        self.assertEqual(created["id"], "2000000000000000990")
        self.assertEqual(created["text"], "posted")
        self.assertIsNone(n.normalize_created_tweet({"data": {"create_tweet": {"tweet_results": {}}}}))


# ---------------------------------------------------------------- fixtures (whole answers)

class HomeFixtureTests(unittest.TestCase):

    def setUp(self):
        self.result = n.normalize_timeline(load_fixture("n_home_timeline.json"))
        self.items = items_of(self.result)

    def test_cursors_and_item_order(self):
        self.assertEqual(self.result["top"], "TOP-1")
        self.assertEqual(self.result["bottom"], "BOTTOM-1")
        self.assertEqual([item["t"] for item in self.items], ["tweet"] * 7 + ["tombstone"])
        self.assertEqual([item["tweet"]["id"] for item in self.items[:7]],
                         ["2000000000000000001", "2000000000000000002", "2000000000000000006",
                          "2000000000000000004", "2000000000000000007", "2000000000000000008",
                          "2000000000000000009"])

    def test_advertisement_duplicate_and_suggestions_are_gone(self):
        ids = [item["tweet"]["id"] for item in self.items if item["t"] == "tweet"]
        self.assertNotIn("2000000000000000010", ids)
        self.assertEqual(ids.count("2000000000000000001"), 1)
        self.assertFalse([item for item in self.items if item["t"] == "header"])
        self.assertFalse([item for item in self.items if item["t"] == "user"])

    def test_text_hashtag_and_link_offsets(self):
        first = self.items[0]["tweet"]
        self.assertEqual(first["text"], "Hello \U0001F600 #news see example.com/a & more")
        self.assertEqual(first["entities"], [
            {"s": 9, "e": 14, "k": "hashtag", "v": "news"},
            {"s": 19, "e": 32, "k": "url", "v": "https://example.com/a"},
        ])
        self.assertEqual(first["user"]["name"], "Alice Example")
        self.assertEqual(first["created_at"], 1794811738)

    def test_reply_is_linked_to_its_parent_and_hides_leading_mentions(self):
        reply = self.items[1]["tweet"]
        self.assertEqual(reply["text"], "thanks!")
        self.assertEqual(reply["reply_to"], {"id": "2000000000000000001", "handles": ["alice_example", "carol_test"]})

    def test_quote_repost_and_card(self):
        quote = self.items[2]["tweet"]
        self.assertEqual(quote["text"], "Look at this")
        self.assertEqual(quote["quote"]["id"], "2000000000000000001")
        self.assertIsNone(quote["quote_unavailable"])
        repost = self.items[3]
        self.assertEqual(repost["tweet"]["id"], "2000000000000000004")
        self.assertEqual(repost["tweet"]["text"], "Original by Bob")
        self.assertEqual(repost["tweet"]["retweeted_by"]["handle"], "dave_demo")
        self.assertEqual(repost["tweet"]["retweet_id"], "2000000000000000005")
        card = self.items[4]["tweet"]
        self.assertEqual(card["text"], "Read this")
        self.assertEqual(card["card"]["type"], "summary_large_image")
        self.assertEqual(card["card"]["domain"], "news.example.com")
        self.assertEqual(card["card"]["url"], "https://news.example.com/story")
        self.assertEqual(card["card"]["title"], "Story title")
        self.assertEqual(card["card"]["image"], {"url": "https://pbs.twimg.com/card_img/1/a?format=jpg&name=800x419",
                                                  "w": 800, "h": 419})

    def test_conversation_module_is_joined(self):
        first, second = self.items[5], self.items[6]
        self.assertEqual((first["above"], first["below"]), (False, True))
        self.assertEqual((second["above"], second["below"]), (True, False))

    def test_tombstone_text(self):
        self.assertEqual(self.items[7], {"t": "tombstone", "text": "このポストは、ポストの作成者により削除されました。詳細はこちら",
                                         "above": False, "below": False})


class DetailFixtureTests(unittest.TestCase):
    FOCAL = "2000000000000000022"

    def test_focal_detail_order_and_flags(self):
        result = n.normalize_timeline(load_fixture("n_tweet_detail.json"), focal_id=self.FOCAL)
        items = items_of(result)
        self.assertEqual([item["t"] for item in items],
                         ["tweet", "tombstone", "tweet", "tweet", "tweet", "tweet", "header", "tweet", "tweet", "more"])
        ancestor, tombstone, focal = items[0], items[1], items[2]
        self.assertEqual((ancestor["below"], ancestor["above"]), (True, False))
        self.assertEqual((tombstone["above"], tombstone["below"]), (True, True))
        self.assertEqual((focal["focal"], focal["above"], focal["below"]), (True, True, False))
        self.assertEqual(focal["tweet"]["text"], "The focal post \U0001F642 with a link example.com/focal")
        self.assertEqual(sum(1 for item in items if item.get("focal")), 1)
        self.assertEqual((items[3]["above"], items[3]["below"]), (False, True))
        self.assertEqual((items[4]["above"], items[4]["below"]), (True, False))
        self.assertEqual((items[5]["above"], items[5]["below"]), (False, False))
        self.assertEqual(items[6], {"t": "header", "text": "もっと見つける"})
        self.assertEqual(items[9], {"t": "more", "cursor": "SHOW-MORE-1", "label": "スパムの可能性がある返信を表示"})
        self.assertIsNone(result["top"])
        self.assertIsNone(result["bottom"])

    def test_without_the_focal_id_no_conversation_line_to_the_ancestors(self):
        items = items_of(n.normalize_timeline(load_fixture("n_tweet_detail.json")))
        self.assertFalse(any(item.get("focal") for item in items))
        self.assertFalse(items[0]["below"])


# ---------------------------------------------------------------- robustness and time

class RobustnessTests(unittest.TestCase):
    JUNK = [None, 0, "x", [], {}, [None], {"data": None}, {"data": {"viewer": 1}},
            {"instructions": "no"}, {"data": {"explore_page": None}}, {"data": {"create_tweet": 3}}]

    def test_public_functions_never_raise_on_junk(self):
        for junk in self.JUNK:
            self.assertIsNone(n.normalize_user(junk))
            self.assertIsNone(n.normalize_tweet(junk))
            self.assertIsNone(n.normalize_user_response(junk))
            self.assertIsNone(n.normalize_created_tweet(junk))
            self.assertEqual(n.normalize_timeline(junk), {"items": [], "top": None, "bottom": None})
            self.assertEqual(n.normalize_explore(junk), {"tabs": [], "tab": "", "items": [], "top": None, "bottom": None})
            self.assertEqual(n.find_instructions(junk), [])

    def test_broken_entries_are_skipped_and_the_rest_kept(self):
        good = tweet_result("still here", tid="2000000000000000995")
        data = answer(add("junk", None, 3, {"content": "x"},
                          {"entryId": "a", "content": {"entryType": "TimelineTimelineItem", "itemContent": None}},
                          {"entryId": "b", "content": {"entryType": "TimelineTimelineModule", "items": "bad"}},
                          {"entryId": "c", "content": {"entryType": "TimelineTimelineItem", "itemContent": {
                              "itemType": "TimelineTweet", "tweet_results": {"result": "not a dict"}}}},
                          item_entry("tweet-995", tweet_item(good))))
        self.assertEqual(tweet_ids(n.normalize_timeline(data)), ["2000000000000000995"])

    def test_unknown_instruction_types_are_ignored(self):
        data = answer({"type": "TimelineSomethingNew", "entries": [1, 2]}, "not an instruction", None)
        self.assertEqual(n.normalize_timeline(data), {"items": [], "top": None, "bottom": None})

    def test_missing_counts_default_to_zero(self):
        leg = {"full_text": "bare", "created_at": "Mon Nov 16 06:48:58 +0000 2026"}
        tweet = n.normalize_tweet(tweet_result("bare", leg=leg))
        self.assertEqual((tweet["reply_count"], tweet["retweet_count"], tweet["like_count"],
                          tweet["quote_count"], tweet["bookmark_count"]), (0, 0, 0, 0, 0))
        self.assertEqual((tweet["liked"], tweet["retweeted"], tweet["bookmarked"]), (False, False, False))
        self.assertEqual(tweet["lang"], "und")
        self.assertEqual(tweet["conversation_id"], "2000000000000000100")

    def test_created_at_of_a_bad_value_is_zero(self):
        tweet = n.normalize_tweet(tweet_result("x", leg=legacy("x", created_at="someday")))
        self.assertEqual(tweet["created_at"], 0)


class TimeAndKeyTests(unittest.TestCase):

    def test_documented_keys_of_entities_media_cards_and_items(self):
        tweet = n.normalize_tweet(tweet_result(
            "pic https://t.co/AAAAAAAAAA", leg=legacy("pic https://t.co/AAAAAAAAAA",
                                                      entities={"urls": [url_entity(
                                                          "pic https://t.co/AAAAAAAAAA", "https://t.co/AAAAAAAAAA",
                                                          "https://t.co/AAAAAAAAAA", "https://example.com/a", "example.com/a")]},
                                                      extended_entities={"media": [media_node("video", video_info={
                                                          "variants": [{"bitrate": 1, "content_type": "video/mp4", "url": "https://v/x.mp4"}]})]})))
        self.assertEqual(sorted(tweet["entities"][0].keys()), ["e", "k", "s", "v"])
        self.assertEqual(sorted(tweet["media"][0].keys()), ["alt", "h", "type", "url", "video", "w"])
        self.assertEqual(sorted(tweet["media"][0]["video"].keys()), ["aspect", "duration_ms", "hls", "mp4"])
        self.assertEqual(sorted(n.normalize_timeline(answer(add(item_entry("x", tweet_item(
            tweet_result("x", tid="2000000000000000990")))))).keys()), ["bottom", "items", "top"])
        item = items_of(n.normalize_timeline(answer(add(item_entry("x", tweet_item(
            tweet_result("x", tid="2000000000000000991")))))))[0]
        self.assertEqual(sorted(item.keys()), ["above", "below", "context", "focal", "t", "tweet"])
        card = n.normalize_tweet(tweet_result("c", leg=legacy("c"), card=card_of("summary", [
            bv_string("card_url", "https://t.co/Z"), bv_string("title", "T")])))
        self.assertEqual(sorted(card["card"].keys()), sorted(["type", "url", "domain", "title", "description", "image", "poll"]))


def translatable_of(text, lang="en", is_translatable=None):
    """translatable of a tweet with the given text and legacy.lang (None: no lang key at all)."""
    leg = legacy(text)
    if lang is None:
        leg.pop("lang")
    else:
        leg["lang"] = lang
    node = tweet_result(text, leg=leg)
    if is_translatable is not None:
        node["is_translatable"] = is_translatable
    return n.normalize_tweet(node)["translatable"]


class TranslationTests(unittest.TestCase):
    """normalize_translation: both answer shapes, the text rules over the whole text, None cases."""

    def test_tweet_translation_with_offsets_after_an_emoji(self):
        out = n.normalize_translation(load_fixture("n_translation_tweet.json"))
        self.assertEqual(out, {
            "text": "\U0001F600 @bob_sample wrote example.com/a today",
            "entities": [
                # the emoji is 2 UTF-16 units and the space 1, so the mention starts at 3
                {"s": 3, "e": 14, "k": "mention", "v": "bob_sample"},
                # 3 + "@bob_sample" (11) + " wrote " (7) = 21; "example.com/a" is 13 units
                {"s": 21, "e": 34, "k": "url", "v": "https://example.com/a"},
            ],
            "source_lang": "en",
            "source_lang_name": "英語",
            "provider": "Google",
        })

    def test_profile_translation_shape(self):
        out = n.normalize_translation(load_fixture("n_translation_profile.json"))
        self.assertEqual(out, {
            "text": "\U0001F642 Writer #photo, see example.org/bob",
            "entities": [
                # emoji 2 + space 1 + "Writer " 7 = 10; "#photo" is 6 units
                {"s": 10, "e": 16, "k": "hashtag", "v": "photo"},
                # "#photo" ends at 16, ", see " is 6 units, "example.org/bob" is 15 units
                {"s": 22, "e": 37, "k": "url", "v": "https://example.org/bob"},
            ],
            "source_lang": "en",
            "source_lang_name": "英語",
            "provider": "Google",
        })

    def test_the_whole_text_is_the_range(self):
        # A leading mention is shown (no reply prefix is hidden) and a link at the end stays
        # (a translation has no card or quoted post to repeat).
        data = {
            "translation": "@bob_sample hi https://t.co/AAAAAAAAAA",
            "entities": {
                "user_mentions": [{"indices": [0, 11], "screen_name": "bob_sample"}],
                "urls": [{"indices": [15, 38], "url": "https://t.co/AAAAAAAAAA",
                          "display_url": "example.com/a", "expanded_url": "https://example.com/a"}],
            },
        }
        out = n.normalize_translation(data)
        self.assertEqual(out["text"], "@bob_sample hi example.com/a")
        self.assertEqual(out["entities"], [
            {"s": 0, "e": 11, "k": "mention", "v": "bob_sample"},
            {"s": 15, "e": 28, "k": "url", "v": "https://example.com/a"},
        ])

    def test_escapes_are_decoded(self):
        self.assertEqual(n.normalize_translation({"translation": "A &amp; B &lt;3"})["text"], "A & B <3")

    def test_missing_source_fields_are_empty_strings(self):
        out = n.normalize_translation({"translation": "x"})
        self.assertEqual((out["source_lang"], out["source_lang_name"], out["provider"]), ("", "", ""))

    def test_entities_of_another_shape_are_ignored(self):
        out = n.normalize_translation({"translation": "plain text", "entities": "not a dict"})
        self.assertEqual(out["text"], "plain text")
        self.assertEqual(out["entities"], [])

    def test_none_when_the_state_is_not_success(self):
        for state in ("Pending", "Error", "Unavailable"):
            with self.subTest(state=state):
                self.assertIsNone(n.normalize_translation({"translation": "text", "translationState": state}))
        self.assertEqual(n.normalize_translation({"translation": "text", "translationState": "Success"})["text"], "text")
        self.assertEqual(n.normalize_translation({"translation": "text"})["text"], "text")

    def test_none_for_a_missing_or_blank_translation(self):
        for data in ({}, {"translation": ""}, {"translation": "   \n"}, {"translation": None},
                     {"translation": 5}, {"translation": {"text": "x"}}):
            with self.subTest(data=data):
                self.assertIsNone(n.normalize_translation(data))

    def test_none_when_only_a_media_link_is_left(self):
        # The media emits nothing, so there is no text to show.
        data = {"translation": "https://t.co/MMMMMMMMMM",
                "entities": {"media": [{"indices": [0, 23], "url": "https://t.co/MMMMMMMMMM"}]}}
        self.assertIsNone(n.normalize_translation(data))

    def test_none_for_junk(self):
        for junk in (None, 0, "x", [], [None], {"profileTranslation": "x"}, {"profileTranslation": None},
                     {"data": {"translation": "x"}}):
            with self.subTest(junk=junk):
                self.assertIsNone(n.normalize_translation(junk))


class TranslatableTests(unittest.TestCase):
    """translatable (Tweet) and bio_translatable (full user): server-design 9."""

    def test_tweet_cases(self):
        cases = [
            # (text, legacy.lang (None: absent), is_translatable (None: absent), expected)
            ("hello", "en", None, True),
            ("hello", "fr", None, True),        # any language outside the list
            ("hello", "ko", None, True),
            ("こんにちは", "ja", None, False),   # Japanese is not offered
            ("hello", "und", None, False),
            ("hello", "zxx", None, False),
            ("hello", "qme", None, False),
            ("hello", "art", None, False),
            ("hello", "", None, False),         # empty language
            ("hello", None, None, False),       # no language at all
            ("", "en", None, False),            # no text
            ("", "en", True, False),            # no text wins over X's flag
            ("hello", "en", False, True),       # X's flag being false does not block a language
            ("hello", "ja", True, True),        # X flags it, although the language is Japanese
        ]
        for text, lang, flag, expected in cases:
            with self.subTest(text=text, lang=lang, flag=flag):
                self.assertIs(translatable_of(text, lang, flag), expected)

    def test_repost_uses_the_language_of_the_original(self):
        original = tweet_result("Hello there", tid="2000000000000000401", leg=legacy("Hello there", lang="en"))
        repost = tweet_result("RT @x: Hello there", tid="2000000000000000402",
                              leg=legacy("RT @x: Hello there", lang="ja",
                                         retweeted_status_result={"result": original}))
        self.assertIs(n.normalize_tweet(repost)["translatable"], True)

    def test_bio_cases(self):
        cases = [
            # (bio, profile_description_language (None: absent), is_profile_translatable (None: absent), expected)
            ("Hello", "en", None, True),
            ("Hello", "ko", None, True),
            ("Hello", "ja", None, False),
            ("Hello", "und", None, False),
            ("Hello", "zxx", None, False),
            ("Hello", "", None, False),
            ("Hello", None, None, False),
            ("Hello", "ja", True, True),        # X says the profile is translatable
            ("Hello", "en", False, True),
            ("", "en", None, False),            # empty bio
            ("", "ja", True, False),            # empty bio wins over X's flag
        ]
        for bio, language, flag, expected in cases:
            node = user_result(profile_bio={"description": bio, "entities": {"description": {}}})
            if language is not None:
                node["profile_description_language"] = language
            if flag is not None:
                node["is_profile_translatable"] = flag
            with self.subTest(bio=bio, language=language, flag=flag):
                self.assertIs(n.normalize_user(node, full=True)["bio_translatable"], expected)

    def test_only_full_users_carry_bio_translatable(self):
        self.assertNotIn("bio_translatable", n.normalize_user(user_result(profile_description_language="en")))

    def test_every_tweet_and_full_user_carries_a_boolean_flag(self):
        # Plain posts and their quoted posts, from the home fixture.
        result = n.normalize_timeline(load_fixture("n_home_timeline.json"))
        tweets = []
        for item in items_of(result):
            if item["t"] == "tweet":
                tweets.append(item["tweet"])
                if item["tweet"]["quote"]:
                    tweets.append(item["tweet"]["quote"])
        self.assertTrue(tweets)
        for tweet in tweets:
            self.assertIsInstance(tweet["translatable"], bool)
        # A user in a timeline is a full user.
        user_item = n.normalize_timeline(answer(add(item_entry("user-1", {
            "itemType": "TimelineUser", "__typename": "TimelineUser",
            "user_results": {"result": user_result(uid="1000000000000000921")}}))))
        self.assertIsInstance(items_of(user_item)[0]["user"]["bio_translatable"], bool)


if __name__ == "__main__":
    unittest.main()
