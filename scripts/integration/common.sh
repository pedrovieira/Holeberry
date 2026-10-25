#!/usr/bin/env bash
# Shared shell bootstrap for the local integration harness.
#
# This file is sourced by up, test and down. It only locates python3 and
# forwards all arguments; lifecycle, validation and supervision live in
# harness.py.

set -eu

if [ -z "${SCRIPT_DIR:-}" ]; then
  SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
fi

HARNESS_PYTHON="${HARNESS_PYTHON:-python3}"

harness_exec() {
  subcommand="${1:-}"
  if [ -z "$subcommand" ]; then
    printf '%s phase=options status=failed detail="missing subcommand"\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >&2
    return 1
  fi
  shift

  if ! command -v "$HARNESS_PYTHON" >/dev/null 2>&1; then
    printf '%s phase=preflight status=failed detail="python3 is required; set HARNESS_PYTHON to override"\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >&2
    return 1
  fi

  exec "$HARNESS_PYTHON" "$SCRIPT_DIR/harness.py" "$subcommand" "$@"
}
