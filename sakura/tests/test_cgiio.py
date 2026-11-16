import gzip
import io
import json
import unittest

import testsupport as ts
from xrelay_app import cgiio
from xrelay_app.errors import RelayError


def environ(method="GET", query="__path=/v2/home", body=b"", **extra):
    values = {"REQUEST_METHOD": method, "QUERY_STRING": query}
    if method == "POST":
        values["CONTENT_LENGTH"] = str(len(body))
    values.update(extra)
    return values


def parse(method="GET", query="__path=/v2/home", body=b"", stdin=None, **extra):
    env = environ(method, query, body, **extra)
    return cgiio.read_request(env, stdin if stdin is not None else io.BytesIO(body))


class ReadRequestTests(unittest.TestCase):
    def test_get_path_and_query_without_path_parameter(self):
        request = parse(query="__path=/v2/home&tab=following&tab=foryou&empty=")
        self.assertEqual(request.method, "GET")
        self.assertEqual(request.path, "/v2/home")
        self.assertEqual(request.query, [("tab", "following"), ("tab", "foryou"), ("empty", "")])
        self.assertEqual(request.param("tab"), "following")
        self.assertEqual(request.param("missing", "dflt"), "dflt")
        self.assertEqual(request.body, b"")

    def test_get_does_not_read_stdin(self):
        class Stdin(object):
            def read(self, *args):
                raise AssertionError("GET must not read the body")
        request = cgiio.read_request(environ("GET"), Stdin())
        self.assertEqual(request.body, b"")

    def test_method_other_than_get_post_is_405(self):
        for method in ("PUT", "DELETE", "HEAD", ""):
            with self.assertRaises(RelayError) as caught:
                cgiio.read_request(environ(method), io.BytesIO())
            self.assertEqual(caught.exception.status, 405, method)

    def test_path_parameter_must_be_exactly_one(self):
        for query in ("", "tab=1", "__path=/a&__path=/b"):
            with self.assertRaises(RelayError) as caught:
                parse(query=query)
            self.assertEqual(caught.exception.status, 400, query)

    def test_invalid_paths_are_refused(self):
        bad = ["v2/home", "/v2/../secret", "/v2/%2e%2e/secret", "/v2\\x", "/v2/a%00b", "/v2/..", ""]
        for path in bad:
            with self.assertRaises(RelayError) as caught:
                parse(query="__path=" + path)
            self.assertEqual(caught.exception.status, 400, path)

    def test_post_reads_body_of_content_length(self):
        body = b'{"text":"hi"}'
        request = parse("POST", "__path=/v2/tweet/create", body)
        self.assertEqual(request.body, body)
        self.assertEqual(request.json(), {"text": "hi"})

    def test_bad_content_length_is_400(self):
        for value in ("abc", "-1", "1_0", " ", "1e3"):
            env = environ("POST", "__path=/v2/x", b"{}", CONTENT_LENGTH=value)
            with self.assertRaises(RelayError) as caught:
                cgiio.read_request(env, io.BytesIO(b"{}"))
            self.assertEqual(caught.exception.status, 400, value)

    def test_body_over_256_kib_is_413_without_reading(self):
        class Stdin(object):
            def read(self, *args):
                raise AssertionError("must not read a too large body")
        env = environ("POST", "__path=/v2/x", CONTENT_LENGTH=str(256 * 1024 + 1))
        with self.assertRaises(RelayError) as caught:
            cgiio.read_request(env, Stdin())
        self.assertEqual(caught.exception.status, 413)

    def test_body_of_exactly_the_limit_is_read(self):
        body = b"x" * (256 * 1024)
        env = environ("POST", "__path=/v2/x", CONTENT_LENGTH=str(len(body)))
        self.assertEqual(len(cgiio.read_request(env, io.BytesIO(body)).body), 256 * 1024)

    def test_truncated_body_is_400(self):
        env = environ("POST", "__path=/v2/x", CONTENT_LENGTH="10")
        with self.assertRaises(RelayError) as caught:
            cgiio.read_request(env, io.BytesIO(b"short"))
        self.assertEqual(caught.exception.status, 400)

    def test_text_stdin_uses_its_buffer(self):
        stdin = io.TextIOWrapper(io.BytesIO(b'{"a":1}'), encoding="utf-8")
        env = environ("POST", "__path=/v2/x", CONTENT_LENGTH="7")
        self.assertEqual(cgiio.read_request(env, stdin).body, b'{"a":1}')


class RequestJsonTests(unittest.TestCase):
    def test_json_object_is_returned(self):
        request = cgiio.Request("POST", "/v2/x", [], {}, b'{"id":"1","on":true}')
        self.assertEqual(request.json(), {"id": "1", "on": True})

    def test_non_object_or_invalid_json_is_400(self):
        for body in (b"[1]", b'"text"', b"nope", b"", b"\xff\xfe", b"null"):
            request = cgiio.Request("POST", "/v2/x", [], {}, body)
            with self.assertRaises(RelayError) as caught:
                request.json()
            self.assertEqual(caught.exception.status, 400, body)


