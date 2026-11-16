import json
import os
import unittest
from unittest import mock

import testsupport as ts
from xrelay_app import transaction
from xrelay_app.errors import RelayError

# server-design section 3.4: the reference vectors (key and animation key are the invented ones of the spec)
KEY = "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8w"
ANIM = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345"
VECTORS = [
    ("GET", "/i/api/graphql/vLHjqbDv7TPFMBkIIO1nOA/SearchTimeline", 111222333, 77,
     "TUxPTklIS0pFREdGQUBDQl1cX15ZWFtaVVRXVlFQU1JtbG9uaWhramVkZ2ZhYGNifXBT7Etz6J5dLhLRh8Tc6K3KycfNTg"),
    ("POST", "/i/api/graphql/lI07N6Otwv1PhnEgXILM7A/FavoriteTweet", 1, 0,
     "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gISIjJCUmJygpKissLS4vMAEAAADXuL+VG/3ewPfmWctnDC4YAw"),
    ("GET", "/i/api/1.1/dm/inbox_initial_state.json", 2317075600, 255,
     "//79/Pv6+fj39vX08/Lx8O/u7ezr6uno5+bl5OPi4eDf3t3c29rZ2NfW1dTT0tHQz2875HUB+ppDmRLlGBp6RShreI87/A"),
]
EPOCH_OFFSET = 1682924400
DEPS_MISSING = True
try:
    import bs4  # noqa: F401
    import x_client_transaction  # noqa: F401
    DEPS_MISSING = False
except ImportError:
    pass

# an invented snippet with the shape that the pattern of server-design section 3.4 describes
SCRIPT_SNIPPET = (
    '(function(e){return(({12345:"ondemand.s",99:"other"})[e]||e)+"."+({12345:"abcdef12",'
    '99:"ffffff"}[e]+"a"))})'
)


class GenerateTests(unittest.TestCase):
    def test_reference_vectors(self):
        for method, path, time_now, rand, expected in VECTORS:
            result = transaction.generate_transaction_id(method, path, KEY, ANIM,
                                                         now=time_now + EPOCH_OFFSET, rand=rand)
            self.assertEqual(result, expected, path)

    def test_result_is_unpadded_base64(self):
        result = transaction.generate_transaction_id("GET", "/x", KEY, ANIM, now=EPOCH_OFFSET + 5, rand=3)
        self.assertNotIn("=", result)
        self.assertRegex(result, r"^[A-Za-z0-9+/]+$")

    def test_default_now_and_rand_are_used_when_missing(self):
        with mock.patch.object(transaction, "_now", return_value=EPOCH_OFFSET + 111222333):
            with mock.patch.object(transaction.random, "randint", return_value=77):
                result = transaction.generate_transaction_id(
                    "GET", "/i/api/graphql/vLHjqbDv7TPFMBkIIO1nOA/SearchTimeline", KEY, ANIM)
        self.assertEqual(result, VECTORS[0][4])

    def test_fraction_of_a_second_is_floored(self):
        a = transaction.generate_transaction_id("GET", "/x", KEY, ANIM, now=EPOCH_OFFSET + 9.99, rand=0)
        b = transaction.generate_transaction_id("GET", "/x", KEY, ANIM, now=EPOCH_OFFSET + 9, rand=0)
        self.assertEqual(a, b)

    def test_key_without_padding_is_accepted(self):
        padded = KEY + "=" * (-len(KEY) % 4)
        self.assertEqual(
            transaction.generate_transaction_id("GET", "/x", KEY, ANIM, now=EPOCH_OFFSET, rand=1),
            transaction.generate_transaction_id("GET", "/x", padded, ANIM, now=EPOCH_OFFSET, rand=1))

    def test_invalid_key_raises_value_error(self):
        with self.assertRaises(ValueError):
            transaction.generate_transaction_id("GET", "/x", "not base64 !!", ANIM, now=EPOCH_OFFSET, rand=1)


