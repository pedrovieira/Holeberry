"""Release safeguards, exercised without signing keys or network access."""

import base64
import contextlib
import copy
import datetime
import io
import os
from pathlib import Path
import plistlib
import shutil
import stat
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
WIDGET_UUID = "87654321-4321-4321-4321-CBA987654321"


def profile(role="app", uuid=UUID):
    return {
        "UUID": uuid,
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
        # Each case starts from a fresh copy so one failed subtest cannot leak
        # its bad field into the cases that follow.
        original = copy.deepcopy(self.infos["widget"])
        for key, value in [
            ("CFBundleIdentifier", "wrong"),
            ("HoleberryAppGroupIdentifier", "wrong"),
            ("HoleberryKeychainAccessGroup", "$(AppIdentifierPrefix)shared"),
            ("CFBundleShortVersionString", "2.0"),
            ("CFBundleVersion", "124"),
            ("CFBundleVersion", ""),
        ]:
            with self.subTest(key=key, value=value):
                self.infos["widget"] = dict(copy.deepcopy(original), **{key: value})
                try:
                    with self.assertRaises(SystemExit):
                        self.check()
                finally:
                    self.infos["widget"] = copy.deepcopy(original)

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


class SandboxMixin:
    """Runs scripts with stubbed commands in a temporary directory."""

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

    def run_command(self, command, **env):
        """Run an argv list, so paths and variables are never re-parsed."""
        self.calls.write_text("")
        result = subprocess.run(
            command, env=dict(self.env, **env), cwd=self.temp,
            text=True, capture_output=True,
        )
        return result, self.calls.read_text()

    def run_script(self, script, **env):
        return self.run_command(["/bin/bash", "-c", script], **env)


class ShellTests(SandboxMixin, unittest.TestCase):
    def notarize(self, target, script=None, **env):
        return self.run_command(["/bin/bash", str(script or CI_DIR / "notarize.sh"), str(target)], **env)

    def notarization_env(self, **overrides):
        key = self.temp / "key.p8"
        key.write_text("test key")
        env = {"APPLE_API_KEY_ID": "key-id", "APPLE_API_ISSUER_ID": "issuer", "APPLE_API_KEY_PATH": str(key)}
        env.update(overrides)
        return env

    def test_notarization_requires_accepted_status_and_successful_command(self):
        self.stub("xcrun", '''
if [ "$1 $2" = "notarytool submit" ]; then
  echo 'id: 12345678-1234-1234-1234-123456789abc'
  echo "status: $TEST_VERDICT"
  exit "$TEST_NOTARY_EXIT"
fi
''')
        for verdict, code, accepted in [("Accepted", "0", True), ("Invalid", "0", False),
                                        ("In Progress", "0", False), ("Accepted", "1", False)]:
            with self.subTest(verdict=verdict, code=code):
                result, calls = self.notarize(
                    self.temp / "release.dmg",
                    **self.notarization_env(TEST_VERDICT=verdict, TEST_NOTARY_EXIT=code),
                )
                self.assertEqual(result.returncode == 0, accepted, result.stdout + result.stderr)
                self.assertEqual("stapler staple" in calls, accepted)
                self.assertEqual("stapler validate" in calls, accepted)
                self.assertEqual("notarytool log" in calls, not accepted)

    def test_app_is_verified_zipped_and_stapled(self):
        self.stub("xcrun", 'if [ "$1 $2" = "notarytool submit" ]; then echo "status: Accepted"; fi\n')
        self.stub("codesign", "exit 0\n")
        self.stub("ditto", "exit 0\n")
        app = self.temp / "Holeberry.app"
        result, calls = self.notarize(app, **self.notarization_env(RUNNER_TEMP=str(self.temp)))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"--verify --deep --strict --verbose=2 {app}", calls)
        self.assertIn("-c -k --sequesterRsrc --keepParent", calls)
        self.assertIn(f"stapler staple {app}", calls)
        self.assertEqual(list(self.temp.glob("holeberry-app.*")), [])

    def test_missing_notarization_credentials_fail_before_submission(self):
        self.stub("xcrun", "exit 0\n")
        cases = [
            ({"APPLE_API_KEY_ID": ""}, "APPLE_API_KEY_ID is required"),
            ({"APPLE_API_ISSUER_ID": ""}, "APPLE_API_ISSUER_ID is required"),
            ({"APPLE_API_KEY_PATH": str(self.temp / "absent.p8")}, "Notarization API key is missing or empty"),
        ]
        for overrides, message in cases:
            with self.subTest(message=message):
                result, calls = self.notarize(self.temp / "release.dmg", **self.notarization_env(**overrides))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stdout + result.stderr)
                self.assertEqual(calls, "")

    def test_script_path_with_shell_metacharacters_is_not_interpreted(self):
        # Paths reach the script as argv, so a checkout directory containing
        # literal $work or $(...) must run unchanged and execute nothing.
        checkout = self.temp / "Holeberry-$work" / "$(touch pwned)"
        checkout.mkdir(parents=True)
        script = checkout / "notarize.sh"
        shutil.copy2(CI_DIR / "notarize.sh", script)
        self.stub("xcrun", 'if [ "$1 $2" = "notarytool submit" ]; then echo "status: Accepted"; fi\n'
                           "exit 0\n")
        result, calls = self.notarize(self.temp / "release.dmg", script=script, **self.notarization_env())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("notarytool submit", calls)
        self.assertFalse((self.temp / "pwned").exists())

    def test_release_creation_and_reruns_stay_draft(self):
        # The lookup is a paginated release list, so it is draft-aware and only
        # authoritative when the request itself succeeds.
        self.stub("gh", '''
if [ "$1 $2" = "api --paginate" ]; then
  case "$TEST_RELEASE" in
    lookup-error) exit 1 ;;
    pagination-error)
      # Verified gh output shape: earlier pages, then the failed page's body.
      printf '"v1.2.3"\ttrue\n{"message": "simulated 503"}\n'
      exit 1
      ;;
    malformed) printf 'not-a-release-row\n' ;;
    ambiguous) printf '"v1.2.3"\ttrue\n"v1.2.3"\ttrue\n' ;;
    missing) ;;
    draft) printf '"v1.2.3"\ttrue\n' ;;
    published) printf '"v1.2.3"\tfalse\n' ;;
    unrelated) printf '"v1.2.2"\tfalse\n' ;;
  esac
fi
''')
        script = workflow_step("Create or update draft GitHub Release")
        failing = ("published", "lookup-error", "pagination-error", "malformed", "ambiguous")
        for state in ("missing", "unrelated", "draft", "published", "lookup-error",
                      "pagination-error", "malformed", "ambiguous"):
            with self.subTest(state=state):
                result, calls = self.run_script(script, TEST_RELEASE=state, GITHUB_REF_NAME="v1.2.3",
                                                GITHUB_REPOSITORY="pedrovieira/Holeberry",
                                                DMG_PATH="build/Holeberry-1.2.3.dmg")
                self.assertEqual(result.returncode == 0, state not in failing, result.stdout + result.stderr)
                if state in ("missing", "unrelated"):
                    self.assertIn("release create v1.2.3 build/Holeberry-1.2.3.dmg "
                                  "--draft --generate-notes --verify-tag", calls)
                elif state == "draft":
                    self.assertIn("release upload v1.2.3 build/Holeberry-1.2.3.dmg --clobber", calls)
                else:
                    self.assertNotIn("release upload", calls)
                    self.assertNotIn("release create", calls)
                self.assertNotIn("release edit", calls)
                self.assertNotIn("--latest", calls)
                # Draft-aware listing, not the tag endpoint that hides drafts.
                self.assertIn("repos/pedrovieira/Holeberry/releases?per_page=100", calls)
                self.assertNotIn("releases/tags/", calls)
                if state in ("lookup-error", "pagination-error"):
                    self.assertIn("Could not list releases", result.stdout + result.stderr)
                if state == "malformed":
                    self.assertIn("Unexpected release listing", result.stdout + result.stderr)
                if state == "ambiguous":
                    self.assertIn("Multiple releases match v1.2.3", result.stdout + result.stderr)
                if state == "published":
                    self.assertIn("is already published", result.stdout + result.stderr)

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
        duplicate = artifacts / "another/generate_appcast"
        duplicate.write_text("#!/bin/bash\n")
        # Both are executable: only the count can reject, whatever find's order.
        duplicate.chmod(0o700)
        result, _ = self.run_script(script, GITHUB_ENV=str(output))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Expected one executable generate_appcast", result.stdout + result.stderr)
        self.assertEqual(output.read_text(), f"GENERATE_APPCAST={tool}\n")

    def test_packaged_tool_search_failure_is_not_accepted(self):
        artifacts = self.temp / "build/SourcePackages/artifacts/sparkle"
        artifacts.mkdir(parents=True)
        tool = artifacts / "generate_appcast"
        tool.write_text("#!/bin/bash\n")
        tool.chmod(0o700)
        output = self.temp / "github-env"
        # Partial output then failure: one executable, but the search did not
        # finish, so it must not be treated as a complete result.
        self.stub("find", 'printf "%s\\n" "$TEST_FIND_MATCH"\nexit 1\n')
        result, _ = self.run_script(workflow_step("Locate packaged generate_appcast"),
                                    GITHUB_ENV=str(output), TEST_FIND_MATCH=str(tool))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("for generate_appcast failed", result.stdout + result.stderr)
        self.assertFalse(output.exists())


