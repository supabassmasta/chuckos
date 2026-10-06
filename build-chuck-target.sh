#!/bin/bash
# Build the chuck binary for the ChuckOS target (Debian bookworm, amd64),
# without touching the installed system.
#
# It builds inside a bookworm chroot, not on this host: the host is Ubuntu
# 24.04, whose glibc/libstdc++ are newer than bookworm's, so a binary built
# here may refuse to run on ChuckOS. The chroot is created once (debootstrap),
# then reused on later runs.
#
# Usage:  sudo ./build-chuck-target.sh
# Output: ./chuck-target/chuck  -- copy it to the installed ChuckOS:
#         sudo install -m 755 chuck /usr/local/bin/chuck
#
# Requires on this host (install yourself): sudo apt install debootstrap rsync

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "error: run as root: sudo $0" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHUCK_SRC="$SCRIPT_DIR/../chuck-1.5.5.8"
CHROOT="${CHROOT:-$SCRIPT_DIR/.chuck-build-chroot}"
OUT_DIR="$SCRIPT_DIR/chuck-target"
SUITE="bookworm"
MIRROR="http://deb.debian.org/debian/"
OWNER="${SUDO_USER:-root}"

for tool in debootstrap rsync; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: $tool not installed. Run: sudo apt install debootstrap rsync" >&2
    exit 1
  fi
done

if [[ ! -d "$CHUCK_SRC" ]]; then
  echo "error: ChucK source not found at $CHUCK_SRC" >&2
  exit 1
fi

if [[ ! -x "$CHROOT/bin/sh" ]]; then
  echo "[build-chuck-target] creating bookworm chroot at $CHROOT (first run, a few minutes)..."
  debootstrap --variant=minbase \
    --include=build-essential,bison,flex,libsndfile1-dev,libasound2-dev \
    "$SUITE" "$CHROOT" "$MIRROR"
fi

MOUNTED=0
cleanup() {
  if [[ $MOUNTED -eq 1 ]]; then
    umount "$CHROOT/proc" 2>/dev/null || true
    umount "$CHROOT/dev" 2>/dev/null || true
  fi
}
trap cleanup EXIT

mount -t proc proc "$CHROOT/proc"
mount --bind /dev "$CHROOT/dev"
MOUNTED=1

echo "[build-chuck-target] syncing ChucK source into the chroot..."
mkdir -p "$CHROOT/root/chuck-src"
rsync -a --delete \
  --exclude '*.o' --exclude '*.d' \
  --exclude 'chuck' --exclude 'chuck.exe' \
  --exclude 'chuck.tab.*' --exclude 'chuck.yy.c' \
  --exclude 'chuck_yacc.c' --exclude 'chuck_yacc.h' \
  --exclude 'chuck.output' \
  --exclude '.git' \
  "$CHUCK_SRC/" "$CHROOT/root/chuck-src/"

echo "[build-chuck-target] compiling (make linux-alsa, same recipe as the image)..."
chroot "$CHROOT" /bin/bash -c 'set -e; cd /root/chuck-src/src; make clean >/dev/null 2>&1 || true; make linux-alsa'

mkdir -p "$OUT_DIR"
cp -f "$CHROOT/root/chuck-src/src/chuck" "$OUT_DIR/chuck"
chown -R "$OWNER":"$OWNER" "$OUT_DIR"

echo "[build-chuck-target] check: highest GLIBC symbol version required (must be <= 2.36 for bookworm):"
objdump -T "$OUT_DIR/chuck" | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1 || true

echo "[build-chuck-target] done: $OUT_DIR/chuck"
echo "[build-chuck-target] on the installed ChuckOS, replace the binary with:"
echo "  sudo install -m 755 chuck /usr/local/bin/chuck"
