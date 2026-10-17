"""Launch a packaged app without access to developer resources or user data."""

import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import time


def check_launch(package):
    if subprocess.run(["/usr/bin/pgrep", "-x", "OilFind"], capture_output=True).returncode == 0:
        raise RuntimeError("Quit the running Oil Find before checking the packaged launch.")
    with tempfile.TemporaryDirectory(prefix="oilfind-launch-") as temporary:
        root = Path(temporary).resolve()
        if package.is_dir():
            app = root / "Oil Find.app"
            subprocess.run(["/usr/bin/ditto", str(package), str(app)], check=True)
        else:
            subprocess.run(["/usr/bin/ditto", "-x", "-k", str(package), str(root)], check=True)
            app = root / "Oil Find.app"
        subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
        with (app / "Contents/Info.plist").open("rb") as source:
            info = plistlib.load(source)
        workspace = root / ".oilfind-update-launch-check"
        workspace.mkdir()
        (workspace / "receipt.json").write_text(json.dumps({
            "target": str(app), "version": info["CFBundleShortVersionString"],
            "build": int(info["CFBundleVersion"]), "previousVersion": "0.0.0", "previousBuild": 0,
        }))
        home = root / "home"
        home.mkdir()
        # Deny every SwiftPM build directory, not just this checkout's current path.
        # The real home is inaccessible; Foundation preferences and index data use the temporary home.
        profile = root / "launch.sb"
        real_home = json.dumps(str(Path.home()))
        profile.write_text('(version 1)\n(allow default)\n'
                           '(deny file-read* (regex #"/[.]build(/|$)"))\n'
                           f'(deny file-read* (subpath {real_home}))\n'
                           f'(deny file-write* (subpath {real_home}))\n'
                           '(deny mach-lookup (global-name "com.apple.securityd"))\n'
                           '(deny network*)\n')
        command = ["/usr/bin/sandbox-exec", "-f", str(profile), str(app / "Contents/MacOS/OilFind"),
                   "-aiTopicsEnabled", "YES", "-aiTopicsProvider.codex.enabled", "YES",
                   "-aiTopicsProvider.claude.enabled", "NO", "-aiTopicsProvider.workbuddy.enabled", "NO",
                   "-didFinishOnboarding", "YES", "-automaticUpdates", "NO",
                   "-legacyAuthorizationCleanupCompleted", "YES"]
        with (root / "launch.log").open("w+") as log:
            process = subprocess.Popen(command, env={**os.environ, "CFFIXED_USER_HOME": str(home)},
                                       stdout=log, stderr=subprocess.STDOUT)
            try:
                deadline = time.monotonic() + 15
                confirmed_at = None
                while process.poll() is None and time.monotonic() < deadline:
                    if (workspace / "launch-confirmed").exists():
                        if confirmed_at is None:
                            confirmed_at = time.monotonic()
                        elif time.monotonic() - confirmed_at >= 2:
                            print(f"Packaged launch passed: {info['CFBundleShortVersionString']} "
                                  f"(build {info['CFBundleVersion']}), isolated resources and launch acknowledgement.")
                            return
                    time.sleep(0.05)
                log.seek(0)
                raise RuntimeError(f"Packaged launch failed (exit={process.poll()}, "
                                   f"acknowledged={confirmed_at is not None}):\n{log.read()[-6000:]}")
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("Usage: python3 Tests/Scripts/test_packaged_launch.py <app-or-zip>")
    try:
        check_launch(Path(sys.argv[1]).resolve(strict=True))
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
