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
#   sudo apt install debootstrap debian-archive-keyring
#   ./vendor-live-build.sh    (no sudo -- see that script for why)
# Must itself be run as root (live-build needs it for chroot operations).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

DISTRIBUTION="bookworm"
ARCHITECTURE="amd64"
# live-build constructs the actual kernel package name as
# "<linux-packages-prefix>-<linux-flavours>" -- the prefix defaults
# correctly to "linux-image" and should not be touched; this is only the
# flavour suffix, giving "linux-image-rt-amd64" (Debian's real PREEMPT_RT
# kernel package name).
KERNEL_FLAVOUR="rt-${ARCHITECTURE}"

# where the ChucK source lives, relative to this script
CHUCK_SRC="$SCRIPT_DIR/../chuck-1.5.5.8"
CHUCK_SRC_DEST="config/includes.chroot/usr/local/src/chuck-1.5.5.8"

# we use a vendored, known-current live-build (see vendor-live-build.sh)
# instead of the system package -- the one Ubuntu ships is a very old,
# Ubuntu-patched snapshot (3.0~a57, circa 2012) with several hardcoded
# assumptions that don't hold for a current Debian target (wrong
# security-archive suite naming, obsolete bootloader/kernel package names,
# Ubuntu mirror/keyring defaults leaking in from /etc/live/build.conf) --
# all fixed/removed upstream since. LIVE_BUILD is live-build's own env var
# for "use these scripts instead of /usr/lib/live/build" -- it is exported
# so every invocation below (and everything live-build shells out to)
# consistently uses the vendored copy, never silently falling back to the
# system one.
LIVE_BUILD_DIR="$SCRIPT_DIR/.live-build"
LB="$LIVE_BUILD_DIR/frontend/lb"
export LIVE_BUILD="$LIVE_BUILD_DIR"
# `lb build` internally dispatches its sub-stages via bare "lb <stage>"
# calls, not through an absolute self-reference -- so the vendored
# frontend/ directory must come first on PATH too, or those recursive
# calls resolve to the system's old /usr/bin/lb instead. That old script
# would then source functions from LIVE_BUILD (our new vendored tree,
# still inherited) while running old frontend code -- an old-frontend/
# new-functions mismatch that crashes immediately (hit this once already:
# "/usr/bin/lb: 17: Echo: not found", a function the new version renamed).
export PATH="$LIVE_BUILD_DIR/frontend:$PATH"

if [[ $EUID -ne 0 ]]; then
  echo "error: this script must be run as root (live-build needs root for chroot operations)." >&2
  echo "  try: sudo $0 $*" >&2
  exit 1
fi

