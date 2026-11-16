import json
import os
import sys
import unittest
from unittest import mock

import testsupport as ts
from xrelay_app import catalog
from xrelay_app.errors import RelayError

# server-design section 4: the operations the catalog must know, with their methods
EXPECTED = {
    "HomeTimeline": "GET", "HomeLatestTimeline": "GET", "TweetDetail": "GET", "SearchTimeline": "GET",
    "UserByScreenName": "GET", "UserByRestId": "GET", "UserTweets": "GET", "UserTweetsAndReplies": "GET",
    "UserMedia": "GET", "Likes": "GET", "Following": "GET", "Followers": "GET",
    "NotificationsTimeline": "GET", "Bookmarks": "GET", "ExplorePage": "GET", "GenericTimelineById": "GET",
    "Viewer": "GET",
    "FavoriteTweet": "POST", "UnfavoriteTweet": "POST", "CreateRetweet": "POST", "DeleteRetweet": "POST",
    "CreateBookmark": "POST", "DeleteBookmark": "POST", "CreateTweet": "POST", "DeleteTweet": "POST",
}
DAY = 24 * 60 * 60
REAL_DOWNLOAD = catalog._download_document  # kept before setUp replaces the module attribute with a mock


def bundled_document():
    """An API.json-shaped document built from the bundled snapshot (so the tests need no network)."""
    with open(str(catalog.BUNDLE_PATH), encoding="utf-8") as handle:
        ops = json.load(handle)["ops"]
    graphql = {}
    for name, entry in ops.items():
        graphql[name] = {"url": "https://x.com/i/api/graphql/x/" + name, "queryId": entry["queryId"],
                         "method": entry["method"], "features": dict(entry["features"])}
    return {"graphql": graphql, "header": {}}


class CatalogTests(unittest.TestCase):
    def setUp(self):
        self.root, _ = ts.relay_home(self)
        self.cache_file = os.path.join(self.root, "cache", "ops.json")
        self.now = [1_800_000_000.0]
        self.download = mock.Mock(side_effect=OSError("offline in tests"))
        for patcher in (mock.patch.object(catalog, "_download_document", self.download),
                        mock.patch.object(catalog, "_now", lambda: self.now[0])):
            patcher.start()
            self.addCleanup(patcher.stop)

    def write_cache(self, fetched_at, ops):
        os.makedirs(os.path.dirname(self.cache_file), exist_ok=True)
        with open(self.cache_file, "w", encoding="utf-8") as handle:
            json.dump({"fetched_at": int(fetched_at), "ops": ops}, handle)

    def entry(self, name, query_id):
        return {"queryId": query_id, "method": EXPECTED[name], "features": {"feature_a": True}}


class OperationTableTests(CatalogTests):
    def test_names_and_methods_are_exactly_section_4(self):
        self.assertEqual(catalog.OPERATIONS, EXPECTED)
        self.assertEqual(len(catalog.OPERATIONS), 25)

    def test_bundled_snapshot_has_all_25_valid_operations(self):
        with open(str(catalog.BUNDLE_PATH), encoding="utf-8") as handle:
            document = json.load(handle)
        self.assertEqual(sorted(document), ["fetched_at", "ops"])
        entries = catalog._read_entries(catalog.BUNDLE_PATH)
        self.assertEqual(sorted(entries["ops"]), sorted(EXPECTED))
        for name, entry in entries["ops"].items():
            self.assertEqual(entry["method"], EXPECTED[name])
            self.assertRegex(entry["queryId"], r"^[A-Za-z0-9_-]{10,40}$")
            self.assertIsInstance(entry["features"], dict)
            self.assertTrue(all(isinstance(value, bool) for value in entry["features"].values()))

    def test_get_operation_answers_from_the_bundle_offline(self):
        entry = catalog.get_operation("HomeTimeline")
        self.assertEqual(entry["method"], "GET")
        self.assertEqual(entry["queryId"], catalog._read_entries(catalog.BUNDLE_PATH)["ops"]["HomeTimeline"]["queryId"])
        self.assertEqual(self.download.call_count, 1)  # the download was tried, and failed, as offline

    def test_unknown_operation_is_503(self):
        with self.assertRaises(RelayError) as caught:
            catalog.get_operation("NoSuchOperation")
        self.assertEqual((caught.exception.status, caught.exception.code), (503, "unavailable"))