class ScriptUrlTests(unittest.TestCase):
    def test_script_url_is_built_from_the_hash_of_the_chunk_id(self):
        self.assertEqual(transaction.find_script_url(SCRIPT_SNIPPET),
                         "https://abs.twimg.com/responsive-web/client-web/ondemand.s.abcdef12a.js")

    def test_no_match_without_the_ondemand_table(self):
        self.assertIsNone(transaction.find_script_url("<html>no script table here</html>"))
        self.assertIsNone(transaction.find_script_url('{12345:"ondemand.s"} plain, no table'))

    def test_chunk_id_must_match_the_name_key(self):
        mismatched = SCRIPT_SNIPPET.replace("12345:\"abcdef12\"", "55555:\"abcdef12\"")
        self.assertIsNone(transaction.find_script_url(mismatched))

    def test_valid_urls_are_accepted(self):
        self.assertTrue(transaction.is_valid_script_url(
            "https://abs.twimg.com/responsive-web/client-web/ondemand.s.abcdef12a.js"))

    def test_invalid_urls_are_rejected(self):
        bad = [
            "http://abs.twimg.com/responsive-web/client-web/ondemand.s.abcdef12a.js",
            "https://example.com/responsive-web/client-web/ondemand.s.abcdef12a.js",
            "https://abs.twimg.com/responsive-web/client-web/ondemand.s.abcdef12a.js?x=1",
            "https://abs.twimg.com/responsive-web/client-web/ondemand.s.abcdef12a.js#frag",
            "https://abs.twimg.com/responsive-web/client-web/other.abcdef12a.js",
            "https://abs.twimg.com/responsive-web/client-web/ondemand.s.abcdef12a.css",
            "https://user@abs.twimg.com/responsive-web/client-web/ondemand.s.abcdef12a.js",
            "https://abs.twimg.com:8443/responsive-web/client-web/ondemand.s.abcdef12a.js",
            "https://x.com/responsive-web/client-web/ondemand.s.abcdef12a.js",
            None,
            42,
            "",
        ]
        for url in bad:
            self.assertFalse(transaction.is_valid_script_url(url), url)


