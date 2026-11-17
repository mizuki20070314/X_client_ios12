import json
import unittest

import testsupport  # noqa: F401  (sets sys.path so that xrelay_app imports)
from xrelay_app import cgiio, routes
from xrelay_app.errors import RelayError


class FakeClient(object):
    """Records every X call; answers come from a table keyed by operation name or REST path."""

    def __init__(self, graphql=None, rest=None):
        self.graphql_answers = dict(graphql or {})
        self.rest_answers = dict(rest or {})
        self.graphql_calls = []  # (name, variables, field_toggles)
        self.rest_calls = []     # (method, path, params, form, json_body)

    def graphql(self, name, variables, field_toggles=None):
        self.graphql_calls.append((name, variables, field_toggles))
        answer = self.graphql_answers.get(name, {"data": {"marker": name}})
        if isinstance(answer, BaseException):
            raise answer
        return answer

    def rest(self, method, path, params=None, form=None, json_body=None):
        self.rest_calls.append((method, path, params, form, json_body))
        answer = self.rest_answers.get(path, {})
        if isinstance(answer, BaseException):
            raise answer
        return answer

    def last(self):
        return self.graphql_calls[-1]


class FakeNormalizer(object):
    """Marker values, plus the keyword arguments each call received."""

    def __init__(self):
        self.calls = []

    def normalize_timeline(self, data, *args, **kwargs):
        self.calls.append(("normalize_timeline", args, kwargs))
        return {"items": ["timeline"], "top": "TOP", "bottom": "BOTTOM", "marker": _marker(data)}

    def normalize_explore(self, data, *args, **kwargs):
        self.calls.append(("normalize_explore", args, kwargs))
        return {"tabs": [{"id": "for_you", "label": "話題を検索"}, {"id": "news", "label": "ニュース"}],
                "tab": "for_you", "items": ["explore-first"], "top": None, "bottom": None,
                "marker": _marker(data)}

    def normalize_user_response(self, data, *args, **kwargs):
        self.calls.append(("normalize_user_response", args, kwargs))
        if _marker(data) == "no-user":
            return None
        return {"id": "42", "handle": "someone", "marker": _marker(data)}

    def normalize_translation(self, data, *args, **kwargs):
        self.calls.append(("normalize_translation", args, kwargs))
        if _marker(data) == "no-translation":
            return None
        return {"text": "こんにちは", "entities": [], "source_lang": "en", "source_lang_name": "英語",
                "provider": "Google", "marker": _marker(data)}

    def normalize_created_tweet(self, data, *args, **kwargs):
        self.calls.append(("normalize_created_tweet", args, kwargs))
        return {"id": "999", "marker": _marker(data)}


def _marker(data):
    if isinstance(data, dict):
        return data.get("marker", "data")
    return None


def timeline_answer(marker):
    return {"marker": marker}


def get(path, **query):
    return cgiio.Request("GET", path, list(query.items()), {}, b"")


def get_pairs(path, pairs):
    return cgiio.Request("GET", path, list(pairs), {}, b"")


def post(path, payload=None, raw=None):
    body = raw if raw is not None else json.dumps(payload).encode("utf-8")
    return cgiio.Request("POST", path, [], {}, body)


class RouteTestCase(unittest.TestCase):
    def run_route(self, request, client=None, normalizer=None):
        self.client = client if client is not None else FakeClient()
        self.normalizer = normalizer if normalizer is not None else FakeNormalizer()
        status, payload = routes.dispatch(request, self.client, self.normalizer)
        self.assertEqual(status, 200)
        return payload

    def assertBad(self, request, client=None):
        with self.assertRaises(RelayError) as caught:
            self.run_route(request, client)
        self.assertEqual((caught.exception.status, caught.exception.code), (400, "bad_request"))

    def assertNoX(self):
        self.assertEqual(self.client.graphql_calls, [])
        self.assertEqual(self.client.rest_calls, [])


