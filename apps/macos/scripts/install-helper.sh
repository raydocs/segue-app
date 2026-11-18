#!/bin/bash
# Stage 0 installer preview. Prints the copy, chmod, and launchctl steps.
# It never installs, never calls sudo, and never talks to launchd.
set -euo pipefail

if [[ "${1:-}" != "--dry-run" || $# -ne 1 ]]; then
  echo "usage: install-helper.sh --dry-run" >&2
  echo "refusing to install: stage 0 is dry-run only" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
HELPER_SRC="${HELPER_SRC:-$ROOT/apps/macos/.build/debug/segue-core-helper}"
PLIST_SRC="${PLIST_SRC:-$ROOT/apps/macos/Resources/com.segue.core-helper.plist}"
HELPER_DST="/Library/PrivilegedHelperTools/segue-core-helper"
PLIST_DST="/Library/LaunchDaemons/com.segue.core-helper.plist"
UID_DST="/Library/PrivilegedHelperTools/segue.allowed-uid"
RELEASE_SRC="${RELEASE_SRC:-$ROOT/apps/macos/.build/debug/segue-release}"
RELEASE_PLIST_SRC="${RELEASE_PLIST_SRC:-$ROOT/apps/macos/Resources/com.segue.release.plist}"
RELEASE_DST="/Library/PrivilegedHelperTools/segue-release"
RELEASE_PLIST_DST="/Library/LaunchDaemons/com.segue.release.plist"

echo "copy $HELPER_SRC -> $HELPER_DST"
echo "chmod 755 $HELPER_DST"
echo "copy $PLIST_SRC -> $PLIST_DST"
echo "chmod 644 $PLIST_DST"
echo "copy allowed-uid -> $UID_DST"
echo "chmod 644 $UID_DST"
echo "launchctl bootstrap system $PLIST_DST"
# The release daemon checks peers against the same allowed-uid file above;
# it has no state of its own to install.
echo "copy $RELEASE_SRC -> $RELEASE_DST"
echo "chmod 755 $RELEASE_DST"
echo "copy $RELEASE_PLIST_SRC -> $RELEASE_PLIST_DST"
echo "chmod 644 $RELEASE_PLIST_DST"
echo "launchctl bootstrap system $RELEASE_PLIST_DST"
