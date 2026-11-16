import gzip
import io
import json
import os
import shutil
import subprocess
import sys
import unittest
from unittest import mock

import testsupport as ts
from xrelay_app import main
from xrelay_app.errors import RelayError

LEGACY_HOME = "/i/api/graphql/fedFLLzmiCAuzPgA8lyh8Q/HomeTimeline"
LEGACY_CREATE = "/i/api/graphql/H-t2v_HvFR07ZBP9aOeKoA/CreateTweet"
JSON_TYPE = "application/json; charset=utf-8"
REAL_MAKE_NORMALIZER = main.make_normalizer  # kept before setUp replaces it with a fake


class EchoClient(object):
    """Stands in for XClient: records calls, answers with the operation name."""

    def __init__(self, error=None, raw_answer=(200, JSON_TYPE, b'{"raw":true}')):
        self.error = error
        self.raw_answer = raw_answer
        self.calls = []

    def graphql(self, name, variables, field_toggles=None):
        self.calls.append(("graphql", name, variables, field_toggles))
        if self.error is not None:
            raise self.error
        return {"data": {"echo": name}}

    def rest(self, method, path, params=None, form=None, json_body=None):
        self.calls.append(("rest", method, path))
        return {}

    def raw(self, method, path, params=None, body=None):
        self.calls.append(("raw", method, path, params, body))
        return self.raw_answer


class EchoNormalizer(object):
    def normalize_timeline(self, data, focal_id=None):
        return {"items": [{"t": "tweet", "name": data["data"]["echo"], "focal_id": focal_id}],
                "top": None, "bottom": "BOTTOM"}

    def normalize_explore(self, data):
        return {"tabs": [], "tab": "for_you", "items": [], "top": None, "bottom": None}

    def normalize_user_response(self, data):
        return {"id": "1"}

    def normalize_created_tweet(self, data):
        return {"id": "2"}


class MainTestCase(unittest.TestCase):
    def setUp(self):
        self.root, self.config_file = ts.relay_home(self)
        ts.write_config(self.config_file, ts.config_data(profiles={
            "account1": ts.profile(),
            "other": ts.profile(auth_token="auth-other", ct0="ct0-other"),
        }))
        ts.offline(self)
        self.client = EchoClient()
        self.made = []

        def make_client(settings, name, profile):
            self.made.append((name, profile))
            return self.client

        for patcher in (mock.patch.object(main, "make_client", make_client),
                        mock.patch.object(main, "make_normalizer", lambda: EchoNormalizer())):
            patcher.start()
            self.addCleanup(patcher.stop)

    def environ(self, path, method="GET", key=True, body=b"", **extra):
        values = {"REQUEST_METHOD": method, "QUERY_STRING": "__path=" + path}
        if key:
            values["HTTP_X_RELAY_KEY"] = ts.CLIENT_KEY
        if method == "POST":
            values["CONTENT_LENGTH"] = str(len(body))
        values.update(extra)
        return values

    def call(self, environ, body=b"", www_root=None, stdin=None):
        stdout = ts.FakeStdout()
        main.handle(environ, stdin if stdin is not None else io.BytesIO(body), stdout, www_root)
        status, headers, content = ts.split_response(stdout)
        return status, headers, content

    def json_of(self, content):
        return json.loads(content.decode("utf-8"))