class DispatchTests(RouteTestCase):
    def test_unknown_route_is_404(self):
        with self.assertRaises(RelayError) as caught:
            routes.dispatch(get("/v2/nothing"), FakeClient(), FakeNormalizer())
        self.assertEqual((caught.exception.status, caught.exception.code), (404, "not_found"))

    def test_known_route_with_the_wrong_method_is_405(self):
        for request in (get("/v2/tweet/like"), post("/v2/home", {})):
            with self.assertRaises(RelayError) as caught:
                routes.dispatch(request, FakeClient(), FakeNormalizer())
            self.assertEqual((caught.exception.status, caught.exception.code), (405, "bad_request"))

    def test_success_is_200_with_the_payload(self):
        status, payload = routes.dispatch(get("/v2/home"), FakeClient(), FakeNormalizer())
        self.assertEqual(status, 200)
        self.assertEqual(payload["top"], "TOP")


class TimelineRouteTests(RouteTestCase):
    def test_home_foryou_first_page(self):
        payload = self.run_route(get("/v2/home"))
        name, variables, toggles = self.client.last()
        self.assertEqual(name, "HomeTimeline")
        self.assertEqual(variables, {"count": 20, "includePromotedContent": True,
                                     "requestContext": "launch", "withCommunity": True})
        self.assertEqual(toggles, {"withPayments": False})
        self.assertEqual(payload["items"], ["timeline"])

    def test_home_following_cursor(self):
        self.run_route(get("/v2/home", tab="following", cursor="C1"))
        name, variables, _ = self.client.last()
        self.assertEqual(name, "HomeLatestTimeline")
        self.assertEqual(variables, {"count": 20, "cursor": "C1", "includePromotedContent": True,
                                     "latestControlAvailable": True, "withCommunity": True})

    def test_home_following_first_page(self):
        self.run_route(get("/v2/home", tab="following"))
        self.assertEqual(self.client.last()[1], {"count": 20, "includePromotedContent": True,
                                                 "latestControlAvailable": True, "requestContext": "launch",
                                                 "withCommunity": True})

    def test_home_validation(self):
        self.assertBad(get("/v2/home", tab="sometimes"))
        self.assertBad(get("/v2/home", cursor=""))
        self.assertBad(get("/v2/home", cursor="x" * 2001))
        self.assertNoX()

    def test_tweet_first_page_passes_the_focal_id(self):
        self.run_route(get("/v2/tweet", id="123"))
        name, variables, toggles = self.client.last()
        self.assertEqual(name, "TweetDetail")
        self.assertEqual(variables, {"focalTweetId": "123", "with_rux_injections": False,
                                     "rankingMode": "Relevance", "includePromotedContent": True,
                                     "withCommunity": True, "withQuickPromoteEligibilityTweetFields": True,
                                     "withBirdwatchNotes": True, "withVoice": True})
        self.assertEqual(toggles, {"withArticleRichContentState": True, "withArticlePlainText": False,
                                   "withGrokAnalyze": False, "withDisallowedReplyControls": False})
        self.assertEqual(self.normalizer.calls[-1], ("normalize_timeline", (), {"focal_id": "123"}))

    def test_tweet_later_page_has_no_focal_id_and_referrer(self):
        self.run_route(get("/v2/tweet", id="123", cursor="C9"))
        variables = self.client.last()[1]
        self.assertEqual((variables["cursor"], variables["referrer"]), ("C9", "tweet"))
        self.assertEqual(self.normalizer.calls[-1], ("normalize_timeline", (), {}))

    def test_tweet_id_is_required_and_numeric(self):
        self.assertBad(get("/v2/tweet"))
        self.assertBad(get("/v2/tweet", id="12a"))
        self.assertBad(get("/v2/tweet", id="1" * 26))
        self.assertBad(get("/v2/tweet", id=""))
        self.assertNoX()

    def test_search_modes_map_to_products(self):
        for mode, product in (("top", "Top"), ("latest", "Latest"), ("people", "People"), ("media", "Media")):
            self.client = FakeClient()
            self.run_route(get("/v2/search", q="x", mode=mode), client=self.client)
            variables = self.client.last()[1]
            self.assertEqual(variables["product"], product)
        self.assertEqual(self.client.last()[1], {"rawQuery": "x", "count": 20, "querySource": "typed_query",
                                                 "product": "Media", "withGrokTranslatedBio": False})

    def test_search_trims_the_query_and_adds_the_cursor(self):
        self.run_route(get("/v2/search", q="  hello world ", cursor="K"))
        variables = self.client.last()[1]
        self.assertEqual(variables["rawQuery"], "hello world")
        self.assertEqual(variables["cursor"], "K")

    def test_search_validation(self):
        self.assertBad(get("/v2/search"))
        self.assertBad(get("/v2/search", q="   "))
        self.assertBad(get("/v2/search", q="x" * 501))
        self.assertBad(get("/v2/search", q="x", mode="popular"))
        self.assertNoX()

    def test_notifications(self):
        self.run_route(get("/v2/notifications"))
        self.assertEqual(self.client.last()[1], {"timeline_type": "All", "count": 20})
        self.run_route(get("/v2/notifications", tab="mentions", cursor="N"))
        self.assertEqual(self.client.last()[1], {"timeline_type": "Mentions", "count": 20, "cursor": "N"})
        self.assertBad(get("/v2/notifications", tab="other"))

    def test_bookmarks(self):
        self.run_route(get("/v2/bookmarks", cursor="B"))
        self.assertEqual(self.client.last(), ("Bookmarks", {"count": 20, "includePromotedContent": True, "cursor": "B"},
                                              None))

    def test_user_timeline_tabs(self):
        expected = {
            "posts": ("UserTweets", {"userId": "7", "count": 20, "includePromotedContent": True,
                                     "withQuickPromoteEligibilityTweetFields": True, "withVoice": True}),
            "replies": ("UserTweetsAndReplies", {"userId": "7", "count": 20, "includePromotedContent": True,
                                                 "withCommunity": True, "withVoice": True}),
            "media": ("UserMedia", {"userId": "7", "count": 20, "includePromotedContent": False,
                                    "withClientEventToken": False, "withBirdwatchNotes": False,
                                    "withVoice": True}),
            "likes": ("Likes", {"userId": "7", "count": 20, "includePromotedContent": False,
                                "withClientEventToken": False, "withBirdwatchNotes": False,
                                "withVoice": True}),
        }
        for tab, (name, variables) in expected.items():
            self.client = FakeClient()
            self.run_route(get("/v2/user/timeline", id="7", tab=tab), client=self.client)
            called_name, called_variables, toggles = self.client.last()
            self.assertEqual((called_name, called_variables), (name, variables), tab)
            self.assertEqual(toggles, {"withArticlePlainText": False})
        self.client = FakeClient()
        self.run_route(get("/v2/user/timeline", id="7"), client=self.client)
        self.assertEqual(self.client.last()[0], "UserTweets")

    def test_user_timeline_validation(self):
        self.assertBad(get("/v2/user/timeline"))
        self.assertBad(get("/v2/user/timeline", id="7", tab="drafts"))
        self.assertNoX()

    def test_user_follows(self):
        self.run_route(get("/v2/user/follows", id="7"))
        self.assertEqual(self.client.last(), ("Following", {"userId": "7", "count": 20,
                                                            "includePromotedContent": False,
                                                            "withGrokTranslatedBio": False}, None))
        self.run_route(get("/v2/user/follows", id="7", kind="followers", cursor="F"), client=self.client)
        self.assertEqual(self.client.last()[0], "Followers")
        self.assertEqual(self.client.last()[1]["cursor"], "F")
        self.assertBad(get("/v2/user/follows", id="7", kind="both"))


