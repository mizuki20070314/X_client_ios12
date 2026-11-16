import json
import unittest
from unittest import mock

import testsupport as ts
from xrelay_app import catalog, transaction, xapi
from xrelay_app import config as relay_config
from xrelay_app.errors import RelayError

try:
    import requests
except ImportError:  # the CI machine may not have requests
    requests = None

HOME_QUERY_ID = catalog._read_entries(catalog.BUNDLE_PATH)["ops"]["HomeTimeline"]["queryId"]


class XClientTests(unittest.TestCase):
    def setUp(self):
        self.root, self.config_file = ts.relay_home(self)
        ts.write_config(self.config_file, ts.config_data())
        ts.offline(self)
        self.now = 1_000.0
        self.refresh = mock.Mock(side_effect=lambda profile: dict(ts.KEYS))
        for patcher in (mock.patch.object(transaction, "_refresh_keys", self.refresh),
                        mock.patch.object(xapi, "_now", lambda: self.now)):
            patcher.start()
            self.addCleanup(patcher.stop)
        self.config = ts.config_data()
        self.profile = ts.profile()

    def make(self, *answers, profile=None):
        transport = ts.FakeTransport(*answers)
        client = xapi.XClient(self.config, "account1", profile if profile is not None else self.profile,
                              session_factory=transport.session_factory)
        return client, transport

    def assertRelay(self, error_status, error_code, call, x_code=None, message=None):
        with self.assertRaises(RelayError) as caught:
            call()
        error = caught.exception
        self.assertEqual((error.status, error.code), (error_status, error_code))
        self.assertEqual(error.x_code, x_code)
        if message is not None:
            self.assertEqual(error.message, message)
        return error


