#!/usr/bin/env python3
"""Keep a local rclone gui process running independently of its menu bar UI."""

import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time
from urllib.parse import parse_qs, urlsplit


def state_directory():
    override = os.environ.get("RCLONE_MENUBAR_STATE_DIR")
    return Path(override) if override else Path.home() / "Library/Application Support/Rclone Menu Bar"


def rclone_binary():
    override = os.environ.get("RCLONE_BINARY")
    if override:
        candidate = Path(override).expanduser()
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate.resolve())
        raise RuntimeError("RCLONE_BINARY must name an executable rclone file")
    search = os.pathsep.join([os.environ.get("PATH", ""), "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"])
    binary = shutil.which("rclone", path=search)
    if not binary:
        raise RuntimeError("Install rclone 1.74 or later, or set RCLONE_BINARY")
    return binary


def local_url(raw):
    url = urlsplit(raw)
    if url.scheme != "http" or url.hostname != "127.0.0.1" or not url.port or url.username or url.password:
        raise ValueError("Expected an authenticated rclone GUI on IPv4 loopback")
    return url


def runtime_from_line(line, pid):
    match = re.search(r"GUI available at (http://\S+)", line)
    if not match:
        return None
    login_url = match.group(1)
    url = local_url(login_url)
    query = parse_qs(url.query)
    api_url = query["url"][0]
    local_url(api_url)
    return {
        "wrapper_pid": os.getpid(), "rclone_pid": pid,
        "started_at": time.time(), "login_url": login_url,
        "gui_url": f"{url.scheme}://{url.netloc}/",
        "api_url": api_url, "user": query["user"][0], "password": query["pass"][0],
    }


def public_log_line(line):
    if "Using random password:" in line or "GUI available at " in line:
        return "Generated private local GUI credentials.\n"
    return line


def run(state):
    runtime = state / "runtime.json"
    runtime.unlink(missing_ok=True)
    command = [
        rclone_binary(), "gui", "--no-open-browser", "--no-auth=false",
        "--addr", "127.0.0.1:0", "--api-addr", "127.0.0.1:0", "--log-level", "INFO",
    ]
    process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True, bufsize=1, start_new_session=True)

    def stop(signum, _frame):
        if process.poll() is None:
            process.send_signal(signum)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    log = state / "rclone.log"
    if log.exists() and log.stat().st_size > 20 * 1024 * 1024:
        log.replace(state / "rclone.previous.log")
    try:
        with log.open("a", buffering=1) as output:
            log.chmod(0o600)
            for line in process.stdout:
                snapshot = runtime_from_line(line, process.pid)
                if snapshot:
                    temporary = state / "runtime.json.new"
                    temporary.write_text(json.dumps(snapshot))
                    temporary.chmod(0o600)
                    temporary.replace(runtime)
                    output.write("Rclone GUI is ready on loopback (authentication enabled).\n")
                else:
                    output.write(public_log_line(line))
        return process.wait()
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait()
        runtime.unlink(missing_ok=True)


def main():
    os.umask(0o077)
    state = state_directory()
    state.mkdir(parents=True, exist_ok=True, mode=0o700)
    state.chmod(0o700)
    with (state / "service.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return 0
        return run(state)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, RuntimeError) as error:
        # Parsing failures must not print a login URL or its query parameters.
        print("Rclone Menu Bar service could not start. Check rclone and the local log.", file=sys.stderr)
        sys.exit(1)