class CacheTests(unittest.TestCase):
    def setUp(self):
        self.root, _ = ts.relay_home(self)
        self.now = [1_800_000_000.0]
        self.refresh = mock.Mock(side_effect=lambda profile: dict(ts.KEYS))
        patchers = [
            mock.patch.object(transaction, "_refresh_keys", self.refresh),
            mock.patch.object(transaction, "_now", lambda: self.now[0]),
        ]
        for patcher in patchers:
            patcher.start()
            self.addCleanup(patcher.stop)
        self.profile = ts.profile()

    def keys_file(self, profile=None):
        fingerprint = transaction._fingerprint(profile or self.profile)
        return os.path.join(self.root, "tid-cache", fingerprint, "keys.json")

    def test_first_call_refreshes_and_caches(self):
        value = transaction.get_transaction_id(self.profile, "GET", "/i/api/x")
        self.assertTrue(len(value) > 80)
        self.assertEqual(self.refresh.call_count, 1)
        with open(self.keys_file(), encoding="utf-8") as handle:
            stored = json.load(handle)
        self.assertEqual(stored["key"], ts.KEYS["key"])
        self.assertEqual(stored["fetched_at"], int(self.now[0]))
        self.assertEqual(stored["source"], ts.KEYS["source"])

    @unittest.skipIf(os.name == "nt", "file modes are not enforced on Windows")
    def test_cache_files_are_private(self):
        transaction.get_transaction_id(self.profile, "GET", "/i/api/x")
        self.assertEqual(os.stat(self.keys_file()).st_mode & 0o777, 0o600)
        self.assertEqual(os.stat(os.path.dirname(self.keys_file())).st_mode & 0o777, 0o700)

    def test_fresh_cache_is_used_without_refresh(self):
        transaction.get_transaction_id(self.profile, "GET", "/i/api/x")
        self.now[0] += 5 * 3600
        transaction.get_transaction_id(self.profile, "GET", "/i/api/x")
        self.assertEqual(self.refresh.call_count, 1)

    def test_stale_cache_after_six_hours_refreshes(self):
        transaction.get_transaction_id(self.profile, "GET", "/i/api/x")
        self.now[0] += 6 * 3600
        transaction.get_transaction_id(self.profile, "GET", "/i/api/x")
        self.assertEqual(self.refresh.call_count, 2)

    def test_refresh_failure_keeps_an_old_cache_of_any_age(self):
        transaction.get_transaction_id(self.profile, "GET", "/i/api/x")
        self.now[0] += 30 * 24 * 3600
        self.refresh.side_effect = RuntimeError("network down")
        value = transaction.get_transaction_id(self.profile, "GET", "/i/api/x")
        self.assertTrue(value)
        self.assertEqual(self.refresh.call_count, 2)

    def test_refresh_failure_without_cache_is_502(self):
        self.refresh.side_effect = RuntimeError("network down")
        with self.assertRaises(RelayError) as caught:
            transaction.get_transaction_id(self.profile, "GET", "/i/api/x")
        self.assertEqual((caught.exception.status, caught.exception.code), (502, "x_error"))

    def test_relay_error_from_refresh_without_cache_is_passed_on(self):
        self.refresh.side_effect = RelayError(503, "unavailable", "依存パッケージが足りません。")
        with self.assertRaises(RelayError) as caught:
            transaction.get_transaction_id(self.profile, "GET", "/i/api/x")
        self.assertEqual(caught.exception.status, 503)

    def test_relay_error_from_refresh_with_cache_falls_back(self):
        transaction.get_transaction_id(self.profile, "GET", "/i/api/x")
        self.now[0] += 7 * 3600
        self.refresh.side_effect = RelayError(502, "x_error", "x")
        self.assertTrue(transaction.get_transaction_id(self.profile, "GET", "/i/api/x"))

    def test_invalidate_forces_the_next_call_to_refresh(self):
        transaction.get_transaction_id(self.profile, "GET", "/i/api/x")
        transaction.invalidate(self.profile)
        transaction.get_transaction_id(self.profile, "GET", "/i/api/x")
        self.assertEqual(self.refresh.call_count, 2)

    def test_invalidate_keeps_old_keys_as_fallback(self):
        transaction.get_transaction_id(self.profile, "GET", "/i/api/x")
        transaction.invalidate(self.profile)
        self.refresh.side_effect = RuntimeError("network down")
        self.assertTrue(transaction.get_transaction_id(self.profile, "GET", "/i/api/x"))
        with open(self.keys_file(), encoding="utf-8") as handle:
            self.assertEqual(json.load(handle)["fetched_at"], 0)

    def test_invalidate_without_cache_does_nothing(self):
        transaction.invalidate(self.profile)
        self.assertEqual(self.refresh.call_count, 0)
        self.assertFalse(os.path.exists(self.keys_file()))

    def test_corrupt_cache_counts_as_absent(self):
        transaction.get_transaction_id(self.profile, "GET", "/i/api/x")
        with open(self.keys_file(), "w", encoding="utf-8") as handle:
            handle.write("{broken")
        transaction.get_transaction_id(self.profile, "GET", "/i/api/x")
        self.assertEqual(self.refresh.call_count, 2)

    def test_each_user_agent_has_its_own_cache(self):
        other = ts.profile(user_agent="Other UA")
        transaction.get_transaction_id(self.profile, "GET", "/i/api/x")
        transaction.get_transaction_id(other, "GET", "/i/api/x")
        self.assertEqual(self.refresh.call_count, 2)
        self.assertNotEqual(self.keys_file(), self.keys_file(other))

    def test_unopenable_lock_file_does_not_block_the_refresh(self):
        fingerprint = transaction._fingerprint(self.profile)
        os.makedirs(os.path.join(self.root, "tid-cache", fingerprint, "tid.lock"))  # a directory is no lock file
        self.assertTrue(transaction.get_transaction_id(self.profile, "GET", "/i/api/x"))
        self.assertEqual(self.refresh.call_count, 1)

    def test_cache_root_that_cannot_be_a_directory_is_503(self):
        os.makedirs(self.root, exist_ok=True)
        with open(os.path.join(self.root, "tid-cache"), "w", encoding="utf-8") as handle:
            handle.write("a file where the cache directory should be")
        with self.assertRaises(RelayError) as caught:
            transaction.get_transaction_id(self.profile, "GET", "/i/api/x")
        self.assertEqual(caught.exception.status, 503)
        self.assertEqual(self.refresh.call_count, 0)

    def test_refresh_result_with_bad_key_is_neither_cached_nor_used(self):
        self.refresh.side_effect = lambda profile: dict(ts.KEYS, key="!!!")
        with self.assertRaises(RelayError) as caught:
            transaction.get_transaction_id(self.profile, "GET", "/i/api/x")
        self.assertEqual(caught.exception.status, 502)
        self.assertFalse(os.path.exists(self.keys_file()))

    def test_bad_refresh_result_falls_back_to_an_old_cache(self):
        transaction.get_transaction_id(self.profile, "GET", "/i/api/x")
        self.now[0] += 7 * 3600
        self.refresh.side_effect = lambda profile: dict(ts.KEYS, animation_key="")
        self.assertTrue(transaction.get_transaction_id(self.profile, "GET", "/i/api/x"))


