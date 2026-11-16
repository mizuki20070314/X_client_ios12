import json
import os
import unittest
from pathlib import Path

import testsupport as ts  # sets sys.path for xrelay_app
from xrelay_app import config
from xrelay_app.errors import RelayError


class RelayErrorTests(unittest.TestCase):
    def test_body_has_all_keys_and_nulls(self):
        error = RelayError(404, "not_found", "見つかりません。")
        self.assertEqual(error.status, 404)
        self.assertEqual(error.body(), {"error": {"code": "not_found", "message": "見つかりません。",
                                                  "x_code": None, "retry_after": None}})

    def test_body_carries_x_code_and_retry_after(self):
        error = RelayError(429, "rate_limited", "待ってください。", x_code=88, retry_after=600)
        self.assertEqual(error.body()["error"]["x_code"], 88)
        self.assertEqual(error.body()["error"]["retry_after"], 600)
        self.assertEqual(str(error), "待ってください。")


class PathTests(unittest.TestCase):
    def test_private_root_honours_xrelay_home(self):
        with ts.environment(XRELAY_HOME="/some/where/private"):
            self.assertEqual(config.private_root(), Path("/some/where/private"))

    def test_private_root_defaults_under_home(self):
        home = ts.temp_dir(self)
        with ts.environment(XRELAY_HOME=None, HOME=home, USERPROFILE=home):
            self.assertEqual(config.private_root(), Path(home) / "private" / "xrelay")

    def test_config_path_honours_xrelay_config_then_root(self):
        with ts.environment(XRELAY_CONFIG="/tmp/x/config.json", XRELAY_HOME="/tmp/y"):
            self.assertEqual(config.config_path(), Path("/tmp/x/config.json"))
        with ts.environment(XRELAY_CONFIG=None, XRELAY_HOME="/tmp/y"):
            self.assertEqual(config.config_path(), Path("/tmp/y") / "config.json")


class LoadConfigTests(unittest.TestCase):
    def setUp(self):
        self.dir = ts.temp_dir(self)
        self.path = os.path.join(self.dir, "config.json")
        patcher = ts.environment(XRELAY_CONFIG=self.path, XRELAY_HOME=self.dir)
        patcher.__enter__()
        self.addCleanup(patcher.__exit__, None, None, None)

    def assertUnavailable(self, data=None, raw=None, mode=0o600):
        if raw is not None:
            with open(self.path, "w", encoding="utf-8") as handle:
                handle.write(raw)
            if ts.POSIX:
                os.chmod(self.path, mode)
        elif data is not None:
            ts.write_config(self.path, data, mode)
        with self.assertRaises(RelayError) as caught:
            config.load_config()
        self.assertEqual(caught.exception.status, 503)
        self.assertEqual(caught.exception.code, "unavailable")

    def test_valid_file_loads(self):
        ts.write_config(self.path)
        loaded = config.load_config()
        self.assertEqual(loaded["default_profile"], "account1")

    def test_missing_file_is_unavailable(self):
        with self.assertRaises(RelayError) as caught:
            config.load_config()
        self.assertEqual(caught.exception.status, 503)

    def test_invalid_json_is_unavailable(self):
        self.assertUnavailable(raw="{not json")

    def test_non_object_is_unavailable(self):
        self.assertUnavailable(raw="[1, 2]")

    def test_key_hash_must_be_64_lower_hex(self):
        for bad in ("", "ABC", "a" * 63, "A" * 64, "g" * 64, None, 12):
            data = ts.config_data()
            data["client_token_sha256"] = bad
            self.assertUnavailable(data=data)

    def test_key_hash_with_trailing_newline_is_rejected(self):
        data = ts.config_data()
        data["client_token_sha256"] = data["client_token_sha256"] + "\n"
        self.assertUnavailable(data=data)

    def test_empty_bearer_is_unavailable(self):
        data = ts.config_data(bearer="   ")
        self.assertUnavailable(data=data)

    def test_profiles_must_be_non_empty_dict(self):
        self.assertUnavailable(data=ts.config_data(profiles={}))
        data = ts.config_data()
        data["profiles"] = []
        self.assertUnavailable(data=data)

    @unittest.skipIf(os.name == "nt", "file modes are not enforced on Windows")
    def test_group_or_world_readable_is_refused(self):
        self.assertUnavailable(data=ts.config_data(), mode=0o644)
        self.assertUnavailable(data=ts.config_data(), mode=0o640)

    @unittest.skipIf(os.name == "nt", "file modes are not enforced on Windows")
    def test_mode_600_is_accepted(self):
        ts.write_config(self.path, ts.config_data(), mode=0o600)
        self.assertIn("profiles", config.load_config())