class HandleBasicsTests(MainTestCase):
    def test_healthz_needs_no_key_and_no_config(self):
        os.remove(self.config_file)
        status, headers, content = self.call(self.environ("/healthz", key=False))
        self.assertEqual(status, 200)
        self.assertEqual(self.json_of(content), {"status": "ok"})
        self.assertEqual(headers["cache-control"], "no-store")

    def test_missing_key_on_a_v2_route_is_401_with_the_object_body(self):
        status, _, content = self.call(self.environ("/v2/home", key=False))
        self.assertEqual(status, 401)
        self.assertEqual(self.json_of(content)["error"]["code"], "unauthorized")

    def test_wrong_key_is_401(self):
        environ = self.environ("/v2/home", key=False, HTTP_X_RELAY_KEY="wrong")
        self.assertEqual(self.call(environ)[0], 401)
        self.assertEqual(self.client.calls, [])

    def test_bearer_key_is_accepted(self):
        environ = self.environ("/v2/home", key=False, HTTP_AUTHORIZATION="Bearer " + ts.CLIENT_KEY)
        self.assertEqual(self.call(environ)[0], 200)

    def test_profiles_without_key_uses_the_old_error_body(self):
        status, _, content = self.call(self.environ("/profiles", key=False))
        self.assertEqual(status, 401)
        self.assertEqual(self.json_of(content), {"error": "CGIキーが無効か、指定されていません。"})

    def test_profiles_lists_sorted_names(self):
        status, _, content = self.call(self.environ("/profiles"))
        self.assertEqual(status, 200)
        self.assertEqual(self.json_of(content), {"profiles": ["account1", "other"]})

    def test_unknown_route_bodies_depend_on_the_path(self):
        status, _, content = self.call(self.environ("/nope"))
        self.assertEqual((status, self.json_of(content)), (404, {"error": "Unknown API route."}))
        status, _, content = self.call(self.environ("/v2/nope"))
        self.assertEqual(status, 404)
        self.assertEqual(self.json_of(content)["error"]["code"], "not_found")
        status, _, content = self.call(self.environ("/i/api/other/thing"))
        self.assertEqual((status, self.json_of(content)), (404, {"error": "Unknown API route."}))

    def test_wrong_method_is_405(self):
        status, _, content = self.call(self.environ("/profiles", method="PUT"))
        self.assertEqual((status, self.json_of(content)), (405, {"error": "GETとPOSTだけ使えます。"}))
        status, _, content = self.call(self.environ("/v2/home", method="PUT"))
        self.assertEqual(status, 405)
        self.assertEqual(self.json_of(content)["error"]["code"], "bad_request")

    def test_bad_route_parameter_is_400(self):
        environ = {"REQUEST_METHOD": "GET", "QUERY_STRING": "__path=/v2/a&__path=/v2/b",
                   "HTTP_X_RELAY_KEY": ts.CLIENT_KEY}
        status, _, content = self.call(environ)
        self.assertEqual(status, 400)
        self.assertEqual(self.json_of(content)["error"]["code"], "bad_request")

    def test_unknown_profile_is_400(self):
        status, _, content = self.call(self.environ("/v2/home", **{"HTTP_X_PROFILE_NAME": "nobody"}))
        self.assertEqual(status, 400)
        self.assertEqual(self.json_of(content)["error"]["code"], "bad_request")

    def test_missing_config_is_503_in_both_shapes(self):
        os.remove(self.config_file)
        status, _, content = self.call(self.environ("/profiles"))
        self.assertEqual(status, 503)
        self.assertIn("error", self.json_of(content))
        status, _, content = self.call(self.environ("/v2/home"))
        self.assertEqual(status, 503)
        self.assertEqual(self.json_of(content)["error"]["code"], "unavailable")

    @unittest.skipIf(os.name == "nt", "file modes are not enforced on Windows")
    def test_world_readable_config_is_503(self):
        os.chmod(self.config_file, 0o644)
        self.assertEqual(self.call(self.environ("/v2/home"))[0], 503)

    def test_oversized_post_is_413(self):
        environ = self.environ("/v2/tweet/create", method="POST", CONTENT_LENGTH=str(256 * 1024 + 1))
        status, _, content = self.call(environ, stdin=io.BytesIO(b""))
        self.assertEqual(status, 413)
        self.assertEqual(self.json_of(content)["error"]["code"], "bad_request")

    def test_internal_error_is_500_without_details(self):
        self.client.error = RuntimeError("token=SECRET-VALUE-123 at /home/x/y.py")
        stderr = io.StringIO()
        with mock.patch.object(sys, "stderr", stderr):
            status, _, content = self.call(self.environ("/v2/home"))
        self.assertEqual(status, 500)
        body = self.json_of(content)
        self.assertEqual(body["error"]["code"], "internal")
        self.assertNotIn("SECRET", content.decode("utf-8"))
        self.assertNotIn("Traceback", content.decode("utf-8"))
        self.assertEqual(stderr.getvalue(), "xrelay: internal error (RuntimeError)\n")

    def test_internal_error_on_the_old_route_uses_the_object_body(self):
        with mock.patch.object(main, "make_client", side_effect=KeyError("boom")), \
                mock.patch.object(sys, "stderr", io.StringIO()):
            status, _, content = self.call(self.environ(LEGACY_HOME))
        self.assertEqual(status, 500)
        self.assertEqual(self.json_of(content)["error"]["code"], "internal")

    def test_a_broken_output_stream_does_not_raise(self):
        class Broken(object):
            def write(self, text):
                raise IOError("closed")

            def flush(self):
                pass
        main.handle(self.environ("/healthz", key=False), io.BytesIO(b""), Broken(), None)


