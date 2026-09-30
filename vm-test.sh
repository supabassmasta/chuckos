#!/bin/bash
# Boot the ChuckOS ISO in QEMU/KVM for testing.
#
# Usage:
#   ./vm-test.sh                    # boot the most recently built ISO
#   ./vm-test.sh path/to/some.iso   # boot a specific ISO
#   ./vm-test.sh --with-usb         # also pass through MIDI/audio USB devices (see below)
#   ./vm-test.sh --list-usb         # just print `lsusb`, to find vendor:product IDs
#
# Once booted: ssh -p 2222 <user>@localhost
# Ctrl-A X quits QEMU from this console (it's serial-only, no graphical window).
#
# A scratch virtual disk (chuckos-test-disk.qcow2, created on first run) is
# attached too, so you can also exercise the installer inside the VM, not
# just the live boot.
#
# USB passthrough (LPD8 / Launchpad / Scarlett): fill in the vendor:product
# IDs below (from `./vm-test.sh --list-usb` with the devices plugged in),
# then pass --with-usb. This grabs the device exclusively from the host
# for as long as the VM runs, and usually needs the VM itself run as root
# (sudo ./vm-test.sh --with-usb) to open /dev/bus/usb/*.
#
# IMPORTANT: audio/MIDI *latency* numbers measured inside this VM are not
# meaningful -- virtualization scheduling jitter dominates them. Use this
# VM to validate that things boot and work, not to judge real-time
# performance; do that on real hardware.
#
# Requires: qemu-system-x86_64, qemu-img (apt install qemu-system-x86 qemu-utils).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# --- fill these in once you know the device IDs (see --list-usb) ---
LPD8_ID=""        # e.g. "09e8:0026"
LAUNCHPAD_ID=""   # e.g. "1235:0069"
SCARLETT_ID=""    # e.g. "1235:8211"
# ---------------------------------------------------------------------

WITH_USB=0
ISO=""

for arg in "$@"; do
  case "$arg" in
    --list-usb) lsusb; exit 0 ;;
    --with-usb) WITH_USB=1 ;;
    *.iso) ISO="$arg" ;;
  esac
done

if [[ -z "$ISO" ]]; then
  ISO="$(ls -t live-image-*.hybrid.iso 2>/dev/null | head -n1)"
fi
if [[ -z "$ISO" || ! -f "$ISO" ]]; then
  echo "error: no ISO found. Build one first with ./build.sh, or pass a path." >&2
  exit 1
fi

if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
  echo "error: qemu-system-x86_64 not found. On the host, run:" >&2
  echo "  sudo apt install qemu-system-x86 qemu-utils" >&2
  exit 1
fi

ACCEL="tcg"
if [[ -r /dev/kvm && -w /dev/kvm ]]; then
  ACCEL="kvm"
else
  echo "note: /dev/kvm not accessible -- falling back to software emulation (slow)." >&2
  echo "  fix: sudo usermod -aG kvm \$USER   (then log out/in)" >&2
fi

DISK="chuckos-test-disk.qcow2"
if [[ ! -f "$DISK" ]] && command -v qemu-img >/dev/null 2>&1; then
  echo "[vm-test.sh] creating scratch install disk: $DISK (8G, sparse)"
  qemu-img create -f qcow2 "$DISK" 8G >/dev/null
fi

QEMU_ARGS=(
  -M q35 -accel "$ACCEL" -m 2048 -smp 2
  -cdrom "$ISO"
  -boot d
  -nographic
  -serial mon:stdio
  -netdev "user,id=net0,hostfwd=tcp::2222-:22"
  -device virtio-net-pci,netdev=net0
)
[[ -f "$DISK" ]] && QEMU_ARGS+=( -drive "file=$DISK,if=virtio,format=qcow2" )

if [[ $WITH_USB -eq 1 ]]; then
  QEMU_ARGS+=( -device qemu-xhci )
  ANY_ID=0
  for id in "$LPD8_ID" "$LAUNCHPAD_ID" "$SCARLETT_ID"; do
    if [[ -n "$id" ]]; then
      QEMU_ARGS+=( -device "usb-host,vendorid=0x${id%%:*},productid=0x${id##*:}" )
      ANY_ID=1
    fi
  done
  if [[ $ANY_ID -eq 0 ]]; then
    echo "warning: --with-usb given but no device IDs are set in this script yet." >&2
    echo "  run './vm-test.sh --list-usb' with the devices plugged in, then edit vm-test.sh." >&2
  fi
  echo "note: USB passthrough usually needs root -- try 'sudo ./vm-test.sh --with-usb' if devices don't show up." >&2
fi

echo "[vm-test.sh] booting $ISO (accel=$ACCEL)..."
echo "[vm-test.sh] once booted: ssh -p 2222 <user>@localhost"
echo "[vm-test.sh] then run:   chuckos-checklist"
echo "[vm-test.sh] Ctrl-A X to quit QEMU from this console."
echo

exec qemu-system-x86_64 "${QEMU_ARGS[@]}"