class RequestShapeTests(XClientTests):
    def test_graphql_get_puts_variables_features_and_toggles_in_the_query(self):
        client, transport = self.make(ts.json_response({"data": {"home": {}}}))
        result = client.graphql("HomeTimeline", {"count": 20}, field_toggles={"withPayments": False})
        self.assertEqual(result, {"data": {"home": {}}})
        method, url, kwargs = transport.calls[0]
        self.assertEqual(method, "GET")
        self.assertEqual(url, "https://x.com/i/api/graphql/{}/HomeTimeline".format(HOME_QUERY_ID))
        params = dict(kwargs["params"])
        self.assertEqual(params["variables"], '{"count":20}')
        self.assertEqual(params["fieldToggles"], '{"withPayments":false}')
        features = catalog.get_operation("HomeTimeline")["features"]
        self.assertEqual(json.loads(params["features"]), features)
        self.assertEqual(kwargs["timeout"], (5, 40))

    def test_get_omits_empty_features_and_absent_toggles(self):
        fake_operation = {"queryId": "abcdefghij", "method": "GET", "features": {}}
        client, transport = self.make(ts.json_response({"data": {}}))
        with mock.patch.object(catalog, "get_operation", return_value=fake_operation):
            client.graphql("Viewer", {"a": 1})
        self.assertEqual(transport.calls[0][2]["params"], [("variables", '{"a":1}')])

    def test_graphql_post_body_has_variables_and_query_id_only_when_no_features(self):
        client, transport = self.make(ts.json_response({"data": {"favorite_tweet": "Done"}}))
        client.graphql("FavoriteTweet", {"tweet_id": "1"})
        method, url, kwargs = transport.calls[0]
        self.assertEqual(method, "POST")
        self.assertEqual(url, "https://x.com/i/api/graphql/lI07N6Otwv1PhnEgXILM7A/FavoriteTweet")
        self.assertIsNone(kwargs["params"])
        self.assertEqual(kwargs["data"], b'{"variables":{"tweet_id":"1"},"queryId":"lI07N6Otwv1PhnEgXILM7A"}')

    def test_graphql_post_adds_features_and_toggles_when_given(self):
        client, transport = self.make(ts.json_response({"data": {"create_tweet": {}}}))
        client.graphql("CreateTweet", {"tweet_text": "hi"}, field_toggles={"x": True})
        body = json.loads(transport.calls[0][2]["data"].decode("utf-8"))
        self.assertEqual(set(body), {"variables", "queryId", "features", "fieldToggles"})
        self.assertEqual(body["fieldToggles"], {"x": True})
        self.assertEqual(body["queryId"], "l4hk8uVGvR-a8kzQ4nOhPA")

    def test_rest_form_is_urlencoded(self):
        client, transport = self.make(ts.json_response({"ok": 1}))
        self.assertEqual(client.rest("POST", "/i/api/1.1/mutes/users/create.json", form={"user_id": "123"}),
                         {"ok": 1})
        method, url, kwargs = transport.calls[0]
        self.assertEqual((method, url), ("POST", "https://x.com/i/api/1.1/mutes/users/create.json"))
        self.assertEqual(kwargs["data"], b"user_id=123")
        self.assertEqual(kwargs["headers"]["Content-Type"], "application/x-www-form-urlencoded")

    def test_rest_form_keeps_key_order(self):
        client, transport = self.make(ts.json_response({}))
        client.rest("POST", "/i/api/1.1/friendships/create.json", form=[("b", "2"), ("a", "1")])
        self.assertEqual(transport.calls[0][2]["data"], b"b=2&a=1")

    def test_rest_json_body_and_get_params(self):
        client, transport = self.make(ts.json_response({"x": 1}), ts.json_response({"y": 2}))
        client.rest("POST", "/i/api/x.json", json_body={"a": "ふ"})
        self.assertEqual(transport.calls[0][2]["data"], '{"a":"ふ"}'.encode("utf-8"))
        self.assertEqual(transport.calls[0][2]["headers"]["Content-Type"], "application/json")
        client.rest("GET", "/i/api/2/badge_count/badge_count.json", params={"supports_ntab_urt": "1"})
        self.assertEqual(transport.calls[1][2]["params"], {"supports_ntab_urt": "1"})

    def test_headers_and_cookies(self):
        client, transport = self.make(ts.json_response({}))
        client.rest("GET", "/i/api/x.json")
        kwargs = transport.calls[0][2]
        headers = kwargs["headers"]
        self.assertEqual(headers["Authorization"], "Bearer AAAA-test-bearer")
        self.assertEqual(headers["User-Agent"], "Mozilla/5.0 (test browser)")
        self.assertEqual(headers["Accept"], "application/json, text/plain, */*")
        self.assertEqual(headers["Origin"], "https://x.com")
        self.assertEqual(headers["Referer"], "https://x.com/home")
        self.assertEqual(headers["x-csrf-token"], "ct0-test-0000")
        self.assertEqual(headers["x-twitter-active-user"], "yes")
        self.assertEqual(headers["x-twitter-auth-type"], "OAuth2Session")
        self.assertEqual(headers["x-twitter-client-language"], "ja")
        self.assertTrue(headers["x-client-transaction-id"])
        self.assertEqual(headers["sec-ch-ua-platform"], "\"Windows\"")
        self.assertEqual(headers["sec-ch-ua"], self.profile["sec_ch_ua"])
        self.assertEqual(kwargs["cookies"], {"auth_token": "auth-test-0000", "ct0": "ct0-test-0000"})

    def test_bearer_prefix_is_added_when_missing(self):
        self.config["x_bearer_token"] = "AAAA-bare"
        client, transport = self.make(ts.json_response({}))
        client.rest("GET", "/i/api/x.json")
        self.assertEqual(transport.calls[0][2]["headers"]["Authorization"], "Bearer AAAA-bare")

    def test_client_hints_are_omitted_when_not_set(self):
        client, transport = self.make(ts.json_response({}), profile=ts.profile(sec_ch_ua="", sec_ch_ua_platform=""))
        client.rest("GET", "/i/api/x.json")
        headers = transport.calls[0][2]["headers"]
        self.assertNotIn("sec-ch-ua", headers)
        self.assertNotIn("sec-ch-ua-platform", headers)

    def test_session_is_closed_after_each_call(self):
        client, transport = self.make(ts.json_response({}), ts.json_response({}))
        client.rest("GET", "/i/api/x.json")
        client.rest("GET", "/i/api/x.json")
        self.assertEqual(transport.sessions, 2)
        self.assertEqual(transport.closed, 2)

    def test_session_is_closed_after_an_error(self):
        client, transport = self.make(ConnectionError("down"))
        self.assertRelay(502, "x_error", lambda: client.rest("GET", "/i/api/x.json"))
        self.assertEqual(transport.closed, 1)

    def test_default_session_factory_is_requests_session(self):
        if requests is None:
            self.skipTest("requests is not installed here")
        client = xapi.XClient(self.config, "account1", self.profile)
        self.assertIs(client._session_factory, requests.Session)

    def test_without_requests_a_call_is_503(self):
        with mock.patch.object(xapi, "requests", None):
            client = xapi.XClient(self.config, "account1", self.profile)
            self.assertRelay(503, "unavailable", lambda: client.rest("GET", "/i/api/x.json"))


