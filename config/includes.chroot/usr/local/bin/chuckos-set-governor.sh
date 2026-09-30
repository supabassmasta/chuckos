#!/bin/bash
# Set the CPU frequency governor to "performance" on every boot -- unlike
# the kernel cmdline CPU isolation (see chuckos-firstboot.sh), the governor
# does not persist across reboots on its own, so this needs to run each
# time (see chuckos-cpu-governor.service).
set -euo pipefail

if ! command -v cpupower >/dev/null 2>&1; then
  echo "[chuckos-cpu-governor] cpupower not found, skipping" >&2
  exit 0
fi

if cpupower frequency-set -g performance >/dev/null 2>&1; then
  echo "[chuckos-cpu-governor] governor set to performance"
else
  echo "[chuckos-cpu-governor] warning: failed to set performance governor (unsupported hardware?)" >&2
fi
