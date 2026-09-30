#!/bin/bash
# Runs once, at first boot (see chuckos-firstboot.service):
#  - adds the first regular user (the one the Debian installer created) to
#    the groups needed for real-time audio and device access
#  - reserves CPU cores for audio via the kernel command line (needs a
#    reboot to take effect -- see CPU governor for the every-boot half of
#    real-time CPU tuning, in chuckos-set-governor.sh)
set -euo pipefail

STATE_DIR=/var/lib/chuckos
mkdir -p "$STATE_DIR"

USER_NAME="$(awk -F: '$3>=1000 && $3<60000 {print $1; exit}' /etc/passwd || true)"

if [[ -n "${USER_NAME:-}" ]]; then
  usermod -aG audio,dialout,plugdev "$USER_NAME" || true
  echo "[chuckos-firstboot] added $USER_NAME to audio, dialout, plugdev groups"
else
  echo "[chuckos-firstboot] no regular user found yet; group setup skipped" >&2
fi

# --- reserve CPU cores for real-time audio (kernel cmdline, needs reboot) ---
# Assumes a 4-core machine, isolating cores 2-3 for audio use. Edit
# ISOLATED_CORES (and MIN_CORES) below if your hardware differs -- e.g. a
# Raspberry Pi with fewer cores. Skips itself rather than misconfiguring a
# machine that doesn't have enough cores to spare.
ISOLATED_CORES="2,3"
MIN_CORES=4
GRUB_FILE=/etc/default/grub

NPROC="$(nproc)"
if [[ "$NPROC" -ge "$MIN_CORES" ]]; then
  if [[ -f "$GRUB_FILE" ]]; then
    if ! grep -q "isolcpus=${ISOLATED_CORES}" "$GRUB_FILE"; then
      CMDLINE_ADD="isolcpus=${ISOLATED_CORES} nohz_full=${ISOLATED_CORES} rcu_nocbs=${ISOLATED_CORES}"
      sed -i -E "s/^(GRUB_CMDLINE_LINUX_DEFAULT=\")([^\"]*)(\")/\1\2 ${CMDLINE_ADD}\3/" "$GRUB_FILE"
      update-grub || echo "[chuckos-firstboot] warning: update-grub failed" >&2
      echo "[chuckos-firstboot] reserved CPUs ${ISOLATED_CORES} for audio (kernel cmdline) -- REBOOT REQUIRED for this to take effect"
    else
      echo "[chuckos-firstboot] CPU isolation already configured in $GRUB_FILE"
    fi
  else
    echo "[chuckos-firstboot] $GRUB_FILE not found, skipping CPU isolation setup" >&2
  fi
else
  echo "[chuckos-firstboot] only $NPROC CPU(s) detected (need >= $MIN_CORES) -- skipping CPU isolation" >&2
fi

touch "$STATE_DIR/firstboot-done"
echo "[chuckos-firstboot] done."
