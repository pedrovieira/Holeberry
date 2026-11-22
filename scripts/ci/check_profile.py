#!/usr/bin/env python3
"""Validate a decoded provisioning profile; print its UUID on success."""

import argparse
import datetime
import plistlib
import re
import sys

BUNDLE_IDS = {
    "app": "me.pedrovieira.holeberry",
    "widget": "me.pedrovieira.holeberry.widgets",
}
APP_GROUP = "group.me.pedrovieira.holeberry"
UUID_PATTERN = re.compile(r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}")


def fail(role, message):
    print(f"::error::{role}: {message}", file=sys.stderr)
    raise SystemExit(1)


def keychain_group(team):
    return f"{team}.me.pedrovieira.holeberry.shared"


def authorized(value, patterns):
    return isinstance(patterns, list) and any(
        isinstance(pattern, str)
        and (
            pattern == "*"
            or pattern == value
            or (pattern.endswith("*") and value.startswith(pattern[:-1]))
        )
        for pattern in patterns
    )


def load_plist(data, role, label):
    try:
        value = plistlib.loads(data)
    except Exception:
        fail(role, f"{label} is not a valid plist")
    if not isinstance(value, dict):
        fail(role, f"{label} is not a dictionary")
    return value


def check_profile(profile, role, team):
    if role not in BUNDLE_IDS:
        fail(role, "unknown target role")
    uuid = profile.get("UUID")
    if not isinstance(uuid, str) or not UUID_PATTERN.fullmatch(uuid):
        fail(role, "profile UUID is missing or unsafe")
    entitlements = profile.get("Entitlements")
    if not isinstance(entitlements, dict):
        fail(role, "profile Entitlements are missing")
    teams = profile.get("TeamIdentifier")
    if not isinstance(teams, list) or team not in teams:
        fail(role, "profile team does not match")
    if entitlements.get("com.apple.application-identifier") != f"{team}.{BUNDLE_IDS[role]}":
        fail(role, "profile application identifier does not match the target")
    if not authorized(APP_GROUP, entitlements.get("com.apple.security.application-groups")):
        fail(role, "profile does not authorize the registered App Group")
    if not authorized(keychain_group(team), entitlements.get("keychain-access-groups")):
        fail(role, "profile does not authorize the shared Keychain group")
    expiration = profile.get("ExpirationDate")
    if not isinstance(expiration, datetime.datetime):
        fail(role, "profile expiration date is missing")
    if expiration.tzinfo is None:
        expiration = expiration.replace(tzinfo=datetime.timezone.utc)
    if expiration <= datetime.datetime.now(datetime.timezone.utc):
        fail(role, "profile is expired")
    return uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("plist", help="Decoded provisioning profile plist")
    parser.add_argument("role", choices=BUNDLE_IDS)
    parser.add_argument("team")
    args = parser.parse_args()
    if not args.team:
        fail(args.role, "team is missing")
    try:
        with open(args.plist, "rb") as handle:
            data = handle.read()
    except OSError:
        fail(args.role, "profile is not readable")
    profile = load_plist(data, args.role, "profile")
    print(check_profile(profile, args.role, args.team))


if __name__ == "__main__":
    main()
