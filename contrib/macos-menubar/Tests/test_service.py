import importlib.util
import os
from pathlib import Path
import unittest
from unittest.mock import patch
from urllib.parse import urlencode

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("menubar_service", ROOT / "service.py")
service = importlib.util.module_from_spec(spec)
spec.loader.exec_module(service)


class ServiceTests(unittest.TestCase):
    def login_line(self, api="http://127.0.0.1:12346/", gui="127.0.0.1:12345"):
        query = urlencode({"url": api, "user": "example", "pass": "dummy value + / ?"})
        return f"NOTICE: GUI available at http://{gui}/login?{query}\n"

    def test_credentials_round_trip_without_entering_log(self):
        line = self.login_line()
        state = service.runtime_from_line(line, 123)
        self.assertEqual(state["password"], "dummy value + / ?")
        self.assertEqual(state["api_url"], "http://127.0.0.1:12346/")
        self.assertNotIn(state["login_url"], service.public_log_line(line))
        self.assertNotIn("dummy", service.public_log_line("Using random password: dummy\n"))

    def test_non_loopback_urls_are_rejected(self):
        for api in ["http://example.invalid:1234/", "http://127.0.0.1/", "https://127.0.0.1:1234/"]:
            with self.subTest(api=api), self.assertRaises(ValueError):
                service.runtime_from_line(self.login_line(api=api), 123)
        with self.assertRaises(ValueError):
            service.runtime_from_line(self.login_line(gui="example.invalid:12345"), 123)

    def test_unrelated_logs_are_preserved(self):
        line = "ERROR: test file: upload failed\n"
        self.assertIsNone(service.runtime_from_line(line, 123))
        self.assertEqual(service.public_log_line(line), line)

    def test_invalid_explicit_binary_does_not_fall_back(self):
        with patch.dict(os.environ, {"RCLONE_BINARY": "/nonexistent/rclone-test-binary"}):
            with self.assertRaises(RuntimeError):
                service.rclone_binary()


if __name__ == "__main__":
    unittest.main()