class SelectProfileTests(unittest.TestCase):
    def setUp(self):
        self.config = ts.config_data(profiles={
            "account1": ts.profile(),
            "nocookie": ts.profile(ct0=""),
            "nouser": ts.profile(user_agent=""),
            "broken": "not a dict",
        })

    def test_empty_name_selects_default(self):
        self.assertEqual(config.select_profile(self.config, None)[0], "account1")
        self.assertEqual(config.select_profile(self.config, "")[0], "account1")

    def test_named_profile(self):
        name, profile = config.select_profile(self.config, "account1")
        self.assertEqual(name, "account1")
        self.assertEqual(profile["auth_token"], "auth-test-0000")

    def test_unknown_name_is_bad_request(self):
        with self.assertRaises(RelayError) as caught:
            config.select_profile(self.config, "nobody")
        self.assertEqual((caught.exception.status, caught.exception.code), (400, "bad_request"))

    def test_non_dict_profile_is_bad_request(self):
        with self.assertRaises(RelayError) as caught:
            config.select_profile(self.config, "broken")
        self.assertEqual(caught.exception.status, 400)

    def test_incomplete_session_is_unavailable(self):
        with self.assertRaises(RelayError) as caught:
            config.select_profile(self.config, "nocookie")
        self.assertEqual(caught.exception.status, 503)

    def test_missing_user_agent_is_unavailable(self):
        with self.assertRaises(RelayError) as caught:
            config.select_profile(self.config, "nouser")
        self.assertEqual(caught.exception.status, 503)

    def test_no_default_profile_is_bad_request(self):
        data = dict(self.config, default_profile=None)
        with self.assertRaises(RelayError) as caught:
            config.select_profile(data, None)
        self.assertEqual(caught.exception.status, 400)


class ClientKeyTests(unittest.TestCase):
    def setUp(self):
        self.config = ts.config_data()

    def test_x_relay_key_header(self):
        self.assertTrue(config.client_key_matches(self.config, {"HTTP_X_RELAY_KEY": ts.CLIENT_KEY}))
        self.assertFalse(config.client_key_matches(self.config, {"HTTP_X_RELAY_KEY": "wrong"}))

    def test_bearer_authorization_header(self):
        environ = {"HTTP_AUTHORIZATION": "Bearer " + ts.CLIENT_KEY}
        self.assertTrue(config.client_key_matches(self.config, environ))
        environ = {"HTTP_AUTHORIZATION": "bearer " + ts.CLIENT_KEY}
        self.assertTrue(config.client_key_matches(self.config, environ))

    def test_redirect_authorization_is_used_when_plain_one_is_missing(self):
        environ = {"REDIRECT_HTTP_AUTHORIZATION": "Bearer " + ts.CLIENT_KEY}
        self.assertTrue(config.client_key_matches(self.config, environ))

    def test_missing_or_non_bearer_key_is_refused(self):
        self.assertFalse(config.client_key_matches(self.config, {}))
        self.assertFalse(config.client_key_matches(self.config, {"HTTP_AUTHORIZATION": "Basic abc"}))
        self.assertFalse(config.client_key_matches(self.config, {"HTTP_X_RELAY_KEY": "   "}))

    def test_non_ascii_key_does_not_raise(self):
        self.assertFalse(config.client_key_matches(self.config, {"HTTP_X_RELAY_KEY": "キー"}))

    def test_client_key_is_compared_by_hash(self):
        # ported from the v1 test_cgi.py, with its literal values
        import hashlib
        secret = "local-test-key"
        minimal = {"client_token_sha256": hashlib.sha256(secret.encode("utf-8")).hexdigest()}
        self.assertTrue(config.client_key_matches(minimal, {"HTTP_X_RELAY_KEY": secret}))
        self.assertFalse(config.client_key_matches(minimal, {"HTTP_X_RELAY_KEY": "wrong"}))