class ValidationTests(CatalogTests):
    def test_query_id_pattern(self):
        for query_id in ("abcdefghij", "a" * 40, "Ab-_09xyz0"):
            self.assertIsNotNone(catalog._valid_entry("Viewer", {"queryId": query_id, "method": "GET",
                                                                 "features": {}}), query_id)
        for query_id in ("abc", "a" * 41, "bad id with spaces", "abcdefghi!", "", None, 1234567890):
            self.assertIsNone(catalog._valid_entry("Viewer", {"queryId": query_id, "method": "GET",
                                                              "features": {}}), repr(query_id))

    def test_method_must_be_the_expected_one(self):
        self.assertIsNone(catalog._valid_entry("HomeTimeline", {"queryId": "abcdefghij", "method": "POST",
                                                                "features": {}}))

    def test_features_must_be_a_dict_of_bools(self):
        base = {"queryId": "abcdefghij", "method": "GET"}
        self.assertIsNotNone(catalog._valid_entry("Viewer", dict(base, features={})))
        for features in ({"a": 1}, {"a": None}, {"a": "true"}, [], None):
            self.assertIsNone(catalog._valid_entry("Viewer", dict(base, features=features)), repr(features))

    def test_not_a_dict_is_invalid(self):
        self.assertIsNone(catalog._valid_entry("Viewer", None))
        self.assertIsNone(catalog._valid_entry("Viewer", ["abcdefghij"]))

    def test_reduce_document_keeps_valid_entries_and_reports_the_rest(self):
        document = bundled_document()
        document["graphql"]["HomeTimeline"]["queryId"] = "short"
        document["graphql"]["CreateTweet"]["method"] = "GET"
        document["graphql"]["Viewer"]["features"]["flag"] = "yes"
        del document["graphql"]["Bookmarks"]
        document["graphql"]["UnrelatedOperation"] = {"queryId": "abcdefghij", "method": "GET", "features": {}}
        entries, problems = catalog.reduce_document(document)
        self.assertEqual(sorted(problems), ["Bookmarks", "CreateTweet", "HomeTimeline", "Viewer"])
        self.assertEqual(len(entries), 21)
        self.assertNotIn("UnrelatedOperation", entries)
        self.assertEqual(set(entries) | set(problems), set(EXPECTED))

    def test_reduce_document_of_garbage_reports_everything(self):
        entries, problems = catalog.reduce_document("not a document")
        self.assertEqual(entries, {})
        self.assertEqual(sorted(problems), sorted(EXPECTED))


class SourceOrderTests(CatalogTests):
    def test_fresh_cache_answers_without_download(self):
        self.write_cache(self.now[0] - 3600, {"HomeTimeline": self.entry("HomeTimeline", "CACHEDQUERY1")})
        self.assertEqual(catalog.get_operation("HomeTimeline")["queryId"], "CACHEDQUERY1")
        self.assertEqual(self.download.call_count, 0)

    def test_fresh_cache_without_the_operation_does_not_download(self):
        self.write_cache(self.now[0] - 3600, {"Viewer": self.entry("Viewer", "CACHEDVIEWER1")})
        entry = catalog.get_operation("HomeTimeline")
        self.assertEqual(entry["queryId"], catalog._read_entries(catalog.BUNDLE_PATH)["ops"]["HomeTimeline"]["queryId"])
        self.assertEqual(self.download.call_count, 0)

    def test_no_cache_downloads_and_writes_the_cache(self):
        document = bundled_document()
        document["graphql"]["HomeTimeline"]["queryId"] = "DOWNLOADQRY1"
        self.download.side_effect = None
        self.download.return_value = document
        self.assertEqual(catalog.get_operation("HomeTimeline")["queryId"], "DOWNLOADQRY1")
        self.assertEqual(self.download.call_count, 1)
        with open(self.cache_file, encoding="utf-8") as handle:
            written = json.load(handle)
        self.assertEqual(written["fetched_at"], int(self.now[0]))
        self.assertEqual(written["ops"]["HomeTimeline"]["queryId"], "DOWNLOADQRY1")
        self.assertEqual(sorted(written["ops"]), sorted(EXPECTED))

    def test_downloaded_cache_is_fresh_for_24_hours(self):
        self.download.side_effect = None
        self.download.return_value = bundled_document()
        catalog.get_operation("Viewer")
        self.now[0] += 23 * 3600
        catalog.get_operation("Viewer")
        self.assertEqual(self.download.call_count, 1)

    def test_failed_download_uses_the_stale_cache(self):
        self.write_cache(self.now[0] - 2 * DAY, {"HomeTimeline": self.entry("HomeTimeline", "STALEQUERY01")})
        self.assertEqual(catalog.get_operation("HomeTimeline")["queryId"], "STALEQUERY01")
        self.assertEqual(self.download.call_count, 1)

    def test_failed_download_without_cache_uses_the_bundle(self):
        bundled = catalog._read_entries(catalog.BUNDLE_PATH)["ops"]["Viewer"]
        self.assertEqual(catalog.get_operation("Viewer"), bundled)
        self.assertFalse(os.path.exists(self.cache_file))

    def test_no_source_at_all_is_503(self):
        with mock.patch.object(catalog, "BUNDLE_PATH", os.path.join(self.root, "nothing.json")):
            with self.assertRaises(RelayError) as caught:
                catalog.get_operation("Viewer")
        self.assertEqual(caught.exception.status, 503)

    def test_corrupt_cache_file_is_ignored(self):
        os.makedirs(os.path.dirname(self.cache_file), exist_ok=True)
        with open(self.cache_file, "w", encoding="utf-8") as handle:
            handle.write("{not json")
        self.download.side_effect = None
        self.download.return_value = bundled_document()
        self.assertEqual(catalog.get_operation("Viewer")["method"], "GET")
        self.assertEqual(self.download.call_count, 1)