class UserRouteTests(RouteTestCase):
    def test_by_handle_strips_one_at_sign(self):
        payload = self.run_route(get("/v2/user", handle="@Some_User"))
        self.assertEqual(self.client.last(), ("UserByScreenName",
                                              {"screen_name": "Some_User", "withGrokTranslatedBio": False},
                                              {"withPayments": False, "withAuxiliaryUserLabels": True}))
        self.assertEqual(payload["user"]["handle"], "someone")

    def test_by_id(self):
        self.run_route(get("/v2/user", id="42"))
        self.assertEqual(self.client.last(), ("UserByRestId", {"userId": "42"},
                                              {"withPayments": False, "withAuxiliaryUserLabels": True}))

    def test_exactly_one_of_handle_or_id(self):
        self.assertBad(get("/v2/user"))
        self.assertBad(get("/v2/user", handle="a", id="1"))
        self.assertNoX()

    def test_handle_validation(self):
        for handle in ("bad-name", "@", "x" * 21, "@@one", " spaced"):
            self.assertBad(get("/v2/user", handle=handle))
        self.assertNoX()

    def test_unknown_user_is_404(self):
        client = FakeClient(graphql={"UserByRestId": {"marker": "no-user"}})
        with self.assertRaises(RelayError) as caught:
            self.run_route(get("/v2/user", id="42"), client=client)
        self.assertEqual((caught.exception.status, caught.exception.code), (404, "not_found"))