class InstallerTests(SandboxMixin, unittest.TestCase):
    """install_profiles.sh lifecycle with a stub CMS decoder and no real files."""

    def setUp(self):
        super().setUp()
        self.install_dir = self.temp / "Provisioning Profiles"
        self.manifest = self.temp / "holeberry-installed-profiles.txt"
        self.github_output = self.temp / "github-output"
        self.github_output.write_text("")
        self.profiles = {"app": profile("app"), "widget": profile("widget", uuid=WIDGET_UUID)}
        # Stand-in for `security cms -D -i <file>`: echo the decoded bytes.
        self.stub("security", 'for arg in "$@"; do last="$arg"; done\ncat "$last"\n')

    def encode(self, value):
        return base64.b64encode(plistlib.dumps(value)).decode("ascii")

    def installed(self, role):
        return self.install_dir / f"{self.profiles[role]['UUID']}.provisionprofile"

    def install(self, **overrides):
        env = {
            "HOLEBERRY_APP_PROFILE": self.encode(self.profiles["app"]),
            "HOLEBERRY_WIDGET_PROFILE": self.encode(self.profiles["widget"]),
            "HOLEBERRY_TEAM_ID": TEAM,
            "HOLEBERRY_PROFILE_INSTALL_DIR": str(self.install_dir),
            "RUNNER_TEMP": str(self.temp),
            "GITHUB_OUTPUT": str(self.github_output),
        }
        env.update(overrides)
        return self.run_command(["/bin/bash", str(CI_DIR / "install_profiles.sh")], **env)

    def test_missing_secrets_fail_before_installing(self):
        profiles_message = "HOLEBERRY_APP_PROFILE and HOLEBERRY_WIDGET_PROFILE secrets are not set"
        cases = [
            ({"HOLEBERRY_APP_PROFILE": ""}, profiles_message),
            ({"HOLEBERRY_WIDGET_PROFILE": ""}, profiles_message),
            ({"HOLEBERRY_TEAM_ID": ""}, "HOLEBERRY_TEAM_ID secret is not set"),
        ]
        for overrides, message in cases:
            with self.subTest(message=message):
                result, calls = self.install(**overrides)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stdout + result.stderr)
                self.assertEqual(calls, "")
                self.assertFalse(self.install_dir.exists())

    def test_installs_both_roles_with_outputs_and_manifest(self):
        result, calls = self.install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        app, widget = self.installed("app"), self.installed("widget")
        self.assertEqual(app.read_bytes(), plistlib.dumps(self.profiles["app"]))
        self.assertEqual(widget.read_bytes(), plistlib.dumps(self.profiles["widget"]))
        self.assertEqual(stat.S_IMODE(app.stat().st_mode), 0o600)
        self.assertEqual(self.manifest.read_text().splitlines(), [str(app), str(widget)])
        self.assertEqual(self.github_output.read_text().splitlines(),
                         [f"app_uuid={UUID}", f"widget_uuid={WIDGET_UUID}"])
        self.assertEqual(len(calls.splitlines()), 2)
        self.assertEqual(list(self.temp.glob("holeberry-profiles.*")), [])

    def test_identical_install_is_reused_and_not_owned(self):
        self.install_dir.mkdir(parents=True)
        widget = self.installed("widget")
        widget.write_bytes(plistlib.dumps(self.profiles["widget"]))
        result, _ = self.install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("already installed with identical contents", result.stdout)
        # Reused files predate this run, so cleanup must not own them.
        self.assertEqual(self.manifest.read_text().splitlines(), [str(self.installed("app"))])
        self.assertEqual(widget.read_bytes(), plistlib.dumps(self.profiles["widget"]))

    def test_conflicting_uuid_contents_are_refused_and_preserved(self):
        self.install_dir.mkdir(parents=True)
        widget = self.installed("widget")
        widget.write_bytes(b"a different profile")
        result, _ = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(f"profile UUID {WIDGET_UUID} already exists with different contents",
                      result.stdout + result.stderr)
        self.assertEqual(widget.read_bytes(), b"a different profile")
        # Partial success: the manifest owns only the app profile this run wrote.
        self.assertEqual(self.manifest.read_text().splitlines(), [str(self.installed("app"))])
        self.assertEqual(self.github_output.read_text(), "")


if __name__ == "__main__":
    unittest.main()
