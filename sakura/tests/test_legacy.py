import json
import os
import unittest

import testsupport as ts
from xrelay_app import cgiio, legacy
from xrelay_app.errors import RelayError

PAYLOAD_QUERY_ID = "H-t2v_HvFR07ZBP9aOeKoA"
HOME_PATH = "/i/api/graphql/fedFLLzmiCAuzPgA8lyh8Q/HomeTimeline"
SEARCH_PATH = "/i/api/graphql/3fEctOs2-FvTB7_mvm1hrQ/SearchTimeline"
CREATE_PATH = "/i/api/graphql/" + PAYLOAD_QUERY_ID + "/CreateTweet"
JSON_TYPE = "application/json; charset=utf-8"


class RawClient(object):
    """Records the raw calls; answers with a fixed (status, content type, body)."""

    def __init__(self, answer=(200, JSON_TYPE, b'{"data":{"home":{}}}')):
        self.answer = answer
        self.calls = []

    def raw(self, method, path, params=None, body=None):
        self.calls.append((method, path, params, body))
        return self.answer


def request(method, path, query=None, body=b""):
    return cgiio.Request(method, path, list(query or []), {}, body)


def expect_error(testcase, status, call, message=None):
    with testcase.assertRaises(RelayError) as caught:
        call()
    testcase.assertEqual(caught.exception.status, status)
    if message is not None:
        testcase.assertEqual(caught.exception.message, message)
    return caught.exception


class CatalogRecordTests(unittest.TestCase):
    # ported from the v1 test_cgi.py: the same rows of the bundled www/requests.ndjson must be found
    def test_catalog_allows_only_app_operations(self):
        self.assertIsNotNone(legacy.catalog_record("GET", HOME_PATH, ts.WWW_DIR))
        self.assertIsNotNone(legacy.catalog_record("GET", SEARCH_PATH, ts.WWW_DIR))
        self.assertIsNotNone(legacy.catalog_record("POST", CREATE_PATH, ts.WWW_DIR))
        self.assertIsNone(legacy.catalog_record("POST", HOME_PATH, ts.WWW_DIR))
        self.assertIsNone(legacy.catalog_record("POST", "/i/api/graphql/unknown/DeleteTweet", ts.WWW_DIR))

    def test_only_the_three_operations_are_allowed(self):
        self.assertEqual(legacy.ALLOWED_OPERATIONS,
                         {("GET", "HomeTimeline"), ("GET", "SearchTimeline"), ("POST", "CreateTweet")})

    def test_a_row_must_match_method_and_path(self):
        directory = ts.temp_dir(self)
        rows = [{"method": "POST", "path": "/graphql/abcdefghij/HomeTimeline"},
                {"method": "GET", "path": "/graphql/zzzzzzzzzz/HomeTimeline"}]
        with open(os.path.join(directory, "requests.ndjson"), "w", encoding="utf-8") as handle:
            handle.write("\n".join(json.dumps(row) for row in rows) + "\n\n")
        self.assertIsNone(legacy.catalog_record("GET", "/i/api/graphql/abcdefghij/HomeTimeline", directory))
        self.assertIsNotNone(legacy.catalog_record("GET", "/i/api/graphql/zzzzzzzzzz/HomeTimeline", directory))

    def test_non_dict_rows_are_skipped(self):
        directory = ts.temp_dir(self)
        with open(os.path.join(directory, "requests.ndjson"), "w", encoding="utf-8") as handle:
            handle.write("[1]\n" + json.dumps({"method": "GET", "path": "/graphql/q/HomeTimeline"}) + "\n")
        self.assertIsNotNone(legacy.catalog_record("GET", "/i/api/graphql/q/HomeTimeline", directory))

    def test_no_catalog_directory_is_503(self):
        expect_error(self, 503, lambda: legacy.catalog_record("GET", HOME_PATH, None))

    def test_missing_or_broken_catalog_is_503(self):
        directory = ts.temp_dir(self)
        expect_error(self, 503, lambda: legacy.catalog_record("GET", HOME_PATH, directory))
        with open(os.path.join(directory, "requests.ndjson"), "w", encoding="utf-8") as handle:
            handle.write("{broken\n")
        expect_error(self, 503, lambda: legacy.catalog_record("GET", HOME_PATH, directory))

    def test_paths_outside_i_api_are_not_catalog_routes(self):
        self.assertIsNone(legacy.catalog_record("GET", "/v2/home", ts.WWW_DIR))


