"""A Debug executable must exit before starting normal background services."""

import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import tempfile


def check_debug_launch(source):
    with tempfile.TemporaryDirectory(prefix="oilfind-debug-check-") as temporary:
        root = Path(temporary).resolve()
        if source.is_dir():
            app = root / "Oil Find.app"
            subprocess.run(["/usr/bin/ditto", str(source), str(app)], check=True)
            with (app / "Contents/Info.plist").open("rb") as file:
                info = plistlib.load(file)
            assert info["CFBundleIdentifier"] == "com.oiloil.find.debug", "Debug must use its own identity"
            assert "CFBundleURLTypes" not in info, "Debug must not claim production URL schemes"
            executable = app / "Contents/MacOS/OilFind"
        else:
            executable = root / "OilFind"
            shutil.copy2(source, executable)
            for resource in source.parent.glob("OilFind_*.bundle"):
                if not resource.is_symlink() and resource.is_dir():
                    shutil.copytree(resource, root / resource.name, symlinks=True)
        home = root / "home"
        home.mkdir()
        profile = root / "check.sb"
        # Both modes deny personal data, mounted drives and FSEvents. Normal
        # launches also deny enumeration before testing the fail-closed entry.
        base = ('(version 1)\n(allow default)\n'
                '(deny file-read* (subpath "/Volumes"))\n'
                f'(deny file-read* (subpath {json.dumps(str(Path.home()))}))\n'
                f'(deny file-write* (subpath {json.dumps(str(Path.home()))}))\n'
                '(deny network*)\n'
                '(deny mach-lookup (global-name "com.apple.FSEvents"))\n'
                '(deny mach-lookup (global-name "com.apple.securityd"))\n')
        def run(arguments, render=False):
            # libignition opens "/" before main. Block enumeration syscalls
            # instead: getdirentries, getdirentries64 and getattrlistbulk.
            profile.write_text(base + ('' if render else '(deny syscall-unix (syscall-number 196 344 461))\n'))
            command = ["/usr/bin/sandbox-exec", "-f", str(profile), str(executable), *arguments]
            process = subprocess.Popen(command, env={**os.environ, "CFFIXED_USER_HOME": str(home)},
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
            try:
                output, error = process.communicate(timeout=10)
                return process.returncode, output, error
            finally:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()

        for arguments in [[], ["-didFinishOnboarding", "YES", "-automaticUpdates", "YES"]]:
            code, _, error = run(arguments)
            assert code == 2 and b"background indexing is disabled" in error, (code, error[-2000:])
        output = root / "snapshot.png"
        code, _, error = run(["--snapshot", str(output)], render=True)
        assert code == 1 and b"requires --db" in error, (code, error[-2000:])
        code, _, error = run(["--snapshot", str(output), "--state", "welcome"], render=True)
        assert code == 0, (code, error[-2000:])
        assert output.read_bytes().startswith(b"\x89PNG\r\n\x1a\n"), "Snapshot did not render"
        print("Debug launch isolation passed: normal launches refused, explicit fixture required, snapshot rendered and exited.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app_or_executable", type=Path)
    args = parser.parse_args()
    check_debug_launch(args.app_or_executable.resolve(strict=True))