class AnswerTableTests(XClientTests):
    def test_success_returns_the_whole_dict(self):
        payload = {"data": {"viewer": {"x": 1}}}
        client, _ = self.make(ts.json_response(payload))
        self.assertEqual(client.graphql("Viewer", {}), payload)

    def test_network_error_is_502(self):
        client, _ = self.make(ConnectionError("refused"))
        self.assertRelay(502, "x_error", lambda: client.graphql("Viewer", {}), message="Xに接続できませんでした。")

    def test_timeout_on_a_write_is_502_too(self):
        client, _ = self.make(OSError("timed out"))
        self.assertRelay(502, "x_error", lambda: client.rest("POST", "/i/api/x.json", form={}))

    def test_2xx_without_json_is_502(self):
        client, _ = self.make(ts.FakeResponse(200, content=b"<html>maintenance</html>"))
        self.assertRelay(502, "x_error", lambda: client.rest("GET", "/i/api/x.json"))

    def test_2xx_json_that_is_not_an_object_is_502(self):
        client, _ = self.make(ts.FakeResponse(200, content=b"[1, 2]"))
        self.assertRelay(502, "x_error", lambda: client.rest("GET", "/i/api/x.json"))

    def test_empty_404_is_retried_once_after_invalidate(self):
        client, transport = self.make(ts.FakeResponse(404, content=b""), ts.json_response({"ok": True}))
        self.assertEqual(client.rest("GET", "/i/api/x.json"), {"ok": True})
        self.assertEqual(len(transport.calls), 2)
        self.assertEqual(self.refresh.call_count, 2)  # invalidate made the second call refresh the keys

    def test_empty_404_twice_is_502_after_one_retry(self):
        client, transport = self.make(ts.FakeResponse(404, content=b""), ts.FakeResponse(404, content=b""))
        self.assertRelay(502, "x_error", lambda: client.rest("GET", "/i/api/x.json"),
                         message="Xからエラーが返されました。")
        self.assertEqual(len(transport.calls), 2)

    def test_404_with_a_body_is_not_retried(self):
        body = json.dumps({"errors": [{"code": 34, "message": "Sorry"}]}).encode("utf-8")
        client, transport = self.make(ts.FakeResponse(404, content=body))
        self.assertRelay(404, "not_found", lambda: client.graphql("Viewer", {}), x_code=34)
        self.assertEqual(len(transport.calls), 1)

    def test_429_takes_retry_after_from_the_reset_header(self):
        self.now = 1_000.0
        client, _ = self.make(ts.FakeResponse(429, headers={"x-rate-limit-reset": "1300"}))
        error = self.assertRelay(429, "rate_limited", lambda: client.rest("GET", "/i/api/x.json"), x_code=88)
        self.assertEqual(error.retry_after, 300)

    def test_429_without_header_has_no_retry_after(self):
        client, _ = self.make(ts.FakeResponse(429, content=b""))
        error = self.assertRelay(429, "rate_limited", lambda: client.rest("GET", "/i/api/x.json"), x_code=88)
        self.assertIsNone(error.retry_after)

    def test_retry_after_is_never_negative(self):
        self.now = 5_000.0
        client, _ = self.make(ts.FakeResponse(429, headers={"X-Rate-Limit-Reset": "1000"}))
        error = self.assertRelay(429, "rate_limited", lambda: client.rest("GET", "/i/api/x.json"), x_code=88)
        self.assertEqual(error.retry_after, 0)

    def test_error_code_88_in_a_2xx_answer_is_429(self):
        body = json.dumps({"errors": [{"code": 88, "message": "Rate limit exceeded."}]}).encode("utf-8")
        client, _ = self.make(ts.FakeResponse(200, content=body))
        self.assertRelay(429, "rate_limited", lambda: client.graphql("Viewer", {}), x_code=88)

    def test_401_and_403_are_x_auth(self):
        for status in (401, 403):
            client, _ = self.make(ts.FakeResponse(status, content=b""))
            error = self.assertRelay(403, "x_auth", lambda: client.rest("GET", "/i/api/x.json"))
            self.assertIsNone(error.x_code)
            self.assertIn("setup_config.py", error.message)

    def test_auth_codes_are_x_auth_with_the_code(self):
        for code in (32, 64, 89, 215, 326):
            body = json.dumps({"errors": [{"code": code, "message": "auth"}]}).encode("utf-8")
            client, _ = self.make(ts.FakeResponse(200, content=body))
            self.assertRelay(403, "x_auth", lambda: client.graphql("Viewer", {}), x_code=code)

    def test_not_found_codes_without_data_are_404(self):
        for code in (34, 50, 63, 144, 421, 422):
            body = json.dumps({"data": {"user": None}, "errors": [{"code": code, "message": "gone"}]}).encode("utf-8")
            client, _ = self.make(ts.FakeResponse(200, content=body))
            self.assertRelay(404, "not_found", lambda: client.graphql("Viewer", {}), x_code=code)

    def test_other_http_errors_are_502_with_x_message(self):
        body = json.dumps({"errors": [{"code": 131, "message": "Something broke\n  badly"}]}).encode("utf-8")
        client, _ = self.make(ts.FakeResponse(500, content=body))
        error = self.assertRelay(502, "x_error", lambda: client.graphql("Viewer", {}), x_code=131)
        self.assertEqual(error.message, "Something broke badly")

    def test_other_http_error_without_json_has_a_generic_message(self):
        client, _ = self.make(ts.FakeResponse(503, content=b"<html>busy</html>"))
        self.assertRelay(502, "x_error", lambda: client.rest("GET", "/i/api/x.json"),
                         message="Xからエラーが返されました。")

    def test_errors_next_to_usable_data_are_a_success(self):
        payload = {"data": {"user": {"id": "1"}, "other": None}, "errors": [{"code": 50, "message": "partial"}]}
        client, _ = self.make(ts.json_response(payload))
        self.assertEqual(client.graphql("Viewer", {}), payload)

    def test_errors_with_all_null_data_are_a_failure(self):
        payload = {"data": {"user": None}, "errors": [{"code": 215, "message": "bad"}]}
        client, _ = self.make(ts.json_response(payload))
        self.assertRelay(403, "x_auth", lambda: client.graphql("Viewer", {}), x_code=215)

    def test_errors_with_null_data_and_no_code_are_502(self):
        payload = {"data": None, "errors": [{"message": "Something went wrong"}]}
        client, _ = self.make(ts.json_response(payload))
        error = self.assertRelay(502, "x_error", lambda: client.graphql("Viewer", {}))
        self.assertEqual(error.message, "Something went wrong")

    def test_errors_without_message_use_the_generic_text(self):
        client, _ = self.make(ts.json_response({"errors": [{"code": 999}]}))
        error = self.assertRelay(502, "x_error", lambda: client.graphql("Viewer", {}), x_code=999)
        self.assertEqual(error.message, "Xからエラーが返されました。")

    def test_empty_errors_list_is_a_success(self):
        client, _ = self.make(ts.json_response({"data": {}, "errors": []}))
        self.assertEqual(client.graphql("Viewer", {}), {"data": {}, "errors": []})