class V2EndToEndTests(MainTestCase):
    def test_home_answers_the_normalised_timeline(self):
        status, headers, content = self.call(self.environ("/v2/home"))
        self.assertEqual(status, 200)
        self.assertEqual(self.json_of(content)["items"][0]["name"], "HomeTimeline")
        self.assertEqual(self.made[0][0], "account1")

    def test_query_parameters_are_passed_on(self):
        environ = {"REQUEST_METHOD": "GET", "QUERY_STRING": "__path=/v2/home&tab=following",
                   "HTTP_X_RELAY_KEY": ts.CLIENT_KEY}
        self.call(environ)
        self.assertEqual(self.client.calls[0][1], "HomeLatestTimeline")

    def test_profile_header_selects_the_profile(self):
        self.call(self.environ("/v2/home", HTTP_X_PROFILE_NAME=" other "))
        name, profile = self.made[0]
        self.assertEqual(name, "other")
        self.assertEqual(profile["ct0"], "ct0-other")

    def test_post_routes_read_the_json_body(self):
        body = json.dumps({"id": "77", "on": True}).encode("utf-8")
        status, _, content = self.call(self.environ("/v2/tweet/like", method="POST", body=body), body=body)
        self.assertEqual(status, 200)
        self.assertEqual(self.json_of(content), {"ok": True})
        self.assertEqual(self.client.calls[0][1], "FavoriteTweet")

    def test_x_rate_limit_is_answered_with_retry_after(self):
        self.client.error = RelayError(429, "rate_limited", "wait", x_code=88, retry_after=600)
        status, _, content = self.call(self.environ("/v2/home"))
        self.assertEqual(status, 429)
        self.assertEqual(self.json_of(content)["error"], {"code": "rate_limited", "message": "wait",
                                                          "x_code": 88, "retry_after": 600})

    def test_a_missing_normalizer_module_is_503(self):
        with mock.patch.object(main, "make_normalizer", REAL_MAKE_NORMALIZER):
            with mock.patch.dict(sys.modules, {"xrelay_app.normalize": None}):
                status, _, content = self.call(self.environ("/v2/home"))
        self.assertEqual(status, 503)
        self.assertEqual(self.json_of(content)["error"]["code"], "unavailable")

    def test_large_answers_are_gzipped_on_request(self):
        with mock.patch.object(main, "make_normalizer", lambda: _Big()):
            status, headers, content = self.call(self.environ("/v2/home", HTTP_ACCEPT_ENCODING="gzip"))
        self.assertEqual(status, 200)
        self.assertEqual(headers["content-encoding"], "gzip")
        self.assertGreater(len(gzip.decompress(content)), 1024)


class _Big(object):
    def normalize_timeline(self, data, focal_id=None):
        return {"items": [{"t": "text", "text": "x" * 3000}], "top": None, "bottom": None}