class SendTests(unittest.TestCase):
    def test_header_lines_are_exact(self):
        stdout = ts.FakeStdout()
        cgiio.send(200, {"status": "ok"}, {}, stdout)
        self.assertTrue(stdout.header_text().startswith("Status: 200 OK\r\n"))
        status, headers, body = ts.split_response(stdout)
        self.assertEqual(status, 200)
        self.assertEqual(headers, {
            "content-type": "application/json; charset=utf-8",
            "cache-control": "no-store",
            "x-content-type-options": "nosniff",
            "vary": "Accept-Encoding",
            "content-length": str(len(body)),
        })
        self.assertEqual(body, b'{"status":"ok"}')
        self.assertTrue(stdout.header_text().endswith("\r\n\r\n"))

    def test_status_reason_phrases(self):
        for status, phrase in ((401, "Unauthorized"), (404, "Not Found"), (503, "Service Unavailable")):
            stdout = ts.FakeStdout()
            cgiio.send(status, {}, {}, stdout)
            self.assertTrue(stdout.header_text().startswith("Status: {} {}\r\n".format(status, phrase)))

    def test_unknown_status_gets_generic_reason(self):
        stdout = ts.FakeStdout()
        cgiio.send(599, {}, {}, stdout)
        self.assertTrue(stdout.header_text().startswith("Status: 599 Error\r\n"))

    def test_dict_is_compact_utf8_json_without_ascii_escapes(self):
        stdout = ts.FakeStdout()
        cgiio.send(200, {"text": "ふむ", "n": 1}, {}, stdout)
        self.assertEqual(stdout.body(), '{"text":"ふむ","n":1}'.encode("utf-8"))

    def test_str_and_bytes_are_sent_as_they_are(self):
        stdout = ts.FakeStdout()
        cgiio.send(200, "ふむ", {}, stdout)
        self.assertEqual(stdout.body(), "ふむ".encode("utf-8"))
        stdout = ts.FakeStdout()
        cgiio.send(200, b"\x00raw", {}, stdout, content_type="application/octet-stream")
        status, headers, body = ts.split_response(stdout)
        self.assertEqual(body, b"\x00raw")
        self.assertEqual(headers["content-type"], "application/octet-stream")

    def test_gzip_only_when_accepted_and_large_enough(self):
        big = {"text": "x" * 2000}
        stdout = ts.FakeStdout()
        cgiio.send(200, big, {"HTTP_ACCEPT_ENCODING": "gzip, deflate"}, stdout)
        status, headers, body = ts.split_response(stdout)
        self.assertEqual(headers["content-encoding"], "gzip")
        self.assertEqual(headers["content-length"], str(len(body)))
        self.assertEqual(json.loads(gzip.decompress(body).decode("utf-8")), big)

    def test_no_gzip_when_not_accepted(self):
        stdout = ts.FakeStdout()
        cgiio.send(200, {"text": "x" * 2000}, {"HTTP_ACCEPT_ENCODING": "br"}, stdout)
        _, headers, body = ts.split_response(stdout)
        self.assertNotIn("content-encoding", headers)
        self.assertEqual(len(body), len(json.dumps({"text": "x" * 2000}, separators=(",", ":"))))

    def test_no_gzip_below_1024_bytes(self):
        stdout = ts.FakeStdout()
        payload = {"text": "x" * 1000}  # encodes to about 1,010 bytes
        cgiio.send(200, payload, {"HTTP_ACCEPT_ENCODING": "gzip"}, stdout)
        _, headers, _ = ts.split_response(stdout)
        self.assertNotIn("content-encoding", headers)
        self.assertEqual(headers["vary"], "Accept-Encoding")

    def test_gzip_threshold_is_1024_bytes_of_the_body(self):
        stdout = ts.FakeStdout()
        cgiio.send(200, "a" * 1024, {"HTTP_ACCEPT_ENCODING": "GZIP"}, stdout)
        _, headers, _ = ts.split_response(stdout)
        self.assertEqual(headers["content-encoding"], "gzip")

    def test_body_goes_to_buffer_after_headers_are_flushed(self):
        order = []

        class Recording(ts.FakeStdout):
            def flush(self):
                order.append(("flush", len(self.text)))

        class Buffer(io.BytesIO):
            def write(self, data):
                order.append(("buffer", len(data)))
                return super(Buffer, self).write(data)

        stdout = Recording()
        stdout.buffer = Buffer()
        cgiio.send(200, {"a": 1}, {}, stdout)
        self.assertEqual(order[0][0], "flush")
        self.assertEqual(order[1][0], "buffer")


if __name__ == "__main__":
    unittest.main()
