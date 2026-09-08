import base64
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


class RuntimeTests(unittest.TestCase):
    def test_real_rclone_copy_and_single_service(self):
        with tempfile.TemporaryDirectory(prefix="rclone-menubar-runtime-") as folder:
            root = Path(folder)
            config = root / "empty.conf"
            config.write_text("")
            state = root / "state"
            environment = {key: value for key, value in os.environ.items() if not key.startswith("RCLONE_")}
            environment.update(RCLONE_CONFIG=str(config), RCLONE_MENUBAR_STATE_DIR=str(state))
            process = subprocess.Popen([sys.executable, str(ROOT / "service.py")], env=environment,
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                deadline = time.monotonic() + 15
                while not (state / "runtime.json").exists():
                    self.assertIsNone(process.poll(), "Is rclone 1.74 or later installed?")
                    self.assertLess(time.monotonic(), deadline, "Service startup timed out")
                    time.sleep(0.1)
                runtime = json.loads((state / "runtime.json").read_text())
                opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
                authorization = "Basic " + base64.b64encode(f"{runtime['user']}:{runtime['password']}".encode()).decode()

                def rc(endpoint, body=None, authenticated=True):
                    headers = {"Content-Type": "application/json"}
                    if authenticated:
                        headers["Authorization"] = authorization
                    request = urllib.request.Request(runtime["api_url"] + endpoint,
                                                     data=json.dumps(body or {}).encode(), headers=headers)
                    with opener.open(request, timeout=10) as response:
                        return json.load(response)

                with self.assertRaises(urllib.error.HTTPError) as denied:
                    rc("core/pid", authenticated=False)
                self.assertEqual(denied.exception.code, 401)
                denied.exception.close()
                self.assertEqual(rc("core/pid")["pid"], runtime["rclone_pid"])
                self.assertEqual(stat.S_IMODE(state.stat().st_mode), 0o700)
                self.assertEqual(stat.S_IMODE((state / "runtime.json").stat().st_mode), 0o600)
                self.assertEqual(rc("config/listremotes")["remotes"], [])

                duplicate = subprocess.run([sys.executable, str(ROOT / "service.py")], env=environment, timeout=5)
                self.assertEqual(duplicate.returncode, 0)
                self.assertEqual(json.loads((state / "runtime.json").read_text())["rclone_pid"], runtime["rclone_pid"])

                source = root / "source"
                source.mkdir()
                payload = bytes(range(256)) * 65536
                (source / "example.bin").write_bytes(payload)
                rc("core/bwlimit", {"rate": "2Mi"})
                job = rc("sync/copy", {"srcFs": str(source), "dstFs": ":memory:menu-bar-test",
                                       "_async": True, "_config": {"Transfers": 1}})
                samples = []
                deadline = time.monotonic() + 30
                while True:
                    status = rc("job/status", {"jobid": job["jobid"]})
                    stats = rc("core/stats", {"group": f"job/{job['jobid']}"})
                    samples.append(stats["bytes"])
                    if status["finished"]:
                        self.assertTrue(status["success"], status["error"])
                        break
                    self.assertLess(time.monotonic(), deadline, "Disposable copy timed out")
                    time.sleep(0.3)
                self.assertTrue(any(0 < count < len(payload) for count in samples), "No live progress observed")
                obj = rc("operations/stat", {"fs": ":memory:menu-bar-test", "remote": "example.bin",
                                              "opt": {"showHash": True}})["item"]
                self.assertEqual(obj["Size"], len(payload))
                self.assertEqual(obj["Hashes"]["md5"], hashlib.md5(payload).hexdigest())
                log = (state / "rclone.log").read_text()
                self.assertNotIn(runtime["password"], log)
                self.assertNotIn(runtime["login_url"], log)
                rc("core/quit")
                self.assertEqual(process.wait(timeout=10), 0)
                self.assertFalse((state / "runtime.json").exists())
            finally:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=10)


if __name__ == "__main__":
    unittest.main()