class CtZeroTests(XClientTests):
    def test_rotated_ct0_is_used_for_the_rest_of_the_request_and_stored(self):
        client, transport = self.make(
            ts.FakeResponse(403, content=json.dumps({"errors": [{"code": 353, "message": "csrf"}]}).encode(),
                            cookies={"ct0": "ct0-rotated"}),
            ts.json_response({"ok": True}),
        )
        self.assertEqual(client.rest("GET", "/i/api/x.json"), {"ok": True})
        second = transport.calls[1][2]
        self.assertEqual(second["headers"]["x-csrf-token"], "ct0-rotated")
        self.assertEqual(second["cookies"]["ct0"], "ct0-rotated")
        with open(self.config_file, encoding="utf-8") as handle:
            stored = json.load(handle)
        self.assertEqual(stored["profiles"]["account1"]["ct0"], "ct0-rotated")
        self.assertEqual(self.profile["ct0"], "ct0-rotated")

    def test_353_without_a_new_ct0_is_x_auth(self):
        body = json.dumps({"errors": [{"code": 353, "message": "csrf"}]}).encode("utf-8")
        client, transport = self.make(ts.FakeResponse(403, content=body))
        self.assertRelay(403, "x_auth", lambda: client.rest("GET", "/i/api/x.json"), x_code=353)
        self.assertEqual(len(transport.calls), 1)

    def test_353_is_repeated_only_once(self):
        body = json.dumps({"errors": [{"code": 353, "message": "csrf"}]}).encode("utf-8")
        client, transport = self.make(
            ts.FakeResponse(403, content=body, cookies={"ct0": "ct0-one"}),
            ts.FakeResponse(403, content=body, cookies={"ct0": "ct0-two"}),
            ts.json_response({"never": True}),
        )
        self.assertRelay(403, "x_auth", lambda: client.rest("GET", "/i/api/x.json"), x_code=353)
        self.assertEqual(len(transport.calls), 2)

    def test_a_failing_config_write_does_not_stop_the_request(self):
        client, transport = self.make(ts.FakeResponse(200, content=b'{"ok":1}', cookies={"ct0": "ct0-new"}),
                                      ts.json_response({"ok": 2}))
        with mock.patch.object(relay_config, "update_profile_ct0", side_effect=OSError("disk full")):
            self.assertEqual(client.rest("GET", "/i/api/x.json"), {"ok": 1})
            self.assertEqual(client.rest("GET", "/i/api/x.json"), {"ok": 2})
        self.assertEqual(transport.calls[1][2]["headers"]["x-csrf-token"], "ct0-new")

    def test_same_ct0_is_not_a_rotation(self):
        client, _ = self.make(ts.FakeResponse(200, content=b'{"a":1}', cookies={"ct0": "ct0-test-0000"}))
        with mock.patch.object(relay_config, "update_profile_ct0") as update:
            client.rest("GET", "/i/api/x.json")
        update.assert_not_called()

    def test_conflicting_cookie_values_are_ignored(self):
        class Jar(object):
            def __bool__(self):
                return True

            def get(self, name):
                raise ValueError("two cookies named ct0")

        self.assertIsNone(xapi._cookie_value(mock.Mock(cookies=Jar()), "ct0"))
        self.assertIsNone(xapi._cookie_value(mock.Mock(cookies={}), "ct0"))
        self.assertIsNone(xapi._cookie_value(mock.Mock(cookies=None), "ct0"))


