#!/usr/bin/env python3
"""Build an ad-hoc-signed native app without installing or starting it."""

import argparse
import hashlib
import json
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", choices=["arm64", "x86_64"], default=platform.machine())
    args = parser.parse_args()
    build = ROOT / "build" / args.arch
    bundle = build / "Rclone Menu Bar.app"
    sources = sorted((ROOT / "Sources").glob("*.swift"))
    inputs = sources + [ROOT / "service.py", Path(__file__).resolve()]
    hashes = {str(path.relative_to(ROOT)): digest(path) for path in inputs}
    executable = bundle / "Contents/MacOS/Rclone Menu Bar"
    resources = bundle / "Contents/Resources"
    executable.parent.mkdir(parents=True, exist_ok=True)
    resources.mkdir(parents=True, exist_ok=True)
    command = ["xcrun", "swiftc", "-parse-as-library", "-O",
               "-target", f"{args.arch}-apple-macosx13.0", *map(str, sources),
               "-o", str(executable), "-framework", "AppKit", "-framework", "SwiftUI"]
    subprocess.run(command, check=True)
    shutil.copyfile(ROOT / "service.py", resources / "service.py")
    (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "org.rclone.menubar",
        "CFBundleName": "Rclone Menu Bar", "CFBundleDisplayName": "Rclone Menu Bar",
        "CFBundleExecutable": "Rclone Menu Bar", "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1",
        "LSMinimumSystemVersion": "13.0", "LSUIElement": True,
        "NSHighResolutionCapable": True,
    }))
    subprocess.run(["codesign", "--force", "--sign", "-", str(bundle)], check=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(bundle)], check=True)
    if hashes != {str(path.relative_to(ROOT)): digest(path) for path in inputs}:
        raise RuntimeError("Sources changed during the build")
    (build / "build-receipt.json").write_text(json.dumps({
        "source_sha256": hashes,
        "bundle_sha256": {str(path.relative_to(bundle)): digest(path)
                          for path in bundle.rglob("*") if path.is_file()},
        "command": command, "signing": "ad-hoc",
    }, indent=2))
    print(bundle)


if __name__ == "__main__":
    main()
