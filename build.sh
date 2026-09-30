#!/bin/bash
# ChuckOS image builder
# ---------------------
# Wraps `live-build` to produce a live-bootable, installable ISO for
# ChuckOS: a minimal, terminal-only Debian with a PREEMPT_RT kernel, tmux,
# and ChucK built from the source tree in ../chuck-1.5.5.8.
#
# Usage:
#   sudo ./build.sh              # build the ISO
#   sudo ./build.sh clean        # wipe previous build state, then build
#   sudo ./build.sh cleanonly    # just wipe previous build state, don't build
#
# To customize:
#   - add/remove a package:  edit config/package-lists/chuckos.list.chroot
#   - add/replace a file on the target system: drop it under
#     config/includes.chroot/<path-from-filesystem-root>
#   - run a step during the build (inside the chroot): add a script under
#     config/hooks/live/, named NNNN-description.chroot (runs in numeric
#     order, after packages and includes.chroot are in place)
#
# Requires (on the host, install yourself -- this script never calls sudo):
#   sudo apt install live-build
# Must itself be run as root (live-build needs it for chroot operations).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

DISTRIBUTION="bookworm"
ARCHITECTURE="amd64"
KERNEL_FLAVOR="linux-rt"   # -> live-build installs linux-image-rt-${ARCHITECTURE}

# where the ChucK source lives, relative to this script
CHUCK_SRC="$SCRIPT_DIR/../chuck-1.5.5.8"
CHUCK_SRC_DEST="config/includes.chroot/usr/local/src/chuck-1.5.5.8"

if [[ $EUID -ne 0 ]]; then
  echo "error: this script must be run as root (live-build needs root for chroot operations)." >&2
  echo "  try: sudo $0 $*" >&2
  exit 1
fi

if ! command -v lb >/dev/null 2>&1; then
  echo "error: live-build is not installed. On the host, run:" >&2
  echo "  sudo apt install live-build" >&2
  exit 1
fi

case "${1:-}" in
  clean)
    echo "[build.sh] cleaning previous build artifacts..."
    lb clean --purge
    ;;
  cleanonly)
    echo "[build.sh] cleaning previous build artifacts..."
    lb clean --purge
    exit 0
    ;;
esac

if [[ ! -d "$CHUCK_SRC" ]]; then
  echo "error: expected ChucK source at $CHUCK_SRC (not found)." >&2
  exit 1
fi

echo "[build.sh] syncing ChucK source into the image (excluding build byproducts)..."
mkdir -p "$CHUCK_SRC_DEST"
rsync -a --delete \
  --exclude '*.o' --exclude '*.d' \
  --exclude 'chuck' --exclude 'chuck.exe' \
  --exclude 'chuck.tab.*' --exclude 'chuck.yy.c' \
  --exclude 'chuck_yacc.c' --exclude 'chuck_yacc.h' \
  --exclude 'chuck.output' \
  --exclude 'host-web/webchuck/js/webchuck.js' \
  --exclude 'host-web/webchuck/js/webchuck.wasm' \
  --exclude 'Release' --exclude 'Debug' \
  --exclude '.git' \
  "$CHUCK_SRC/" "$CHUCK_SRC_DEST/"

echo "[build.sh] configuring live-build (${DISTRIBUTION}/${ARCHITECTURE}, kernel=${KERNEL_FLAVOR})..."
lb config \
  --distribution "${DISTRIBUTION}" \
  --architectures "${ARCHITECTURE}" \
  --archive-areas "main contrib non-free non-free-firmware" \
  --linux-packages "${KERNEL_FLAVOR}" \
  --binary-images iso-hybrid \
  --debian-installer live \
  --debian-installer-gui false \
  --iso-application "ChuckOS" \
  --iso-volume "ChuckOS ${DISTRIBUTION}"

echo "[build.sh] building image (this can take a while)..."
lb build

ISO="$(ls -1t live-image-*.hybrid.iso 2>/dev/null | head -n1)"
if [[ -n "$ISO" ]]; then
  echo "[build.sh] done: ${SCRIPT_DIR}/${ISO} ($(du -h "$ISO" | cut -f1))"
  echo "[build.sh] write it to a USB stick with, e.g.:"
  echo "  lsblk                      # find the right device first!"
  echo "  sudo dd if=${ISO} of=/dev/sdX bs=4M status=progress conv=fsync"
  echo "  (double check /dev/sdX -- the wrong device means data loss)"
else
  echo "[build.sh] warning: build finished but no live-image-*.hybrid.iso was found; check output above." >&2
fi
