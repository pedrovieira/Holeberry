#!/usr/bin/env bash
# Validate and install only the profiles needed for this release.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
umask 077
if [ -z "${HOLEBERRY_APP_PROFILE:-}" ] || [ -z "${HOLEBERRY_WIDGET_PROFILE:-}" ]; then
  echo "::error::HOLEBERRY_APP_PROFILE and HOLEBERRY_WIDGET_PROFILE secrets are not set — cannot sign the app and widget; refusing to release"
  exit 1
fi
if [ -z "${HOLEBERRY_TEAM_ID:-}" ]; then
  echo "::error::HOLEBERRY_TEAM_ID secret is not set — cannot select profiles; refusing to release"
  exit 1
fi

# Test seam: tests point this at a sandbox directory. Production keeps the
# default per-user location, which the workflow cleanup also assumes.
INSTALL_DIR="${HOLEBERRY_PROFILE_INSTALL_DIR:-$HOME/Library/MobileDevice/Provisioning Profiles}"
MANIFEST="$RUNNER_TEMP/holeberry-installed-profiles.txt"
PROFILE_TEMP_DIR="$(mktemp -d "$RUNNER_TEMP/holeberry-profiles.XXXXXX")"
chmod 700 "$PROFILE_TEMP_DIR"
trap 'rm -rf "$PROFILE_TEMP_DIR"' EXIT
PROFILE_UUID=""

mkdir -p "$INSTALL_DIR"
: > "$MANIFEST"

install_profile() {
  local encoded="$1"
  local label="$2"
  local temp_profile="$PROFILE_TEMP_DIR/$label.provisionprofile"
  local temp_plist="$PROFILE_TEMP_DIR/$label.plist"
  local installed

  printf '%s' "$encoded" | base64 --decode > "$temp_profile"
  chmod 600 "$temp_profile"
  security cms -D -i "$temp_profile" > "$temp_plist"
  if ! PROFILE_UUID="$(python3 "$SCRIPT_DIR/check_profile.py" "$temp_plist" "$label" "$HOLEBERRY_TEAM_ID")"; then
    echo "::error::$label profile failed the authorization preflight checks"
    return 1
  fi
  installed="$INSTALL_DIR/$PROFILE_UUID.provisionprofile"
  if [ -e "$installed" ]; then
    if ! cmp -s "$temp_profile" "$installed"; then
      echo "::error::$label profile UUID $PROFILE_UUID already exists with different contents; refusing to overwrite"
      return 1
    fi
    echo "::notice::$label profile $PROFILE_UUID is already installed with identical contents; reusing it"
  else
    cp "$temp_profile" "$installed"
    printf '%s\n' "$installed" >> "$MANIFEST"
    chmod 600 "$installed"
    echo "::notice::Installed $label profile $PROFILE_UUID"
  fi
}

install_profile "$HOLEBERRY_APP_PROFILE" "app"
APP_UUID="$PROFILE_UUID"
install_profile "$HOLEBERRY_WIDGET_PROFILE" "widget"
WIDGET_UUID="$PROFILE_UUID"

echo "app_uuid=$APP_UUID" >> "$GITHUB_OUTPUT"
echo "widget_uuid=$WIDGET_UUID" >> "$GITHUB_OUTPUT"
echo "::notice::Using app profile $APP_UUID and widget profile $WIDGET_UUID"