class ValidatePostTests(unittest.TestCase):
    # ported from the v1 test_cgi.py test_post_payload_supports_text_and_validated_reply
    def test_text_and_validated_reply(self):
        payload = {
            "queryId": PAYLOAD_QUERY_ID,
            "variables": {
                "tweet_text": "hello",
                "reply": {"in_reply_to_tweet_id": "123", "exclude_reply_user_ids": []},
                "media": {"media_entities": ["unexpected"]},
            },
            "features": {},
        }
        normalized = legacy.validate_post(json.dumps(payload).encode("utf-8"), PAYLOAD_QUERY_ID)
        result = json.loads(normalized.decode("utf-8"))
        self.assertEqual(result["variables"]["reply"], {"in_reply_to_tweet_id": "123",
                                                        "exclude_reply_user_ids": []})
        self.assertEqual(result["variables"]["media"], {"media_entities": [], "possibly_sensitive": False})

        payload["variables"]["reply"] = None
        normalized = legacy.validate_post(json.dumps(payload).encode("utf-8"), PAYLOAD_QUERY_ID)
        self.assertIsNone(json.loads(normalized.decode("utf-8"))["variables"]["reply"])

        payload["variables"]["reply"] = {"in_reply_to_tweet_id": "not-an-id"}
        with self.assertRaises(RelayError):
            legacy.validate_post(json.dumps(payload).encode("utf-8"), PAYLOAD_QUERY_ID)

        with self.assertRaises(RelayError):
            legacy.validate_post(
                b'{"queryId":"H-t2v_HvFR07ZBP9aOeKoA","variables":{"tweet_text":""}}', PAYLOAD_QUERY_ID)
        with self.assertRaises(RelayError):
            legacy.validate_post(
                b'{"queryId":"H-t2v_HvFR07ZBP9aOeKoA","variables":{"tweet_text":"x"},"extra":"not allowed"}',
                PAYLOAD_QUERY_ID)

    def test_the_v1_texts_are_kept(self):
        def error_for(body, query_id=PAYLOAD_QUERY_ID):
            with self.assertRaises(RelayError) as caught:
                legacy.validate_post(body, query_id)
            return caught.exception.message
        self.assertEqual(error_for(b"nope"), "Expected a JSON request body.")
        self.assertEqual(error_for(b"[]"), "Unsupported post payload.")
        self.assertEqual(error_for(b'{"queryId":"other","variables":{}}'),
                         "GraphQL query ID does not match the selected operation.")
        self.assertEqual(error_for(json.dumps({"queryId": PAYLOAD_QUERY_ID}).encode()),
                         "Missing post variables.")
        self.assertEqual(error_for(json.dumps({"queryId": PAYLOAD_QUERY_ID,
                                               "variables": {"tweet_text": "x" * 281}}).encode()),
                         "Post text must be between 1 and 280 characters.")
        self.assertEqual(error_for(json.dumps({"queryId": PAYLOAD_QUERY_ID,
                                               "variables": {"tweet_text": "x", "reply": "x"}}).encode()),
                         "Reply payload is invalid.")

    def test_text_limit_is_280_characters_untrimmed(self):
        ok = json.dumps({"queryId": PAYLOAD_QUERY_ID, "variables": {"tweet_text": "x" * 280}}).encode()
        self.assertTrue(legacy.validate_post(ok, PAYLOAD_QUERY_ID))
        blank = json.dumps({"queryId": PAYLOAD_QUERY_ID, "variables": {"tweet_text": "  "}}).encode()
        expect_error(self, 400, lambda: legacy.validate_post(blank, PAYLOAD_QUERY_ID))

    def test_reply_exclusions_are_checked(self):
        def body(reply):
            return json.dumps({"queryId": PAYLOAD_QUERY_ID,
                               "variables": {"tweet_text": "x", "reply": reply}}).encode()
        expect_error(self, 400, lambda: legacy.validate_post(
            body({"in_reply_to_tweet_id": "1", "exclude_reply_user_ids": ["2"] * 51}), PAYLOAD_QUERY_ID))
        expect_error(self, 400, lambda: legacy.validate_post(
            body({"in_reply_to_tweet_id": "1", "exclude_reply_user_ids": ["x"]}), PAYLOAD_QUERY_ID))
        expect_error(self, 400, lambda: legacy.validate_post(
            body({"in_reply_to_tweet_id": "1", "exclude_reply_user_ids": "2"}), PAYLOAD_QUERY_ID))
        normalized = json.loads(legacy.validate_post(
            body({"in_reply_to_tweet_id": "1"}), PAYLOAD_QUERY_ID).decode("utf-8"))
        self.assertEqual(normalized["variables"]["reply"], {"in_reply_to_tweet_id": "1",
                                                            "exclude_reply_user_ids": []})

    def test_numeric_id_must_not_end_with_a_newline(self):
        body = json.dumps({"queryId": PAYLOAD_QUERY_ID,
                           "variables": {"tweet_text": "x",
                                         "reply": {"in_reply_to_tweet_id": "123\n"}}}).encode()
        expect_error(self, 400, lambda: legacy.validate_post(body, PAYLOAD_QUERY_ID))

    def test_output_is_compact_utf8_json(self):
        body = json.dumps({"queryId": PAYLOAD_QUERY_ID, "variables": {"tweet_text": "ふむ"}},
                          ensure_ascii=False).encode("utf-8")
        out = legacy.validate_post(body, PAYLOAD_QUERY_ID)
        text_bytes = "ふむ".encode("utf-8")
        self.assertIn(text_bytes, out)
        self.assertNotIn(b" ", out.replace(text_bytes, b""))


