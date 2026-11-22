#!/usr/bin/env python3
"""Validate the built app and widget profiles, entitlements, and version metadata."""

import argparse
import subprocess
from pathlib import Path

from check_profile import APP_GROUP, BUNDLE_IDS, check_profile, fail, keychain_group, load_plist


def load_plist_command(command, role, label):
    result = subprocess.run(command, capture_output=True)
    if result.returncode != 0:
        fail(role, f"cannot read {label}")
    return load_plist(result.stdout, role, label)


def check_signed_bundle(app_path, team):
    app_path = Path(app_path)
    widget_path = app_path / "Contents/PlugIns/HoleberryWidgets.appex"
    expected_keychain_group = keychain_group(team)
    roles = {
        "app": (app_path, BUNDLE_IDS["app"]),
        "widget": (widget_path, BUNDLE_IDS["widget"]),
    }

    versions = {}
    for role, (bundle_path, bundle_id) in roles.items():
        profile_path = bundle_path / "Contents/embedded.provisionprofile"
        if not profile_path.is_file():
            fail(role, "embedded provisioning profile is missing")
        profile = load_plist_command(
            ["security", "cms", "-D", "-i", str(profile_path)],
            role,
            "embedded profile",
        )
        check_profile(profile, role, team)
        expected_app_id = f"{team}.{bundle_id}"

        actual = load_plist_command(
            [
                "codesign",
                "-d",
                "--entitlements",
                "-",
                "--xml",
                str(bundle_path),
            ],
            role,
            "signed entitlements",
        )
        if actual.get("com.apple.application-identifier") != expected_app_id:
            fail(role, "signed application identifier does not match")
        app_groups = actual.get("com.apple.security.application-groups")
        if not isinstance(app_groups, list) or APP_GROUP not in app_groups:
            fail(role, "signed App Group is missing")
        keychain_groups = actual.get("keychain-access-groups")
        if not isinstance(keychain_groups, list) or expected_keychain_group not in keychain_groups:
            fail(role, "signed concrete Keychain group is missing")
        for key in ("get-task-allow", "com.apple.security.get-task-allow"):
            if key in actual:
                fail(role, "signed entitlements contain a debug entitlement")
        if role == "widget":
            if actual.get("com.apple.security.app-sandbox") is not True:
                fail(role, "widget sandbox entitlement is missing")
            if actual.get("com.apple.security.network.client") is not True:
                fail(role, "widget network entitlement is missing")

        info_path = bundle_path / "Contents/Info.plist"
        try:
            data = info_path.read_bytes()
        except OSError:
            fail(role, "built Info.plist is not readable")
        info = load_plist(data, role, "built Info.plist")
        if info.get("CFBundleIdentifier") != bundle_id:
            fail(role, "built bundle identifier does not match")
        if info.get("HoleberryAppGroupIdentifier") != APP_GROUP:
            fail(role, "built App Group marker is incorrect")
        if info.get("HoleberryKeychainAccessGroup") != expected_keychain_group:
            fail(role, "built Keychain marker is not the expected concrete team-prefixed value")
        marketing = info.get("CFBundleShortVersionString")
        build = info.get("CFBundleVersion")
        if (
            not isinstance(marketing, str)
            or not marketing
            or not isinstance(build, str)
            or not build
        ):
            fail(role, "built version metadata is missing")
        versions[role] = (marketing, build)

    if versions["app"] != versions["widget"]:
        fail("app/widget", "built versions do not match")
    print(
        f"::notice::Signed app/widget metadata valid "
        f"(version {versions['app'][0]} build {versions['app'][1]})"
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app")
    parser.add_argument("team")
    args = parser.parse_args()
    check_signed_bundle(args.app, args.team)


if __name__ == "__main__":
    main()