class ExploreRouteTests(RouteTestCase):
    def explore_answer(self):
        return {"data": {"explore_page": {"body": {"timelines": [
            {"id": "for_you", "labelText": "話題を検索", "timeline": {"id": "VGltZWxpbmU6AAA="}},
            {"id": "news", "labelText": "ニュース", "timeline": {"id": "VGltZWxpbmU6QkJC"}},
        ]}}}}

    def test_first_tab_is_the_normalised_explore_answer(self):
        client = FakeClient(graphql={"ExplorePage": self.explore_answer()})
        payload = self.run_route(get("/v2/explore"), client=client)
        self.assertEqual(client.graphql_calls, [("ExplorePage", {"cursor": ""}, None)])
        self.assertEqual(payload["tab"], "for_you")
        self.assertEqual(payload["items"], ["explore-first"])

    def test_the_initial_tab_named_explicitly_is_the_same_answer(self):
        client = FakeClient(graphql={"ExplorePage": self.explore_answer()})
        payload = self.run_route(get("/v2/explore", tab="for_you"), client=client)
        self.assertEqual(len(client.graphql_calls), 1)
        self.assertEqual(payload["items"], ["explore-first"])

    def test_other_tab_loads_its_timeline_by_id(self):
        client = FakeClient(graphql={
            "ExplorePage": self.explore_answer(),
            "GenericTimelineById": {"marker": "news-page"},
        })
        payload = self.run_route(get("/v2/explore", tab="news"), client=client)
        self.assertEqual(client.graphql_calls[1], ("GenericTimelineById",
                                                   {"timelineId": "VGltZWxpbmU6QkJC", "count": 20,
                                                    "withQuickPromoteEligibilityTweetFields": True}, None))
        self.assertEqual(set(payload), {"tabs", "tab", "items", "top", "bottom"})
        self.assertEqual(payload["tab"], "news")
        self.assertEqual(payload["tabs"][1]["id"], "news")
        self.assertEqual(payload["items"], ["timeline"])
        self.assertEqual((payload["top"], payload["bottom"]), ("TOP", "BOTTOM"))

    def test_unknown_tab_is_400_and_asks_for_nothing_more(self):
        client = FakeClient(graphql={"ExplorePage": self.explore_answer()})
        with self.assertRaises(RelayError) as caught:
            self.run_route(get("/v2/explore", tab="sports"), client=client)
        self.assertEqual(caught.exception.status, 400)
        self.assertEqual(len(client.graphql_calls), 1)

    def test_tab_with_a_malformed_timeline_id_is_400(self):
        answer = self.explore_answer()
        answer["data"]["explore_page"]["body"]["timelines"][1]["timeline"]["id"] = "bad id!"
        client = FakeClient(graphql={"ExplorePage": answer})
        with self.assertRaises(RelayError) as caught:
            self.run_route(get("/v2/explore", tab="news"), client=client)
        self.assertEqual(caught.exception.status, 400)

    def test_tab_syntax_is_checked_first(self):
        self.assertBad(get("/v2/explore", tab="a b"))
        self.assertNoX()


class MeAndBadgeRouteTests(RouteTestCase):
    def test_me_has_user_and_badges(self):
        client = FakeClient(rest={routes.BADGE_PATH: {"ntab_unread_count": 5, "dm_unread_count": 2}})
        payload = self.run_route(get("/v2/me"), client=client)
        self.assertEqual(client.graphql_calls[0], ("Viewer", {"withCommunitiesMemberships": True},
                                                   {"isDelegate": False, "withAuxiliaryUserLabels": True}))
        self.assertEqual(client.rest_calls[0], ("GET", routes.BADGE_PATH, {"supports_ntab_urt": "1"},
                                                None, None))
        self.assertEqual(payload["badges"], {"notifications": 5, "messages": 2})
        self.assertEqual(payload["user"]["id"], "42")

    def test_me_survives_a_failed_badge_request(self):
        client = FakeClient(rest={routes.BADGE_PATH: RelayError(502, "x_error", "down")})
        payload = self.run_route(get("/v2/me"), client=client)
        self.assertEqual(payload["badges"], {"notifications": 0, "messages": 0})

    def test_me_without_a_user_is_502(self):
        client = FakeClient(graphql={"Viewer": {"marker": "no-user"}})
        with self.assertRaises(RelayError) as caught:
            self.run_route(get("/v2/me"), client=client)
        self.assertEqual(caught.exception.status, 502)

    def test_badges_route(self):
        client = FakeClient(rest={routes.BADGE_PATH: {"ntab_unread_count": 3, "dm_unread_count": 0}})
        self.assertEqual(self.run_route(get("/v2/badges"), client=client),
                         {"notifications": 3, "messages": 0})

    def test_badges_route_fails_when_x_fails(self):
        client = FakeClient(rest={routes.BADGE_PATH: RelayError(403, "x_auth", "login")})
        with self.assertRaises(RelayError):
            self.run_route(get("/v2/badges"), client=client)

    def test_odd_badge_values_are_zero(self):
        for value in ("5", -1, True, None, 2.5):
            client = FakeClient(rest={routes.BADGE_PATH: {"ntab_unread_count": value, "dm_unread_count": value}})
            self.assertEqual(self.run_route(get("/v2/badges"), client=client), {"notifications": 0, "messages": 0})