class DispatchTests(unittest.TestCase):
    def test_get_is_passed_through_unchanged(self):
        client = RawClient((404, "application/json; charset=utf-8", b'{"errors":[{"code":34}]}'))
        query = [("variables", "{}"), ("features", "{}")]
        result = legacy.dispatch(request("GET", HOME_PATH, query), client, ts.WWW_DIR)
        self.assertEqual(result, (404, "application/json; charset=utf-8", b'{"errors":[{"code":34}]}'))
        self.assertEqual(client.calls, [("GET", HOME_PATH, query, None)])

    def test_search_get_is_allowed_too(self):
        client = RawClient()
        legacy.dispatch(request("GET", SEARCH_PATH, [("variables", "{}")]), client, ts.WWW_DIR)
        self.assertEqual(client.calls[0][1], SEARCH_PATH)

    def test_post_create_tweet_sends_the_normalised_body(self):
        client = RawClient()
        body = json.dumps({"queryId": PAYLOAD_QUERY_ID, "variables": {"tweet_text": "hi", "reply": None}}).encode()
        legacy.dispatch(request("POST", CREATE_PATH, body=body), client, ts.WWW_DIR)
        method, path, params, sent = client.calls[0]
        self.assertEqual((method, path, params), ("POST", CREATE_PATH, []))
        self.assertEqual(sent, legacy.validate_post(body, PAYLOAD_QUERY_ID))

    def test_get_of_create_tweet_is_not_enabled(self):
        client = RawClient()
        error = expect_error(self, 404, lambda: legacy.dispatch(request("GET", CREATE_PATH), client, ts.WWW_DIR),
                             message="This GraphQL operation is not enabled.")
        self.assertEqual(error.status, 404)
        self.assertEqual(client.calls, [])

    def test_post_of_home_timeline_is_not_enabled(self):
        client = RawClient()
        expect_error(self, 404, lambda: legacy.dispatch(request("POST", HOME_PATH, body=b"{}"), client, ts.WWW_DIR))
        self.assertEqual(client.calls, [])

    def test_unknown_query_parameter_is_400(self):
        client = RawClient()
        expect_error(self, 400,
                     lambda: legacy.dispatch(request("GET", HOME_PATH, [("evil", "1")]), client, ts.WWW_DIR),
                     message="Unsupported GraphQL query parameter.")
        self.assertEqual(client.calls, [])

    def test_catalog_mismatch_is_404_before_anything_else(self):
        client = RawClient()
        expect_error(self, 404, lambda: legacy.dispatch(
            request("GET", "/i/api/graphql/wrongwrongwr/HomeTimeline"), client, ts.WWW_DIR))

    def test_without_a_catalog_directory_the_allowed_operations_are_503(self):
        client = RawClient()
        expect_error(self, 503, lambda: legacy.dispatch(request("GET", HOME_PATH), client, None))
        self.assertEqual(client.calls, [])

    def test_the_v1_response_of_a_transport_failure_is_the_client_error(self):
        class Broken(RawClient):
            def raw(self, method, path, params=None, body=None):
                raise RelayError(502, "x_error", "Xに接続できませんでした。")
        expect_error(self, 502, lambda: legacy.dispatch(request("GET", HOME_PATH), Broken(), ts.WWW_DIR))


if __name__ == "__main__":
    unittest.main()