class _CatalogResponse(object):
    def __init__(self, text):
        self.text = text

    def raise_for_status(self):
        return None


class _CatalogSession(object):
    def __init__(self, text):
        self.text = text
        self.requested = []

    def get(self, url, timeout=None):
        self.requested.append(url)
        return _CatalogResponse(self.text)


def _missing_html_asset(response):
    raise AttributeError("asset reference missing")


class ScriptFallbackTests(unittest.TestCase):
    # ported from the v1 test_cgi.py: when the HTML has no script name, the catalog of script names answers
    def test_catalog_fallback_when_x_html_changes(self):
        session = _CatalogSession(json.dumps(
            {"ondemand.s": "https://abs.twimg.com/responsive-web/client-web/ondemand.s.hash.js"}))
        result = transaction._fallback_script_url(session, object(), _missing_html_asset)
        self.assertTrue(result.endswith("ondemand.s.hash.js"))
        self.assertEqual(len(session.requested), 1)
        self.assertTrue(transaction.is_valid_script_url(result))

    def test_unsafe_catalog_url_is_rejected_by_validation(self):
        session = _CatalogSession(json.dumps({"ondemand.s": "https://example.invalid/script.js"}))
        result = transaction._fallback_script_url(session, object(), _missing_html_asset)
        self.assertEqual(result, "https://example.invalid/script.js")
        self.assertFalse(transaction.is_valid_script_url(result))

    def test_html_lookup_comes_first_and_needs_no_request(self):
        session = _CatalogSession("")
        result = transaction._fallback_script_url(
            session, object(),
            lambda response: "https://abs.twimg.com/responsive-web/client-web/ondemand.s.aa.js")
        self.assertEqual(session.requested, [])
        self.assertTrue(result.endswith("ondemand.s.aa.js"))

    def test_nothing_found_anywhere_gives_none(self):
        session = _CatalogSession(json.dumps({"other": "x"}))
        self.assertIsNone(transaction._fallback_script_url(session, object(), _missing_html_asset))


class RefreshDependencyTests(unittest.TestCase):
    @unittest.skipUnless(DEPS_MISSING, "bs4 and x_client_transaction are installed; no network test here")
    def test_missing_dependencies_are_503_without_network(self):
        with self.assertRaises(RelayError) as caught:
            transaction._refresh_keys(ts.profile())
        self.assertEqual(caught.exception.status, 503)


if __name__ == "__main__":
    unittest.main()
