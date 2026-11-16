import hashlib
import importlib.machinery
import importlib.util
import json
import os
import unittest
from pathlib import Path
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "www" / "cgi-bin" / "xrelay.cgi"
LOADER = importlib.machinery.SourceFileLoader("xrelay_cgi", str(SCRIPT))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
xrelay = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(xrelay)


class CgiValidationTests(unittest.TestCase):
    def test_catalog_allows_only_app_operations(self):
        self.assertIsNotNone(xrelay._catalog_record("GET", "/i/api/graphql/fedFLLzmiCAuzPgA8lyh8Q/HomeTimeline"))
        self.assertIsNotNone(xrelay._catalog_record("GET", "/i/api/graphql/3fEctOs2-FvTB7_mvm1hrQ/SearchTimeline"))
        self.assertIsNotNone(xrelay._catalog_record("POST", "/i/api/graphql/H-t2v_HvFR07ZBP9aOeKoA/CreateTweet"))
        self.assertIsNone(xrelay._catalog_record("POST", "/i/api/graphql/fedFLLzmiCAuzPgA8lyh8Q/HomeTimeline"))
        self.assertIsNone(xrelay._catalog_record("POST", "/i/api/graphql/unknown/DeleteTweet"))

    def test_post_payload_supports_text_and_validated_reply(self):
        payload = {
            "queryId": "H-t2v_HvFR07ZBP9aOeKoA",
            "variables": {
                "tweet_text": "hello",
                "reply": {"in_reply_to_tweet_id": "123", "exclude_reply_user_ids": []},
                "media": {"media_entities": ["unexpected"]},
            },
            "features": {},
        }
        normalized = xrelay._validate_post(
            json.dumps(payload).encode("utf-8"),
            "H-t2v_HvFR07ZBP9aOeKoA",
        )
        result = json.loads(normalized.decode("utf-8"))
        self.assertEqual(result["variables"]["reply"], {
            "in_reply_to_tweet_id": "123",
            "exclude_reply_user_ids": [],
        })
        self.assertEqual(result["variables"]["media"], {"media_entities": [], "possibly_sensitive": False})

        payload["variables"]["reply"] = None
        normalized = xrelay._validate_post(
            json.dumps(payload).encode("utf-8"),
            "H-t2v_HvFR07ZBP9aOeKoA",
        )
        self.assertIsNone(json.loads(normalized.decode("utf-8"))["variables"]["reply"])

        payload["variables"]["reply"] = {"in_reply_to_tweet_id": "not-an-id"}
        with self.assertRaises(xrelay.RequestError):
            xrelay._validate_post(
                json.dumps(payload).encode("utf-8"),
                "H-t2v_HvFR07ZBP9aOeKoA",
            )

        with self.assertRaises(xrelay.RequestError):
            xrelay._validate_post(
                b'{"queryId":"H-t2v_HvFR07ZBP9aOeKoA","variables":{"tweet_text":""}}',
                "H-t2v_HvFR07ZBP9aOeKoA",
            )
        with self.assertRaises(xrelay.RequestError):
            xrelay._validate_post(
                b'{"queryId":"H-t2v_HvFR07ZBP9aOeKoA","variables":{"tweet_text":"x"},"extra":"not allowed"}',
                "H-t2v_HvFR07ZBP9aOeKoA",
            )

    def test_client_key_is_compared_by_hash(self):
        secret = "local-test-key"
        config = {"client_token_sha256": hashlib.sha256(secret.encode("utf-8")).hexdigest()}
        with patch.dict(os.environ, {"HTTP_X_RELAY_KEY": secret}, clear=True):
            self.assertTrue(xrelay._client_token_matches(config))
        with patch.dict(os.environ, {"HTTP_X_RELAY_KEY": "wrong"}, clear=True):
            self.assertFalse(xrelay._client_token_matches(config))

    def test_transaction_script_uses_catalog_fallback_when_x_html_changes(self):
        class Response(object):
            text = json.dumps({"ondemand.s": "https://abs.twimg.com/responsive-web/client-web/ondemand.s.hash.js"})

            def raise_for_status(self):
                return None

        class Session(object):
            def __init__(self):
                self.requested = []

            def get(self, url, timeout=None):
                self.requested.append(url)
                return Response()

        session = Session()

        def missing_html_asset(response):
            raise AttributeError("asset reference missing")

        result = xrelay._get_ondemand_script_url(session, object(), missing_html_asset)
        self.assertTrue(result.endswith("ondemand.s.hash.js"))
        self.assertEqual(len(session.requested), 1)

        def unsafe_html_asset(response):
            return "https://example.invalid/script.js"

        with self.assertRaises(xrelay.RequestError):
            xrelay._get_ondemand_script_url(Session(), object(), unsafe_html_asset)


if __name__ == "__main__":
    unittest.main()