class WriteRouteTests(RouteTestCase):
    def test_create_plain_text_is_trimmed(self):
        payload = self.run_route(post("/v2/tweet/create", {"text": "  こんにちは  ", "reply_to": None,
                                                           "quote": None, "media_ids": []}))
        name, variables, toggles = self.client.last()
        self.assertEqual(name, "CreateTweet")
        self.assertEqual(variables, {"tweet_text": "こんにちは", "dark_request": False,
                                     "media": {"media_entities": [], "possibly_sensitive": False},
                                     "semantic_annotation_ids": [], "disallowed_reply_options": None})
        self.assertIsNone(toggles)
        self.assertEqual(payload, {"ok": True, "tweet": {"id": "999", "marker": "data"}})

    def test_create_reply_quote_and_media(self):
        self.run_route(post("/v2/tweet/create", {"text": "x", "reply_to": "111", "quote": "222",
                                                 "media_ids": ["333", "444"]}))
        variables = self.client.last()[1]
        self.assertEqual(variables["reply"], {"in_reply_to_tweet_id": "111", "exclude_reply_user_ids": []})
        self.assertEqual(variables["attachment_url"], "https://x.com/i/status/222")
        self.assertEqual(variables["media"]["media_entities"], [{"media_id": "333", "tagged_users": []},
                                                                {"media_id": "444", "tagged_users": []}])

    def test_create_without_optional_keys(self):
        self.run_route(post("/v2/tweet/create", {"text": "x"}))
        variables = self.client.last()[1]
        self.assertNotIn("reply", variables)
        self.assertNotIn("attachment_url", variables)

    def test_create_text_limits(self):
        self.run_route(post("/v2/tweet/create", {"text": "x" * 4000}))
        self.assertBad(post("/v2/tweet/create", {"text": "x" * 4001}))
        self.assertBad(post("/v2/tweet/create", {"text": "   "}))
        self.assertBad(post("/v2/tweet/create", {"text": 12}))
        self.assertBad(post("/v2/tweet/create", {}))

    def test_create_id_and_media_validation(self):
        self.assertBad(post("/v2/tweet/create", {"text": "x", "reply_to": "abc"}))
        self.assertBad(post("/v2/tweet/create", {"text": "x", "quote": 12}))
        self.assertBad(post("/v2/tweet/create", {"text": "x", "media_ids": "333"}))
        self.assertBad(post("/v2/tweet/create", {"text": "x", "media_ids": ["33x"]}))

    def test_create_body_must_be_an_object(self):
        self.assertBad(post("/v2/tweet/create", raw=b"[]"))
        self.assertBad(post("/v2/tweet/create", raw=b"not json"))
        self.assertBad(post("/v2/tweet/create", raw=b""))
        self.assertNoX()

    def test_create_already_done_answers_ok_without_tweet(self):
        client = FakeClient(graphql={"CreateTweet": RelayError(403, "x_auth", "x", x_code=139)})
        self.assertEqual(self.run_route(post("/v2/tweet/create", {"text": "x"}), client=client),
                         {"ok": True, "tweet": None})

    def test_like_on_and_off(self):
        self.assertEqual(self.run_route(post("/v2/tweet/like", {"id": "1", "on": True})), {"ok": True})
        self.assertEqual(self.client.last(), ("FavoriteTweet", {"tweet_id": "1"}, None))
        self.run_route(post("/v2/tweet/like", {"id": "1", "on": False}), client=self.client)
        self.assertEqual(self.client.last(), ("UnfavoriteTweet", {"tweet_id": "1"}, None))

    def test_retweet_on_and_off(self):
        self.run_route(post("/v2/tweet/retweet", {"id": "5", "on": True}))
        self.assertEqual(self.client.last(), ("CreateRetweet", {"tweet_id": "5", "dark_request": False}, None))
        self.run_route(post("/v2/tweet/retweet", {"id": "5", "on": False}), client=self.client)
        self.assertEqual(self.client.last(), ("DeleteRetweet", {"source_tweet_id": "5", "dark_request": False},
                                              None))

    def test_bookmark_on_and_off(self):
        self.run_route(post("/v2/tweet/bookmark", {"id": "6", "on": True}))
        self.assertEqual(self.client.last(), ("CreateBookmark", {"tweet_id": "6"}, None))
        self.run_route(post("/v2/tweet/bookmark", {"id": "6", "on": False}), client=self.client)
        self.assertEqual(self.client.last(), ("DeleteBookmark", {"tweet_id": "6"}, None))

    def test_delete_tweet(self):
        self.assertEqual(self.run_route(post("/v2/tweet/delete", {"id": "7"})), {"ok": True})
        self.assertEqual(self.client.last(), ("DeleteTweet", {"tweet_id": "7", "dark_request": False}, None))

    def test_follow_mute_block_send_the_rest_forms(self):
        self.run_route(post("/v2/user/follow", {"id": "8", "on": True}))
        method, path, params, form, json_body = self.client.rest_calls[-1]
        self.assertEqual((method, path), ("POST", "/i/api/1.1/friendships/create.json"))
        self.assertEqual(list(form.items())[-1], ("user_id", "8"))
        self.assertEqual(list(form.items())[0], ("include_profile_interstitial_type", "1"))
        self.assertEqual(len(form), 13)
        self.run_route(post("/v2/user/follow", {"id": "8", "on": False}), client=self.client)
        self.assertEqual(self.client.rest_calls[-1][1], "/i/api/1.1/friendships/destroy.json")

        self.run_route(post("/v2/user/mute", {"id": "9", "on": True}), client=self.client)
        self.assertEqual(self.client.rest_calls[-1][1:4], ("/i/api/1.1/mutes/users/create.json", None, {"user_id": "9"}))
        self.run_route(post("/v2/user/mute", {"id": "9", "on": False}), client=self.client)
        self.assertEqual(self.client.rest_calls[-1][1], "/i/api/1.1/mutes/users/destroy.json")

        self.run_route(post("/v2/user/block", {"id": "10", "on": True}), client=self.client)
        self.assertEqual(self.client.rest_calls[-1][1:4], ("/i/api/1.1/blocks/create.json", None, {"user_id": "10"}))
        self.run_route(post("/v2/user/block", {"id": "10", "on": False}), client=self.client)
        self.assertEqual(self.client.rest_calls[-1][1], "/i/api/1.1/blocks/destroy.json")

    def test_on_must_be_a_json_boolean(self):
        for body in ({"id": "1"}, {"id": "1", "on": "true"}, {"id": "1", "on": 1}, {"id": "1", "on": None}):
            self.assertBad(post("/v2/tweet/like", body))
        self.assertNoX()

    def test_ids_must_be_strings_of_digits(self):
        self.assertBad(post("/v2/tweet/like", {"id": 1, "on": True}))
        self.assertBad(post("/v2/tweet/delete", {}))
        self.assertBad(post("/v2/user/block", {"id": "1a", "on": True}))
        self.assertNoX()

    def test_already_done_codes_are_success(self):
        for code in (139, 327, 144, 405):
            client = FakeClient(graphql={"FavoriteTweet": RelayError(403, "x_auth", "x", x_code=code)})
            self.assertEqual(self.run_route(post("/v2/tweet/like", {"id": "1", "on": True}), client=client),
                             {"ok": True}, code)
        client = FakeClient(rest={"/i/api/1.1/mutes/users/create.json": RelayError(502, "x_error", "x", x_code=327)})
        self.assertEqual(self.run_route(post("/v2/user/mute", {"id": "1", "on": True}), client=client), {"ok": True})

    def test_other_errors_are_not_swallowed(self):
        client = FakeClient(graphql={"DeleteTweet": RelayError(429, "rate_limited", "wait", x_code=88)})
        with self.assertRaises(RelayError) as caught:
            self.run_route(post("/v2/tweet/delete", {"id": "1"}), client=client)
        self.assertEqual(caught.exception.status, 429)