if [[ ! -x "$LB" ]]; then
  echo "error: vendored live-build not found at $LIVE_BUILD_DIR." >&2
  echo "  fetch it first (no sudo needed):" >&2
  echo "  ./vendor-live-build.sh" >&2
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
    "$LB" clean --purge || true
    # lb clean --purge does not reliably drop the bootstrap cache, nor does
    # it touch live-build's own internal config/* metadata files -- and
    # `lb config` itself MERGES onto whatever is already in config/ rather
    # than fully regenerating it, so a flag removed from one build.sh run
    # to the next can leave a stale value behind (bitten by this once
    # already: an old --linux-packages value silently survived a run where
    # that flag was no longer passed at all). So: wipe build state/cache,
    # and wipe every live-build-internal file directly under config/
    # EXCEPT the subdirectories we actually author by hand -- keep this
    # list of exceptions in sync with the "!config/..." lines in
    # .gitignore, since it's the same "what do we author vs. what does
    # live-build generate" distinction.
    rm -rf cache .build chroot binary local auto
    for entry in config/*; do
      case "$(basename "$entry")" in
        archives|bootloaders|hooks|includes.chroot|package-lists) ;; # ours -- keep
        *) rm -rf "$entry" ;;
      esac
    done
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

echo "[build.sh] configuring live-build (${DISTRIBUTION}/${ARCHITECTURE}, kernel flavour=${KERNEL_FLAVOUR})..."
DEBIAN_MIRROR="http://deb.debian.org/debian/"
DEBIAN_SECURITY_MIRROR="http://security.debian.org/debian-security/"
# --ignore-system-defaults: skip /etc/live/build.conf -- belt-and-suspenders
# alongside the explicit mirror/keyring flags below, so nothing is left to
# a host-specific system default regardless of what's installed here.
#
# --keyring-packages debian-archive-keyring: makes sure the chroot trusts
# (and, more importantly, ends up with) the Debian archive key, not
# whatever a given host's live-build might otherwise default to.
#
# --firmware-chroot false / --firmware-binary false: live-build can
# auto-detect firmware packages matching installed hardware drivers by
# downloading and parsing dists/<suite>/Contents-<arch>.gz. We already list
# the firmware packages we actually want explicitly in
# config/package-lists/chuckos.list.chroot, so we skip this (one less
# network dependency during the build).
#
# --bootappend-live "...console=...": this is a headless, terminal-only
# system -- the kernel must output to the serial port, not just local VGA.
# ttyS0 first so it's the primary console (login prompt etc. go there);
# tty1 also listed so a physically-attached monitor still works too.
# IMPORTANT: --bootappend-live REPLACES live-build's own default value
# wholesale, it doesn't add to it -- and that default is
# "boot=live components quiet splash" (see functions/configuration.sh),
# where "boot=live components" is NOT cosmetic: it's what tells the
# live-boot initramfs how to find/mount the live filesystem at all.
# Dropping it (as an earlier version of this script did, by only passing
# console= here) boots to a BusyBox rescue shell with "No root device
# specified" -- so it must be included explicitly below. "quiet splash" is
# intentionally NOT carried over -- we want boot messages visible, not
# hidden, on a system with no graphical splash anyway.
#
# --bootappend-install "keymap=fr": sets the Debian Installer's own
# keyboard-layout question to French/AZERTY by default too (its early
# keyboard-selection screen runs before any preseed file would normally be
# read, so this has to go on the kernel cmdline, not a config file).
# Unlike --bootappend-live above, this one is safe to pass standalone --
# live-build appends to it rather than replacing a default outright.
"$LB" config \
  --mode debian \
  --ignore-system-defaults \
  --distribution "${DISTRIBUTION}" \
  --architecture "${ARCHITECTURE}" \
  --archive-areas "main contrib non-free non-free-firmware" \
  --firmware-chroot false \
  --firmware-binary false \
  --bootappend-live "boot=live components console=ttyS0,115200n8 console=tty1" \
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
  --mirror-debian-installer "${DEBIAN_MIRROR}" \
  --parent-mirror-debian-installer "${DEBIAN_MIRROR}" \
  --keyring-packages "debian-archive-keyring" \
  --linux-flavours "${KERNEL_FLAVOUR}" \
  --bootappend-install "keymap=fr" \
  --binary-image iso-hybrid \
  --debian-installer live \
  --debian-installer-gui false \
  --iso-application "ChuckOS" \
  --iso-volume "ChuckOS ${DISTRIBUTION}"

echo "[build.sh] verifying resolved bootstrap mirror..."
if [[ -f config/bootstrap ]] && grep -qi "archive.ubuntu.com" config/bootstrap; then
  echo "error: config/bootstrap still references archive.ubuntu.com after lb config." >&2
  echo "  Contents of config/bootstrap for reference:" >&2
  grep -i mirror config/bootstrap >&2 || true
  exit 1
fi

echo "[build.sh] building image (this can take a while)..."
"$LB" build

ISO="$(ls -1t ./*.iso 2>/dev/null | head -n1)"
if [[ -n "$ISO" ]]; then
  echo "[build.sh] done: ${SCRIPT_DIR}/${ISO#./} ($(du -h "$ISO" | cut -f1))"
  echo "[build.sh] write it to a USB stick with, e.g.:"
  echo "  lsblk                      # find the right device first!"
  echo "  sudo dd if=${ISO#./} of=/dev/sdX bs=4M status=progress conv=fsync"
  echo "  (double check /dev/sdX -- the wrong device means data loss)"
else
  echo "[build.sh] warning: build finished but no .iso file was found; check output above." >&2
fi
