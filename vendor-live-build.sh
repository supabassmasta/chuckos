#!/bin/bash
# Fetch (or update) a current copy of live-build, vendored into .live-build/.
#
# Why: the live-build package shipped by Ubuntu (apt install live-build) is
# an old, Ubuntu-patched snapshot (3.0~a57, circa 2012) with several
# hardcoded assumptions that don't hold for a current Debian target --
# wrong security-archive suite naming, obsolete bootloader/kernel package
# names ("lilo", "linux-image-2.6-amd64"), Ubuntu mirror/keyring defaults
# leaking in from /etc/live/build.conf. Current upstream live-build (from
# Debian's live-team) has all of that fixed/removed. Rather than patch
# around an old package's bugs indefinitely, build.sh uses this vendored,
# current copy instead -- it's self-contained (a plain git clone, no
# install/dpkg step) and never touches the host's own live-build package.
#
# Usage:
#   ./vendor-live-build.sh          # clone if missing, else update
#
# No sudo needed -- this is a plain, unprivileged git clone.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

REPO_URL="https://salsa.debian.org/live-team/live-build.git"
DEST=".live-build"

if [[ -d "$DEST/.git" ]]; then
  echo "[vendor-live-build.sh] updating existing checkout in $DEST..."
  git -C "$DEST" pull --ff-only
else
  echo "[vendor-live-build.sh] cloning $REPO_URL into $DEST..."
  git clone --depth 1 "$REPO_URL" "$DEST"
fi

echo "[vendor-live-build.sh] done: $("$DEST/frontend/lb" --version 2>/dev/null || echo "(version check unavailable)")"
