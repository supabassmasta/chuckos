#!/bin/bash
# Runs once, at first boot (see chuckos-firstboot.service): adds the first
# regular user (the one the Debian installer created) to the groups needed
# for real-time audio and device access.
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

touch "$STATE_DIR/firstboot-done"
echo "[chuckos-firstboot] done."