TWEET_PATH_123 = ("/i/api/1.1/strato/column/None/tweetId=123,destinationLanguage=None,"
                  "translationSource=Some(Google),feature=None,timeout=None,onlyCached=None"
                  "/translation/service/translateTweet")
PROFILE_PATH_456 = ("/i/api/1.1/strato/column/None/profileUserId=456,destinationLanguage=None,"
                    "translationSource=Some(Google)/translation/service/translateProfile")


class TranslateRouteTests(RouteTestCase):
    # server-design section 9: the REST paths are written out here, not taken from the code under test

    def test_tweet_translate_asks_x_for_the_documented_path(self):
        payload = self.run_route(get("/v2/tweet/translate", id="123"))
        self.assertEqual(self.client.rest_calls, [("GET", TWEET_PATH_123, None, None, None)])
        self.assertEqual(self.client.graphql_calls, [])
        self.assertEqual(self.normalizer.calls, [("normalize_translation", (), {})])
        self.assertEqual(payload["provider"], "Google")

    def test_user_translate_asks_x_for_the_documented_path(self):
        payload = self.run_route(get("/v2/user/translate", id="456"))
        self.assertEqual(self.client.rest_calls, [("GET", PROFILE_PATH_456, None, None, None)])
        self.assertEqual(self.client.graphql_calls, [])
        self.assertEqual(self.normalizer.calls, [("normalize_translation", (), {})])
        self.assertEqual(payload["text"], "こんにちは")

    def test_the_answer_of_x_goes_through_normalize_translation(self):
        client = FakeClient(rest={TWEET_PATH_123: {"marker": "x-answer"}})
        payload = self.run_route(get("/v2/tweet/translate", id="123"), client=client)
        self.assertEqual(payload["marker"], "x-answer")

    def test_path_is_plain_text_without_percent_encoding_or_query(self):
        self.run_route(get("/v2/tweet/translate", id="123"))
        path = self.client.rest_calls[0][1]
        self.assertNotIn("%", path)
        self.assertNotIn("?", path)

    def test_no_translation_is_404_on_both_routes(self):
        for route, path, identifier in (("/v2/tweet/translate", TWEET_PATH_123, "123"),
                                        ("/v2/user/translate", PROFILE_PATH_456, "456")):
            client = FakeClient(rest={path: {"marker": "no-translation"}})
            with self.assertRaises(RelayError) as caught:
                self.run_route(get(route, id=identifier), client=client)
            self.assertEqual((caught.exception.status, caught.exception.code), (404, "not_found"))
            self.assertEqual(caught.exception.message, "翻訳できませんでした。")

    def test_id_is_required_and_numeric_before_anything_is_sent(self):
        client = FakeClient()
        for route in ("/v2/tweet/translate", "/v2/user/translate"):
            self.assertBad(get(route), client=client)
            for bad in ("", "12a", "-1", " 12", "1" * 26, "１２"):
                self.assertBad(get(route, id=bad), client=client)
        self.assertEqual(client.rest_calls, [])
        self.assertEqual(client.graphql_calls, [])

    def test_id_of_25_digits_is_accepted(self):
        digits = "9" * 25
        self.run_route(get("/v2/user/translate", id=digits))
        self.assertEqual(self.client.rest_calls[0][1],
                         "/i/api/1.1/strato/column/None/profileUserId=" + digits
                         + ",destinationLanguage=None,translationSource=Some(Google)/translation/service/translateProfile")

    def test_post_is_405_on_both_routes(self):
        for route in ("/v2/tweet/translate", "/v2/user/translate"):
            client = FakeClient()
            with self.assertRaises(RelayError) as caught:
                routes.dispatch(post(route, {"id": "123"}), client, FakeNormalizer())
            self.assertEqual((caught.exception.status, caught.exception.code), (405, "bad_request"))
            self.assertEqual(client.rest_calls, [])


if __name__ == "__main__":
    unittest.main()
