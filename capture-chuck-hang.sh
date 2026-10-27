#!/bin/bash
# Run in a SECOND terminal right after pressing Ctrl-C in chuck (while it hangs).
# Captures where the leftover chuck threads are blocked in the kernel.
P="$(pgrep -x chuck | head -1)"
if [[ -z "$P" ]]; then echo "no chuck process running"; exit 1; fi
echo "=== chuck pid $P ==="
ps -L -p "$P" -o tid,stat,wchan:30,comm
for t in /proc/"$P"/task/*; do
  echo "== thread $(basename "$t")  state: $(awk '{print $3}' "$t/stat")"
  sudo cat "$t/stack" 2>/dev/null | head -15
done
echo "=== recent kernel messages (audio/HDA) ==="
sudo dmesg | grep -iE "snd|hda|azx|alsa|audio|timeout" | tail -30