class DownloadDecisionTests(CatalogTests):
    def test_invalid_download_entry_falls_back_to_the_stale_cache(self):
        self.write_cache(self.now[0] - 2 * DAY, {"HomeTimeline": self.entry("HomeTimeline", "STALEQUERY01")})
        document = bundled_document()
        document["graphql"]["HomeTimeline"]["method"] = "POST"  # invalid for this operation
        document["graphql"]["Viewer"]["queryId"] = "NEWVIEWERQRY"
        self.download.side_effect = None
        self.download.return_value = document
        self.assertEqual(catalog.get_operation("HomeTimeline")["queryId"], "STALEQUERY01")
        self.assertEqual(catalog.get_operation("Viewer")["queryId"], "NEWVIEWERQRY")

    def test_entries_missing_from_the_download_keep_their_old_value(self):
        self.write_cache(self.now[0] - 2 * DAY, {"Likes": self.entry("Likes", "OLDLIKESQRY1")})
        document = bundled_document()
        del document["graphql"]["Likes"]
        self.download.side_effect = None
        self.download.return_value = document
        self.assertEqual(catalog.get_operation("Likes")["queryId"], "OLDLIKESQRY1")

    def test_download_without_any_valid_entry_counts_as_a_failure(self):
        self.write_cache(self.now[0] - 2 * DAY, {"HomeTimeline": self.entry("HomeTimeline", "STALEQUERY01")})
        self.download.side_effect = None
        self.download.return_value = {"graphql": {}}
        self.assertEqual(catalog.get_operation("HomeTimeline")["queryId"], "STALEQUERY01")
        self.assertEqual(self.download.call_count, 1)

    def test_failures_back_off_for_an_hour(self):
        self.write_cache(self.now[0] - 2 * DAY, {"HomeTimeline": self.entry("HomeTimeline", "STALEQUERY01")})
        catalog.get_operation("HomeTimeline")
        self.assertEqual(self.download.call_count, 1)
        self.now[0] += 30 * 60
        catalog.get_operation("HomeTimeline")
        self.assertEqual(self.download.call_count, 1)
        self.now[0] += 31 * 60
        catalog.get_operation("HomeTimeline")
        self.assertEqual(self.download.call_count, 2)

    def test_download_size_limit(self):
        fake = mock.Mock()
        fake.get.return_value = ts.FakeResponse(200, content=b"x" * (catalog.MAX_DOWNLOAD_BYTES + 1))
        with mock.patch.dict(sys.modules, {"requests": fake}):
            with self.assertRaises(ValueError):
                REAL_DOWNLOAD()

    def test_download_uses_the_timeouts_of_section_3_5(self):
        fake = mock.Mock()
        fake.get.return_value = ts.FakeResponse(200, content=json.dumps({"graphql": {}}).encode("utf-8"))
        with mock.patch.dict(sys.modules, {"requests": fake}):
            self.assertEqual(REAL_DOWNLOAD(), {"graphql": {}})
        args, kwargs = fake.get.call_args
        self.assertEqual(kwargs["timeout"], (5, 15))
        self.assertTrue(args[0].endswith("/docs/json/API.json"))


if __name__ == "__main__":
    unittest.main()
