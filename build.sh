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
#   sudo apt install live-build debian-archive-keyring
# (debian-archive-keyring is needed even on a Debian host, and especially on
# a non-Debian host such as Ubuntu, so debootstrap can verify Debian's
# Release signatures when building a Debian target.)
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

if ! dpkg -s debian-archive-keyring >/dev/null 2>&1; then
  echo "error: debian-archive-keyring is not installed (needed to verify Debian's" >&2
  echo "  Release signatures -- this matters especially when building on a" >&2
  echo "  non-Debian host such as Ubuntu). On the host, run:" >&2
  echo "  sudo apt install debian-archive-keyring" >&2
  exit 1
fi

case "${1:-}" in
  clean|cleanonly)
    echo "[build.sh] cleaning previous build artifacts..."
    lb clean --purge || true
    # lb clean --purge does not reliably drop the bootstrap cache -- if a
    # previous run bootstrapped against the wrong mirror (e.g. this
    # project's own history of accidentally using the host's Ubuntu mirror
    # instead of Debian's), `lb build` will happily "restore" that stale,
    # wrong-mirror cache instead of re-bootstrapping. Remove it explicitly
    # so `clean` is actually a clean slate every time.
    rm -rf cache .build chroot binary
    if [[ "${1}" == "cleanonly" ]]; then
      exit 0
    fi
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
# --mode debian plus explicit Debian mirrors: live-build otherwise infers
# defaults (mirror, keyring) from the *host* OS. On a non-Debian host (e.g.
# this being built from Ubuntu) that silently points debootstrap at the
# Ubuntu archive, which has no "bookworm" suite and fails with a 404 on
# Release. Forcing these explicitly makes the target Debian regardless of
# host.
# the actual debootstrap invocation uses the *parent* mirror settings
# (LB_PARENT_MIRROR_BOOTSTRAP etc), not the plain --mirror-* ones -- those
# only affect the chroot's apt sources.list *after* bootstrapping. On this
# host, /etc/live/build.conf (shipped by Ubuntu's live-build package)
# apparently defaults the parent mirror to archive.ubuntu.com, and plain
# --mirror-bootstrap does not override that. Set both explicitly so nothing
# is left to a host-specific system default.
DEBIAN_MIRROR="http://deb.debian.org/debian/"
DEBIAN_SECURITY_MIRROR="http://security.debian.org/debian-security/"
lb config \
  --mode debian \
  --distribution "${DISTRIBUTION}" \
  --architectures "${ARCHITECTURE}" \
  --archive-areas "main contrib non-free non-free-firmware" \
  --mirror-bootstrap "${DEBIAN_MIRROR}" \
  --mirror-chroot "${DEBIAN_MIRROR}" \
  --mirror-chroot-security "${DEBIAN_SECURITY_MIRROR}" \
  --mirror-binary "${DEBIAN_MIRROR}" \
  --mirror-binary-security "${DEBIAN_SECURITY_MIRROR}" \
  --parent-mirror-bootstrap "${DEBIAN_MIRROR}" \
  --parent-mirror-chroot "${DEBIAN_MIRROR}" \
  --parent-mirror-chroot-security "${DEBIAN_SECURITY_MIRROR}" \
  --parent-mirror-binary "${DEBIAN_MIRROR}" \
  --parent-mirror-binary-security "${DEBIAN_SECURITY_MIRROR}" \
  --mirror-chroot-volatile "${DEBIAN_MIRROR}" \
  --parent-mirror-chroot-volatile "${DEBIAN_MIRROR}" \
  --mirror-binary-volatile "${DEBIAN_MIRROR}" \
  --parent-mirror-binary-volatile "${DEBIAN_MIRROR}" \
  --mirror-debian-installer "${DEBIAN_MIRROR}" \
  --parent-mirror-debian-installer "${DEBIAN_MIRROR}" \
  --linux-packages "${KERNEL_FLAVOR}" \
  --binary-images iso-hybrid \
  --debian-installer live \
  --debian-installer-gui false \
  --iso-application "ChuckOS" \
  --iso-volume "ChuckOS ${DISTRIBUTION}"

echo "[build.sh] verifying resolved bootstrap mirror..."
if [[ -f config/bootstrap ]] && grep -qi "archive.ubuntu.com" config/bootstrap; then
  echo "error: config/bootstrap still references archive.ubuntu.com after lb config." >&2
  echo "  this usually means /etc/live/build.conf on this host is overriding our" >&2
  echo "  settings. Contents of config/bootstrap for reference:" >&2
  grep -i mirror config/bootstrap >&2 || true
  exit 1
fi

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
