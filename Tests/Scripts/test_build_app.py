import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[2]


class BuildAppTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="oilfind-build-test-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / "scripts").mkdir()
        (self.root / "Resources").mkdir()
        (self.root / "bin").mkdir()
        for name in ("build-app.sh", "verify-release-app.sh"):
            shutil.copy2(PROJECT / "scripts" / name, self.root / "scripts" / name)
        shutil.copy2(PROJECT / "Resources/Info.plist", self.root / "Resources/Info.plist")
        (self.root / "Resources/AppIcon.icns").write_bytes(b"test icon")
        self.binary = self.root / "binary/OilFind"
        self.binary.parent.mkdir()
        self.binary.write_text("new executable")
        self.binary.chmod(0o755)
        self.log = self.root / "calls.jsonl"
        self.environment = dict(os.environ)
        self.environment.pop("OILFIND_SIGN_IDENTITY", None)
        self.environment.update(
            PATH=str(self.root / "bin") + os.pathsep + os.environ["PATH"],
            OILFIND_TEST_ROOT=str(self.root),
            OILFIND_TEST_LOG=str(self.log),
        )
        stub = self.root / "bin/stub"
        stub.write_text(f"#!{sys.executable}\n" + r'''
import json, os, shutil, signal, sys
from pathlib import Path
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["OILFIND_TEST_LOG"], "a") as log:
    log.write(json.dumps([name, *args]) + "\n")
failure = os.environ.get("OILFIND_TEST_FAIL", "")
root = Path(os.environ["OILFIND_TEST_ROOT"])
if name == "swift":
    if failure == "build": sys.exit(1)
    if "--show-bin-path" in args: print(root / "binary")
elif name == "strip":
    if failure == "strip": sys.exit(1)
elif name == "security":
    if os.environ.get("OILFIND_TEST_SELF_SIGNED"): print('1) ABC "Oil Find Self-Signed"')
elif name == "codesign":
    if "--force" in args and failure == "sign": sys.exit(1)
    if "--verify" in args and failure == "verify": sys.exit(1)
    if "-d" in args: print("Identifier=" + os.environ.get("OILFIND_TEST_IDENTIFIER", "com.oiloil.find"))
elif name == "mv":
    if Path(args[0]).name == "Oil Find.app" and Path(args[1]).name != "previous.app" and failure == "promote":
        sys.exit(1)
    shutil.move(args[0], args[1])
    if Path(args[1]).name == "previous.app" and failure == "interrupt":
        os.kill(os.getppid(), signal.SIGTERM)
elif name == "xcrun":
    print(os.environ.get("OILFIND_TEST_BUILD_INFO", "platform MACOS\nminos 14.0\nsdk 15.5"))
''')
        stub.chmod(0o755)
        for name in ("swift", "strip", "security", "codesign", "mv", "xcrun"):
            (self.root / "bin" / name).symlink_to(stub)

    def app_path(self, debug=False):
        return self.root / ("build/debug/Oil Find.app" if debug else "build/Oil Find.app")

    def seed_old_app(self, debug=False):
        app = self.app_path(debug)
        app.mkdir(parents=True)
        (app / "stale-resource").write_text("old artifact")
        return app

    def run_script(self, name="build-app.sh", arguments=(), **environment):
        return subprocess.run(
            ["/bin/bash", str(self.root / "scripts" / name), *map(str, arguments)],
            capture_output=True, text=True, env=dict(self.environment, **environment),
        )

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def assert_no_stage(self):
        self.assertEqual(sorted((self.root / "build").glob("**/.oilfind-stage.*")), [])

    def test_release_replaces_old_bundle_without_stale_resources(self):
        app = self.seed_old_app()
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(app))
        self.assertFalse((app / "stale-resource").exists())
        self.assertEqual((app / "Contents/MacOS/OilFind").read_text(), "new executable")
        calls = self.calls()
        self.assertIn(["swift", "build", "-c", "release"], calls)
        self.assertTrue(any(call[:2] == ["strip", "-S"] for call in calls))
        sign = next(call for call in calls if call[:2] == ["codesign", "--force"])
        self.assertEqual(sign[sign.index("--sign") + 1], "-")
        verify_index = next(i for i, call in enumerate(calls) if call[:2] == ["codesign", "--verify"])
        move_index = next(i for i, call in enumerate(calls) if call[0] == "mv")
        self.assertLess(verify_index, move_index)
        self.assert_no_stage()

    def test_debug_bundle_is_separate_and_not_stripped(self):
        release = self.seed_old_app()
        debug = self.seed_old_app(debug=True)
        result = self.run_script(arguments=("--debug",))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((release / "stale-resource").exists())
        self.assertFalse((debug / "stale-resource").exists())
        self.assertIn(["swift", "build", "-c", "debug"], self.calls())
        self.assertFalse(any(call[0] == "strip" for call in self.calls()))
        self.assert_no_stage()

    def test_signing_identity_selection_is_preserved(self):
        for environment, identity, hardened in (
            ({"OILFIND_SIGN_IDENTITY": "Developer ID Application: Example"}, "Developer ID Application: Example", True),
            ({"OILFIND_TEST_SELF_SIGNED": "1"}, "Oil Find Self-Signed", False),
        ):
            with self.subTest(identity=identity):
                self.log.unlink(missing_ok=True)
                result = self.run_script(**environment)
                self.assertEqual(result.returncode, 0, result.stderr)
                sign = next(call for call in self.calls() if call[:2] == ["codesign", "--force"])
                self.assertEqual(sign[sign.index("--sign") + 1], identity)
                self.assertEqual(sign[sign.index("--identifier") + 1], "com.oiloil.find")
                self.assertEqual("--timestamp" in sign, hardened)
                self.assertEqual("--options" in sign, hardened)
                self.assert_no_stage()

    def test_failures_preserve_previous_artifact_and_clean_stage(self):
        app = self.seed_old_app()
        for failure in ("build", "strip", "sign", "verify", "promote", "interrupt"):
            with self.subTest(failure=failure):
                result = self.run_script(OILFIND_TEST_FAIL=failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((app / "stale-resource").read_text(), "old artifact")
                self.assertFalse((app / "Contents").exists())
                self.assert_no_stage()

    def test_first_build_promotion_failure_leaves_no_artifact(self):
        result = self.run_script(OILFIND_TEST_FAIL="promote")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.app_path().exists())
        self.assert_no_stage()

    def test_removed_icon_is_not_carried_over(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        (self.root / "Resources/AppIcon.icns").unlink()
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.app_path() / "Contents/Resources/AppIcon.icns").exists())

    def test_invalid_arguments_do_not_build(self):
        for arguments in (("--invalid",), ("--debug", "extra"), ("",)):
            with self.subTest(arguments=arguments):
                result = self.run_script(arguments=arguments)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(self.calls(), [])

    def test_release_verification_accepts_valid_metadata_and_signature(self):
        self.assertEqual(self.run_script().returncode, 0)
        result = self.run_script("verify-release-app.sh", (self.app_path(),))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Verified release app:", result.stdout)

    def test_release_verification_rejects_bad_sdk_target_and_signature(self):
        self.assertEqual(self.run_script().returncode, 0)
        for environment in (
            {"OILFIND_TEST_BUILD_INFO": "platform MACOS\nminos 14.0\nsdk 15.3"},
            {"OILFIND_TEST_BUILD_INFO": "platform MACOS\nminos 15.0\nsdk 15.5"},
            {"OILFIND_TEST_BUILD_INFO": "platform IOS\nminos 14.0\nsdk 15.5"},
            {"OILFIND_TEST_BUILD_INFO": ""},
            {"OILFIND_TEST_IDENTIFIER": "wrong.bundle"},
            {"OILFIND_TEST_FAIL": "verify"},
        ):
            with self.subTest(environment=environment):
                result = self.run_script("verify-release-app.sh", (self.app_path(),), **environment)
                self.assertNotEqual(result.returncode, 0)

    def test_release_verification_requires_executable_and_icon(self):
        self.assertEqual(self.run_script().returncode, 0)
        binary = self.app_path() / "Contents/MacOS/OilFind"
        binary.chmod(0o644)
        self.assertNotEqual(self.run_script("verify-release-app.sh", (self.app_path(),)).returncode, 0)
        binary.chmod(0o755)
        (self.app_path() / "Contents/Resources/AppIcon.icns").unlink()
        self.assertNotEqual(self.run_script("verify-release-app.sh", (self.app_path(),)).returncode, 0)

    def test_release_verification_rejects_wrong_plist_metadata(self):
        for key, value in (("CFBundleIdentifier", "wrong.bundle"), ("CFBundleExecutable", "Wrong"),
                           ("LSMinimumSystemVersion", "15.0")):
            with self.subTest(key=key):
                self.assertEqual(self.run_script().returncode, 0)
                subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :{key} {value}",
                                str(self.app_path() / "Contents/Info.plist")], check=True)
                self.assertNotEqual(self.run_script("verify-release-app.sh", (self.app_path(),)).returncode, 0)

    def test_real_macho_signing_and_archive_roundtrip(self):
        source = self.root / "main.c"
        source.write_text("int main(void) { return 0; }\n")
        subprocess.run(["/usr/bin/xcrun", "clang", "-mmacosx-version-min=14.0",
                        str(source), "-o", str(self.binary)], check=True, capture_output=True)
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", "--identifier", "com.oiloil.find",
                        str(self.app_path())], check=True, capture_output=True)
        archive = self.root / "release.zip"
        extracted = self.root / "extracted"
        subprocess.run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent",
                        str(self.app_path()), str(archive)], check=True)
        subprocess.run(["/usr/bin/ditto", "-x", "-k", str(archive), str(extracted)], check=True)
        for app in (self.app_path(), extracted / "Oil Find.app"):
            result = subprocess.run(["/bin/bash", str(self.root / "scripts/verify-release-app.sh"), str(app)],
                                    capture_output=True, text=True, env=os.environ)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        (extracted / "Oil Find.app/Contents/MacOS/OilFind").write_bytes(b"tampered executable")
        result = subprocess.run(["/bin/bash", str(self.root / "scripts/verify-release-app.sh"),
                                 str(extracted / "Oil Find.app")], capture_output=True, text=True, env=os.environ)
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
