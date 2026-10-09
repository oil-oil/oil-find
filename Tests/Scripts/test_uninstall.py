import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class UninstallTests(unittest.TestCase):
    def run_uninstall(self, arguments=(), initial=None, answer="y\n"):
        with tempfile.TemporaryDirectory(prefix="oilfind-uninstall-test-") as directory:
            root = Path(directory)
            state = root / "defaults.json"
            log = root / "calls.jsonl"
            state.write_text(json.dumps(initial if initial is not None else {
                "trialStartedAt": 1790000000.5, "trialLastSeenAt": 1790003600.75,
                "licenseAPI": "http://example.com", "deviceFallbackID": "legacy", "pinyinEnabled": True,
            }))
            stub = root / "stub"
            stub.write_text("""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['OILFIND_TEST_LOG'], 'a') as log:
    log.write(json.dumps([name, *args]) + '\\n')
if name == 'pgrep': sys.exit(1)
if name != 'defaults': sys.exit(0)
path = Path(os.environ['OILFIND_TEST_DEFAULTS'])
values = json.loads(path.read_text())
if args[0] == 'read':
    if len(args) == 2:
        if not values: sys.exit(1)
        print(json.dumps(values))
    else:
        if args[2] not in values: sys.exit(1)
        print(values[args[2]])
elif args[0] == 'delete':
    path.write_text('{}')
elif args[0] == 'write':
    values[args[2]] = float(args[4])
    path.write_text(json.dumps(values))
""")
            stub.chmod(0o755)
            for name in ("defaults", "pgrep", "rm", "security", "osascript"):
                (root / name).symlink_to(stub)
            env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ["PATH"],
                       OILFIND_TEST_LOG=str(log), OILFIND_TEST_DEFAULTS=str(state))
            script = Path(__file__).resolve().parents[2] / "scripts/uninstall.sh"
            result = subprocess.run(["/bin/bash", str(script), *arguments], input=answer,
                                    capture_output=True, text=True, env=env)
            calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
            return result, json.loads(state.read_text()), calls

    def test_default_deletes_all_settings_and_legacy_keychain_item(self):
        result, values, calls = self.run_uninstall()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(values, {})
        self.assertIn(["security", "delete-generic-password", "-s", "com.oiloil.find.trial"], calls)
        self.assertIn(["security", "delete-generic-password", "-s", "com.oiloil.find.clipboard-history", "-a", "aes-gcm-v1"], calls)
        self.assertEqual(sum(call[0] == "rm" for call in calls), 1)

    def test_decline_and_invalid_arguments_do_not_mutate_anything(self):
        for arguments, answer, status in [((), "n\n", 0), (("--invalid",), "y\n", 2), (("--purge",), "y\n", 2)]:
            result, values, calls = self.run_uninstall(arguments, {"trialStartedAt": 1, "pinyinEnabled": True}, answer)
            self.assertEqual(result.returncode, status)
            self.assertEqual(values, {"trialStartedAt": 1, "pinyinEnabled": True})
            self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
