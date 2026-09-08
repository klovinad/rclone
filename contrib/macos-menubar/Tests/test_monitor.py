import base64
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]


class MonitorTests(unittest.TestCase):
    def test_rc_lifecycle(self):
        with tempfile.TemporaryDirectory(prefix="rclone-menubar-monitor-") as folder:
            root = Path(folder)
            scenario = root / "scenario.json"
            scenario.write_text("{}")
            auth = "Basic " + base64.b64encode(b"test:dummy").decode()

            class Handler(BaseHTTPRequestHandler):
                def log_message(self, *_args):
                    pass

                def do_POST(self):
                    data = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))) or b"{}")
                    current = json.loads(scenario.read_text())
                    status = 200
                    if self.headers.get("Authorization") != auth:
                        status, value = 401, {}
                    elif current.get("offline"):
                        status, value = 503, {}
                    elif self.path == "/core/pid":
                        value = {"pid": current.get("pid", 12345)}
                    elif self.path == "/job/list":
                        value = {"runningIds": current.get("running", [])}
                    elif self.path == "/core/group-list":
                        value = {"groups": ["global", "job/17"]}
                    elif self.path == "/core/stats" and data.get("group") == "job/17":
                        value = current.get("stats", {})
                    elif self.path == "/job/status" and "finished" in current:
                        value = {"finished": current["finished"], "success": current["success"]}
                    else:
                        status, value = 404, {}
                    body = json.dumps(value).encode()
                    self.send_response(status)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)

            server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            try:
                (root / "runtime.json").write_text(json.dumps({
                    "wrapper_pid": os.getpid(), "rclone_pid": 12345,
                    "api_url": f"http://127.0.0.1:{server.server_port}/",
                    "login_url": f"http://127.0.0.1:{server.server_port}/", "user": "test", "password": "dummy",
                }))
                binary = root / "MonitorTests"
                subprocess.run(["xcrun", "swiftc", "-parse-as-library",
                                str(ROOT / "Sources/TransferStatus.swift"), str(ROOT / "Tests/MonitorTests.swift"),
                                "-o", str(binary), "-framework", "AppKit", "-framework", "SwiftUI"], check=True)
                environment = dict(os.environ, RCLONE_MENUBAR_STATE_DIR=str(root), MENUBAR_TEST_SCENARIO=str(scenario))
                result = subprocess.run([str(binary)], env=environment, text=True, capture_output=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                print(result.stdout.strip())
            finally:
                server.shutdown()
                server.server_close()


if __name__ == "__main__":
    unittest.main()
