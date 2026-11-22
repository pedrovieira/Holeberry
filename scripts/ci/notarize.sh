#!/usr/bin/env bash
# Submit an app or DMG, require Apple's acceptance, then staple and validate it.
set -euo pipefail

TARGET="${1:?Usage: bash scripts/ci/notarize.sh <app-or-dmg>}"
: "${APPLE_API_KEY_ID:?APPLE_API_KEY_ID is required}"
: "${APPLE_API_ISSUER_ID:?APPLE_API_ISSUER_ID is required}"
KEY_PATH="${APPLE_API_KEY_PATH:-/tmp/holeberry-apple-api-key.p8}"
if [ ! -s "$KEY_PATH" ]; then
  echo "::error::Notarization API key is missing or empty"
  exit 1
fi

SUBMIT_PATH="$TARGET"
if [[ "$TARGET" == *.app ]]; then
  # Verify before spending time in the queue. notarytool needs a container.
  codesign --verify --deep --strict --verbose=2 "$TARGET"
  SUBMIT_PATH="$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/holeberry-app.XXXXXX").zip"
  TEMP_FILE="${SUBMIT_PATH%.zip}"
  trap 'rm -f "$SUBMIT_PATH" "$TEMP_FILE"' EXIT
  ditto -c -k --sequesterRsrc --keepParent "$TARGET" "$SUBMIT_PATH"
fi

# notarytool can exit 0 with an Invalid verdict. Require both a successful
# command and Accepted status; print Apple's log when a submission is rejected.
SUBMIT_STATUS=0
SUBMIT_OUTPUT="$(xcrun notarytool submit "$SUBMIT_PATH" \
  --key "$KEY_PATH" \
  --key-id "$APPLE_API_KEY_ID" \
  --issuer "$APPLE_API_ISSUER_ID" \
  --wait --timeout 30m 2>&1)" || SUBMIT_STATUS=$?
echo "$SUBMIT_OUTPUT"
if [ "$SUBMIT_STATUS" -ne 0 ] || ! grep -q '^[[:space:]]*status: Accepted[[:space:]]*$' <<< "$SUBMIT_OUTPUT"; then
  SUBMISSION_ID="$(sed -n 's/.*id: \([0-9a-f-]\{36\}\).*/\1/p' <<< "$SUBMIT_OUTPUT" | head -1)"
  if [ -n "$SUBMISSION_ID" ]; then
    echo "::error::Notarization failed — Apple's log:"
    xcrun notarytool log "$SUBMISSION_ID" \
      --key "$KEY_PATH" \
      --key-id "$APPLE_API_KEY_ID" \
      --issuer "$APPLE_API_ISSUER_ID" || true
  fi
  exit 1
fi

xcrun stapler staple "$TARGET"
xcrun stapler validate "$TARGET"
