"""Release safeguards, exercised without signing keys or network access."""

import contextlib
import copy
import datetime
import io
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import textwrap
import unittest
from unittest.mock import patch

CI_DIR = Path(__file__).resolve().parents[1]
ROOT = CI_DIR.parents[1]
sys.path.insert(0, str(CI_DIR))

from check_profile import APP_GROUP, BUNDLE_IDS, check_profile, keychain_group, load_plist
from check_signed_bundle import check_signed_bundle

TEAM = "TESTTEAM01"
UUID = "12345678-1234-1234-1234-123456789ABC"


def profile(role="app"):
    return {
        "UUID": UUID,
        "TeamIdentifier": [TEAM],
        "ExpirationDate": datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
        + datetime.timedelta(days=1),
        "Entitlements": {
            "com.apple.application-identifier": f"{TEAM}.{BUNDLE_IDS[role]}",
            "com.apple.security.application-groups": [APP_GROUP],
            "keychain-access-groups": [keychain_group(TEAM)],
        },
    }


class ProfileTests(unittest.TestCase):
    def test_both_roles_accept_concrete_and_wildcard_authorizations(self):
        for role in BUNDLE_IDS:
            for pattern in (None, "*", f"{TEAM}.*"):
                with self.subTest(role=role, pattern=pattern):
                    value = profile(role)
                    if pattern:
                        value["Entitlements"]["keychain-access-groups"] = [pattern]
                        value["Entitlements"]["com.apple.security.application-groups"] = ["group.*"]
                    self.assertEqual(check_profile(value, role, TEAM), UUID)

    def test_invalid_profiles_fail_closed(self):
        changes = [
            ("UUID", "../../escape"),
            ("TeamIdentifier", ["OTHERTEAM"]),
            ("ExpirationDate", datetime.datetime(2000, 1, 1)),
            ("ExpirationDate", "tomorrow"),
            ("Entitlements", None),
        ]
        for key, value in changes:
            with self.subTest(key=key, value=value), contextlib.redirect_stderr(io.StringIO()):
                invalid = profile()
                invalid[key] = value
                with self.assertRaises(SystemExit):
                    check_profile(invalid, "app", TEAM)
        for key, value in [
            ("com.apple.application-identifier", f"{TEAM}.{BUNDLE_IDS['widget']}"),
            ("com.apple.security.application-groups", ["group.other"]),
            ("keychain-access-groups", ["OTHERTEAM.*"]),
            ("keychain-access-groups", keychain_group(TEAM)),
            ("keychain-access-groups", [42]),
        ]:
            with self.subTest(key=key, value=value), contextlib.redirect_stderr(io.StringIO()):
                invalid = profile()
                invalid["Entitlements"][key] = value
                with self.assertRaises(SystemExit):
                    check_profile(invalid, "app", TEAM)

    def test_malformed_and_non_dictionary_plists_fail_closed(self):
        for data in (b"invalid", plistlib.dumps(["not a dictionary"])):
            with self.subTest(data=data), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit):
                    load_plist(data, "app", "profile")


class BundleTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.app = Path(temp.name) / "Holeberry.app"
        self.paths = {
            "app": self.app,
            "widget": self.app / "Contents/PlugIns/HoleberryWidgets.appex",
        }
        self.profiles = {role: profile(role) for role in BUNDLE_IDS}
        self.entitlements = {}
        self.infos = {}
        for role, path in self.paths.items():
            (path / "Contents").mkdir(parents=True)
            (path / "Contents/embedded.provisionprofile").touch()
            self.entitlements[role] = copy.deepcopy(self.profiles[role]["Entitlements"])
            if role == "widget":
                self.entitlements[role].update({
                    "com.apple.security.app-sandbox": True,
                    "com.apple.security.network.client": True,
                })
            self.infos[role] = {
                "CFBundleIdentifier": BUNDLE_IDS[role],
                "HoleberryAppGroupIdentifier": APP_GROUP,
                "HoleberryKeychainAccessGroup": keychain_group(TEAM),
                "CFBundleShortVersionString": "1.2.3",
                "CFBundleVersion": "123",
            }

    def check(self):
        for role, path in self.paths.items():
            (path / "Contents/Info.plist").write_bytes(plistlib.dumps(self.infos[role]))

        def run(command, **kwargs):
            role = "widget" if ".appex" in command[-1] else "app"
            value = self.profiles[role] if command[0] == "security" else self.entitlements[role]
            return subprocess.CompletedProcess(command, 0, stdout=plistlib.dumps(value))

        with patch("check_signed_bundle.subprocess.run", side_effect=run):
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                check_signed_bundle(self.app, TEAM)

    def test_valid_app_and_widget(self):
        self.check()

    def test_signed_entitlements_must_be_concrete_and_safe(self):
        changes = [
            ("app", "keychain-access-groups", [f"{TEAM}.*"]),
            ("app", "keychain-access-groups", keychain_group(TEAM)),
            ("app", "com.apple.security.application-groups", ["group.*"]),
            ("app", "com.apple.application-identifier", "wrong"),
            ("app", "get-task-allow", False),
            ("app", "com.apple.security.get-task-allow", True),
            ("widget", "com.apple.security.app-sandbox", False),
            ("widget", "com.apple.security.network.client", False),
        ]
        original = copy.deepcopy(self.entitlements)
        for role, key, value in changes:
            with self.subTest(role=role, key=key):
                self.entitlements = copy.deepcopy(original)
                self.entitlements[role][key] = value
                with self.assertRaises(SystemExit):
                    self.check()

    def test_bundle_markers_and_versions_must_match(self):
        for key, value in [
            ("CFBundleIdentifier", "wrong"),
            ("HoleberryAppGroupIdentifier", "wrong"),
            ("HoleberryKeychainAccessGroup", "$(AppIdentifierPrefix)shared"),
            ("CFBundleShortVersionString", "2.0"),
            ("CFBundleVersion", "124"),
            ("CFBundleVersion", ""),
        ]:
            with self.subTest(key=key, value=value):
                original = self.infos["widget"][key]
                self.infos["widget"][key] = value
                with self.assertRaises(SystemExit):
                    self.check()
                self.infos["widget"][key] = original

    def test_embedded_profile_is_required_and_revalidated(self):
        self.profiles["widget"]["TeamIdentifier"] = ["OTHERTEAM"]
        with self.assertRaises(SystemExit):
            self.check()
        self.profiles["widget"] = profile("widget")
        (self.paths["widget"] / "Contents/embedded.provisionprofile").unlink()
        with self.assertRaises(SystemExit):
            self.check()


def workflow_step(name):
    workflow = (ROOT / ".github/workflows/release.yml").read_text()
    block = workflow.split(f"      - name: {name}\n", 1)[1]
    block = block.split("\n      - name: ", 1)[0]
    # Comments between steps are outside the run block.
    script = block.split("        run: |\n", 1)[1].split("\n      #", 1)[0]
    return textwrap.dedent(script)


class ShellTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.temp = Path(temp.name).resolve()
        self.calls = self.temp / "calls"
        self.env = dict(os.environ, PATH=f"{self.temp}:{os.environ['PATH']}", CALLS=str(self.calls))

    def stub(self, name, script):
        path = self.temp / name
        path.write_text('#!/bin/bash\nprintf "%s\\n" "$*" >> "$CALLS"\n' + script)
        path.chmod(0o700)

    def run_script(self, script, **env):
        self.calls.write_text("")
        result = subprocess.run(
            ["/bin/bash", "-c", script], env=dict(self.env, **env), cwd=self.temp,
            text=True, capture_output=True,
        )
        return result, self.calls.read_text()

    def test_notarization_requires_accepted_status_and_successful_command(self):
        self.stub("xcrun", '''
if [ "$1 $2" = "notarytool submit" ]; then
  echo 'id: 12345678-1234-1234-1234-123456789abc'
  echo "status: $TEST_VERDICT"
  exit "$TEST_NOTARY_EXIT"
fi
''')
        key = self.temp / "key.p8"
        key.write_text("test key")
        self.env.update(APPLE_API_KEY_ID="key-id", APPLE_API_ISSUER_ID="issuer", APPLE_API_KEY_PATH=str(key))
        script = f'bash "{CI_DIR}/notarize.sh" "{self.temp}/release.dmg"'
        for verdict, code, accepted in [("Accepted", "0", True), ("Invalid", "0", False),
                                         ("In Progress", "0", False), ("Accepted", "1", False)]:
            with self.subTest(verdict=verdict, code=code):
                result, calls = self.run_script(script, TEST_VERDICT=verdict, TEST_NOTARY_EXIT=code)
                self.assertEqual(result.returncode == 0, accepted, result.stdout + result.stderr)
                self.assertEqual("stapler staple" in calls, accepted)
                self.assertEqual("stapler validate" in calls, accepted)
                self.assertEqual("notarytool log" in calls, not accepted)

    def test_app_is_verified_zipped_and_stapled(self):
        self.stub("xcrun", 'if [ "$1 $2" = "notarytool submit" ]; then echo "status: Accepted"; fi\n')
        self.stub("codesign", "exit 0\n")
        self.stub("ditto", "exit 0\n")
        key = self.temp / "key.p8"
        key.write_text("test key")
        app = self.temp / "Holeberry.app"
        script = f'bash "{CI_DIR}/notarize.sh" "{app}"'
        result, calls = self.run_script(script, APPLE_API_KEY_ID="id", APPLE_API_ISSUER_ID="issuer",
                                        APPLE_API_KEY_PATH=str(key), RUNNER_TEMP=str(self.temp))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"--verify --deep --strict --verbose=2 {app}", calls)
        self.assertIn("-c -k --sequesterRsrc --keepParent", calls)
        self.assertIn(f"stapler staple {app}", calls)
        self.assertEqual(list(self.temp.glob("holeberry-app.*")), [])

    def test_missing_notarization_credentials_fail_before_submission(self):
        self.stub("xcrun", "exit 0\n")
        result, calls = self.run_script(f'bash "{CI_DIR}/notarize.sh" release.dmg',
                                        APPLE_API_KEY_ID="", APPLE_API_ISSUER_ID="")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, "")

    def test_release_creation_and_reruns_stay_draft(self):
        self.stub("gh", '''
if [ "$1 $2" = "release view" ]; then
  case "$TEST_RELEASE" in
    missing) exit 1 ;;
    draft) echo true ;;
    published) echo false ;;
  esac
fi
''')
        script = workflow_step("Create or update draft GitHub Release")
        for state in ("missing", "draft", "published"):
            with self.subTest(state=state):
                result, calls = self.run_script(script, TEST_RELEASE=state, GITHUB_REF_NAME="v1.2.3",
                                                DMG_PATH="build/Holeberry-1.2.3.dmg")
                self.assertEqual(result.returncode == 0, state != "published", result.stderr)
                if state == "missing":
                    self.assertIn("--draft --generate-notes --verify-tag", calls)
                elif state == "draft":
                    self.assertIn("release upload v1.2.3 build/Holeberry-1.2.3.dmg --clobber", calls)
                else:
                    self.assertNotIn("release upload", calls)
                    self.assertNotIn("release create", calls)
                self.assertNotIn("release edit", calls)
                self.assertNotIn("--latest", calls)

    def test_identity_check_rejects_empty_or_failed_queries(self):
        self.stub("security", 'echo "$TEST_IDENTITIES valid identities found"\nexit "$TEST_SECURITY_EXIT"\n')
        for count, code, success in [("0", "0", False), ("1", "0", True), ("1", "1", False)]:
            with self.subTest(count=count, code=code):
                result, calls = self.run_script(workflow_step("Verify signing identity"),
                                                TEST_IDENTITIES=count, TEST_SECURITY_EXIT=code)
                self.assertEqual(result.returncode == 0, success)
                self.assertIn("find-identity -v -p codesigning holeberry-signing.keychain", calls)

    def test_packaged_tool_must_be_unique_and_executable(self):
        artifacts = self.temp / "build/SourcePackages/artifacts/sparkle"
        artifacts.mkdir(parents=True)
        output = self.temp / "github-env"
        script = workflow_step("Locate packaged generate_appcast")
        result, _ = self.run_script(script, GITHUB_ENV=str(output))
        self.assertNotEqual(result.returncode, 0)
        tool = artifacts / "generate_appcast"
        tool.write_text("#!/bin/bash\n")
        result, _ = self.run_script(script, GITHUB_ENV=str(output))
        self.assertNotEqual(result.returncode, 0)
        tool.chmod(0o700)
        result, _ = self.run_script(script, GITHUB_ENV=str(output))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output.read_text(), f"GENERATE_APPCAST={tool}\n")
        (artifacts / "another").mkdir()
        (artifacts / "another/generate_appcast").touch()
        result, _ = self.run_script(script, GITHUB_ENV=str(output))
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