class WritePrivateTests(unittest.TestCase):
    def test_writes_bytes_and_replaces_existing_file(self):
        directory = ts.temp_dir(self)
        path = os.path.join(directory, "secret.json")
        config.write_private(path, b"first")
        config.write_private(path, b"second")
        with open(path, "rb") as handle:
            self.assertEqual(handle.read(), b"second")
        self.assertEqual(os.listdir(directory), ["secret.json"])  # no temp file left behind

    def test_refuses_text(self):
        directory = ts.temp_dir(self)
        with self.assertRaises(TypeError):
            config.write_private(os.path.join(directory, "x"), "text")

    @unittest.skipIf(os.name == "nt", "file modes are not enforced on Windows")
    def test_mode_is_600(self):
        directory = ts.temp_dir(self)
        path = os.path.join(directory, "secret.json")
        config.write_private(path, b"x")
        self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)

    def test_failed_write_removes_temp_file(self):
        directory = ts.temp_dir(self)
        missing_dir = os.path.join(directory, "missing", "file.json")
        with self.assertRaises(OSError):
            config.write_private(missing_dir, b"x")
        self.assertEqual(os.listdir(directory), [])


class UpdateProfileCt0Tests(unittest.TestCase):
    def setUp(self):
        self.dir = ts.temp_dir(self)
        self.path = os.path.join(self.dir, "config.json")
        patcher = ts.environment(XRELAY_CONFIG=self.path)
        patcher.__enter__()
        self.addCleanup(patcher.__exit__, None, None, None)
        ts.write_config(self.path, ts.config_data(profiles={
            "account1": ts.profile(),
            "account2": ts.profile(ct0="ct0-other"),
        }))

    def test_replaces_only_that_profiles_ct0(self):
        self.assertTrue(config.update_profile_ct0("account1", "ct0-rotated"))
        with open(self.path, encoding="utf-8") as handle:
            data = json.load(handle)
        self.assertEqual(data["profiles"]["account1"]["ct0"], "ct0-rotated")
        self.assertEqual(data["profiles"]["account1"]["auth_token"], "auth-test-0000")
        self.assertEqual(data["profiles"]["account2"]["ct0"], "ct0-other")
        self.assertEqual(data["client_token_sha256"], ts.key_hash(ts.CLIENT_KEY))

    def test_unknown_profile_changes_nothing(self):
        with open(self.path, "rb") as handle:
            before = handle.read()
        self.assertFalse(config.update_profile_ct0("nobody", "x"))
        with open(self.path, "rb") as handle:
            self.assertEqual(handle.read(), before)

    @unittest.skipIf(os.name == "nt", "file modes are not enforced on Windows")
    def test_file_keeps_mode_600(self):
        config.update_profile_ct0("account1", "ct0-rotated")
        self.assertEqual(os.stat(self.path).st_mode & 0o777, 0o600)


class EnsurePrivateDirTests(unittest.TestCase):
    def test_creates_nested_directories(self):
        directory = ts.temp_dir(self)
        target = os.path.join(directory, "a", "b")
        config.ensure_private_dir(target)
        self.assertTrue(os.path.isdir(target))
        config.ensure_private_dir(target)  # idempotent

    @unittest.skipIf(os.name == "nt", "file modes are not enforced on Windows")
    def test_leaf_mode_is_700(self):
        directory = ts.temp_dir(self)
        target = os.path.join(directory, "cache")
        config.ensure_private_dir(target)
        self.assertEqual(os.stat(target).st_mode & 0o777, 0o700)


if __name__ == "__main__":
    unittest.main()