class LegacyEndToEndTests(MainTestCase):
    def test_get_is_passed_through_as_x_sent_it(self):
        self.client.raw_answer = (201, "application/json; charset=utf-8", b'{"exact":"bytes"}')
        environ = self.environ(LEGACY_HOME, **{"QUERY_STRING": "__path=" + LEGACY_HOME + "&variables=%7B%7D"})
        status, headers, content = self.call(environ, www_root=ts.WWW_DIR)
        self.assertEqual(status, 201)
        self.assertEqual(headers["content-type"], "application/json; charset=utf-8")
        self.assertEqual(content, b'{"exact":"bytes"}')
        self.assertEqual(self.client.calls[0][0:3], ("raw", "GET", LEGACY_HOME))

    def test_post_create_tweet_goes_through_the_validation(self):
        body = json.dumps({"queryId": "H-t2v_HvFR07ZBP9aOeKoA", "variables": {"tweet_text": "hi"}}).encode()
        status, _, content = self.call(self.environ(LEGACY_CREATE, method="POST", body=body),
                                       body=body, www_root=ts.WWW_DIR)
        self.assertEqual(status, 200)
        sent = self.client.calls[0][4]
        self.assertEqual(json.loads(sent.decode("utf-8"))["variables"]["media"],
                         {"media_entities": [], "possibly_sensitive": False})

    def test_v1_errors_keep_the_old_body(self):
        status, _, content = self.call(self.environ("/i/api/graphql/x/DeleteTweet"), www_root=ts.WWW_DIR)
        self.assertEqual(status, 404)
        self.assertEqual(self.json_of(content), {"error": "This GraphQL operation is not enabled."})

    def test_missing_catalog_root_is_503_with_the_old_body(self):
        status, _, content = self.call(self.environ(LEGACY_HOME), www_root=None)
        self.assertEqual(status, 503)
        self.assertIn("error", self.json_of(content))
        self.assertIsInstance(self.json_of(content)["error"], str)

    def test_the_v1_body_limit_gives_the_old_shape_too(self):
        environ = self.environ(LEGACY_CREATE, method="POST", CONTENT_LENGTH=str(256 * 1024 + 1))
        status, _, content = self.call(environ, stdin=io.BytesIO(b""), www_root=ts.WWW_DIR)
        self.assertEqual(status, 413)
        self.assertIsInstance(self.json_of(content)["error"], str)


class CgiEntryPointTests(unittest.TestCase):
    """Runs the real www/cgi-bin/xrelay.cgi in a child process, the way Apache does (with -I)."""

    def run_cgi(self, home, path="/healthz", extra_env=None):
        env = dict(os.environ)
        for key in list(env):
            if key.startswith("HTTP_") or key in ("XRELAY_CONFIG", "PYTHONPATH"):
                env.pop(key)
        env.update({"REQUEST_METHOD": "GET", "QUERY_STRING": "__path=" + path, "XRELAY_HOME": home})
        env.update(extra_env or {})
        result = subprocess.run([sys.executable, "-I", ts.CGI_PATH], input=b"", stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, env=env, timeout=120)
        # on Windows the text-mode header write turns the CRLF into CRCRLF (the old CGI did the same); the server
        # is POSIX, where no such translation happens
        result.stdout = result.stdout.replace(b"\r\r\n", b"\r\n")
        return result

    def test_installed_application_answers(self):
        home = ts.temp_dir(self)
        shutil.copytree(os.path.join(ts.APP_DIR, "xrelay_app"), os.path.join(home, "app", "xrelay_app"),
                        ignore=shutil.ignore_patterns("__pycache__"))
        result = self.run_cgi(home)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(b"Status: 200 OK\r\n", result.stdout)
        self.assertTrue(result.stdout.endswith(b'\r\n\r\n{"status":"ok"}'), result.stdout)

    def test_missing_application_is_answered_503_without_traceback(self):
        home = ts.temp_dir(self)
        result = self.run_cgi(home)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(b"Status: 503 Service Unavailable\r\n", result.stdout)
        self.assertTrue(result.stdout.endswith(b'{"error": "CGI application is not installed."}'))
        self.assertNotIn(b"Traceback", result.stdout)

    def test_broken_application_is_answered_503_without_traceback(self):
        home = ts.temp_dir(self)
        package = os.path.join(home, "app", "xrelay_app")
        os.makedirs(package)
        with open(os.path.join(package, "__init__.py"), "w", encoding="utf-8") as handle:
            handle.write('raise ValueError("broken install")\n')
        result = self.run_cgi(home)
        self.assertIn(b"Status: 503 Service Unavailable\r\n", result.stdout)
        self.assertNotIn(b"Traceback", result.stdout)
        self.assertNotIn(b"broken install", result.stdout)

    def test_entry_point_is_a_thin_file_with_the_documented_shebang(self):
        with open(ts.CGI_PATH, encoding="utf-8") as handle:
            first = handle.readline()
        self.assertEqual(first, "#!/usr/local/bin/python\n")


if __name__ == "__main__":
    unittest.main()