class RawTests(XClientTests):
    def test_raw_passes_the_answer_through_unchanged(self):
        body = json.dumps({"errors": [{"code": 34, "message": "Sorry"}]}).encode("utf-8")
        client, transport = self.make(ts.FakeResponse(404, headers={"Content-Type": "application/json; charset=utf-8"},
                                                      content=body))
        status, content_type, content = client.raw("GET", "/i/api/graphql/x/Y", params=[("a", "1")])
        self.assertEqual((status, content_type, content), (404, "application/json; charset=utf-8", body))
        self.assertEqual(transport.calls[0][2]["params"], [("a", "1")])

    def test_raw_defaults_the_content_type(self):
        client, _ = self.make(ts.FakeResponse(200, content=b"not json at all"))
        status, content_type, content = client.raw("GET", "/i/api/x.json")
        self.assertEqual((status, content_type, content), (200, "application/json; charset=utf-8", b"not json at all"))

    def test_raw_retries_an_empty_404_once(self):
        client, transport = self.make(ts.FakeResponse(404, content=b""), ts.FakeResponse(200, content=b"{}"))
        self.assertEqual(client.raw("GET", "/i/api/x.json")[0], 200)
        self.assertEqual(len(transport.calls), 2)

    def test_raw_post_sends_the_given_body_and_content_type(self):
        client, transport = self.make(ts.FakeResponse(200, content=b"{}"))
        client.raw("POST", "/i/api/graphql/x/CreateTweet", body=b'{"a":1}')
        method, _, kwargs = transport.calls[0]
        self.assertEqual(method, "POST")
        self.assertEqual(kwargs["data"], b'{"a":1}')
        self.assertIsNone(kwargs["params"])
        self.assertEqual(kwargs["headers"]["Content-Type"], "application/json")

    def test_transaction_id_failure_happens_before_any_request(self):
        self.refresh.side_effect = RuntimeError("no keys at all")
        client, transport = self.make(ts.json_response({}))
        self.assertRelay(502, "x_error", lambda: client.rest("GET", "/i/api/x.json"))
        self.assertEqual(transport.calls, [])


class HelperTests(unittest.TestCase):
    def test_compact_json_and_bearer(self):
        self.assertEqual(xapi._compact({"a": [1, "ふ"]}), '{"a":[1,"ふ"]}')
        self.assertEqual(xapi._bearer_header(" AAAA "), "Bearer AAAA")
        self.assertEqual(xapi._bearer_header("bearer AAAA"), "bearer AAAA")
        self.assertEqual(xapi._bearer_header(None), "")


if __name__ == "__main__":
    unittest.main()
