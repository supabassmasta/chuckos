# ChuckOS manual

A minimal, terminal-only Debian (bookworm) built for running [ChucK](https://chuck.stanford.edu/)
with low, tunable audio latency: PREEMPT_RT kernel, no graphical desktop, tmux as the
multi-terminal front end, real-time scheduling priority for the audio group, and ChucK built
from the source tree in `../chuck-1.5.5.8`.

## Building the image

On the host machine:
```
sudo apt install debootstrap debian-archive-keyring qemu-system-x86 qemu-utils rsync git
cd chuckos
./vendor-live-build.sh    # no sudo -- fetches a current live-build, see that script
sudo ./build.sh
```
This produces a `.iso` file in this directory. `build.sh` never calls `sudo` itself -- you always
run it as root explicitly, so it's obvious when privileged work is happening.

**Why `./vendor-live-build.sh` instead of `apt install live-build`:** the live-build Debian/Ubuntu
packages this host, `3.0~a57`, is a very old (circa 2012) snapshot with several hardcoded
assumptions that don't hold for a current Debian release -- wrong security-archive suite naming,
obsolete bootloader/kernel package names, Ubuntu mirror defaults leaking in from
`/etc/live/build.conf`. `vendor-live-build.sh` clones a current copy from Debian's live-team
upstream into `.live-build/` (gitignored) instead -- a plain, unprivileged git clone that never
touches the host's own `live-build` package. `build.sh` uses it automatically once present; re-run
`./vendor-live-build.sh` any time to update it.

**To customize:**
- Add/remove a package → edit `config/package-lists/chuckos.list.chroot` (one package per line),
  re-run `sudo ./build.sh`.
- Add or replace a file on the target system → drop it under `config/includes.chroot/<path from
  filesystem root>`, e.g. `config/includes.chroot/etc/foo.conf` becomes `/etc/foo.conf`.
- Run a step during the build itself (inside the chroot) → add a script under
  `config/hooks/live/`, named `NNNN-description.chroot`; hooks run in numeric order, after
  packages and `includes.chroot` files are already in place.

## Testing in a VM

```
sudo ./vm-test.sh
```
Boots the most recently built ISO in QEMU/KVM with a serial console (no graphical window --
`Ctrl-A X` quits). Forwards SSH to `localhost:2222`, and attaches a scratch 8GB disk
(`chuckos-test-disk.qcow2`) so you can run the installer inside the VM too, not just live-boot it.

**What you'll see on that serial console:** the isolinux boot menu ("Live system / Start installer
/ ...") is mirrored to serial too, with a 5-second auto-boot countdown -- it boots the default
"Live system" entry on its own if you don't press anything. Once the kernel itself starts,
everything (boot messages, login prompt, tmux) is fully visible and usable over this serial
console, since the kernel is configured to output to `ttyS0`.

The local/physical console (tty1, e.g. a real monitor, or `vm-test.sh --with-usb`-style direct
VGA) auto-logs in as `user` with no prompt at all. The *serial* console, deliberately, does not
auto-login -- it shows a real `login:` prompt. Credentials there are the standard Debian Live
default: username `user`, password `live` (yes, that's genuinely it -- see
`/usr/lib/live/config/0030-user-setup` in the image for where it's set; it's a well-known,
widely-documented default, fine for local testing, not something to rely on if this ever ends up
reachable on a real network).

Note: live-config's own `1160-openssh-server` component disables SSH *password* auth by default
at every live boot (sensible, given the well-known password above) -- ChuckOS explicitly
re-enables it via `config/includes.chroot/etc/ssh/sshd_config.d/10-chuckos.conf`, specifically so
`user`/`live` works over SSH too for testing. Same caveat applies: fine locally, don't rely on it
if this is ever reachable on a real network.

Once it's up:
```
ssh -p 2222 <your-user>@localhost
chuckos-checklist
```
(`<your-user>` here is whatever account you created while running the installer -- see
"SSH access" below for the live-boot-only case, where that's just `user`.)

`chuckos-checklist` (baked into the image, works on real hardware too) runs a battery of
pass/fail checks: RT kernel active, ChucK builds/runs, tmux/git/ssh present, audio-select /
chuck-run / net-toggle present, MIDI tooling present, rtprio limits configured.

**USB passthrough** (to functionally test the AKAI LPD8, Novation Launchpad, or Focusrite
Scarlett inside the VM):
```
./vm-test.sh --list-usb          # find vendor:product IDs with devices plugged in
# edit vm-test.sh, fill in LPD8_ID / LAUNCHPAD_ID / SCARLETT_ID
sudo ./vm-test.sh --with-usb     # usually needs root to open /dev/bus/usb/*
```
Passthrough grabs the device exclusively from the host while the VM runs.

**Audio device**: a virtual Intel HDA sound card is always attached, so `chuck --probe` /
`aplay -l` / `chuckos-checklist` see a real device (matching the "HDA" `audio-select` default) --
but by default it's not routed anywhere audible, just present for functional testing. To actually
hear test tones on this host's speakers:
```
./vm-test.sh --with-audio-host
```
Uses PulseAudio (works via native PulseAudio or PipeWire's pulse-compat shim, which covers most
current desktops); edit `AUDIO_HOST_BACKEND` in `vm-test.sh` if your host needs a different QEMU
audio backend (`qemu-system-x86_64 -audiodev help` lists what's available).

**Important**: latency *numbers* measured inside this VM are not trustworthy -- virtualization
scheduling jitter dominates them. Use the VM to confirm things boot and work correctly; measure
actual latency only on real hardware.

## Installing for real

`build.sh` prints the exact `dd` command at the end of a successful build. In short:
```
lsblk                       # identify your USB stick -- don't guess
sudo dd if=live-image-<arch>.hybrid.iso of=/dev/sdX bs=4M status=progress conv=fsync
```
Boot from that USB key on the target machine; the boot menu offers both **live** (try it without
touching the disk) and **install** (runs the Debian installer, text-mode, to install permanently).

## tmux cheat sheet

ChuckOS drops you into a shared tmux session called `main` automatically on login -- at the
physical console (tty1-6) or over SSH, so you see the same windows either way.

| Keys | Action |
|---|---|
| `Alt` + `→` / `←` | switch to next/previous window (no prefix needed -- this is the "Alt-Tab" feel) |
| `Alt` + `1`..`5` | jump straight to window 1-5 |
| `Ctrl-b` `c` | create a new window |
| `Ctrl-b` `,` | rename the current window |
| `Ctrl-b` `d` | detach (session keeps running in the background) |
| `Ctrl-b` `[` | enter scrollback/copy mode, then `↑`/`↓`/`PageUp`/`PageDown` to scroll, `q` to exit |
| `tmux attach -t main` | reattach manually if you ever exit the shell entirely |

**Mouse wheel scrolling**: works over SSH (your terminal client sends proper scroll-wheel escape
sequences, which tmux reads directly), but not at the physical/local console. That's a `gpm`
limitation, not something fixable in `tmux.conf`: `gpm` provides console copy/paste (click-drag to
select, middle-click to paste -- this part works everywhere) by managing its own selection buffer
directly at the console level, but it doesn't forward general mouse events -- including the wheel
-- to the foreground application the way a real terminal emulator does. There's no clean fix for
this on a raw Linux console short of running a full terminal-emulator layer (e.g. `fbterm`), which
would be a much bigger change than this is worth. Use `Ctrl-b [` then `PageUp`/`PageDown`/arrows
for scrollback at the physical console instead -- it's reliable everywhere.

**Alt+←/→ not switching windows at the physical console?** This was a real bug, fixed: `tmux`'s
`M-Left`/`M-Right` bindings only recognize the xterm-style escape sequence for Alt+arrow (what an
SSH client's terminal emulator sends), not the Linux console's own encoding for the same keypress
(`ESC ESC [ D` / `ESC ESC [ C` -- the console's Meta/Alt handling just prefixes a second ESC onto
the plain arrow key's sequence, which is different from xterm's single-sequence-with-modifier
form). `/etc/tmux.conf` now binds both forms explicitly (see the `user-keys` lines), so Alt+←/→
should work at the physical console too as of this build.

Config lives at `/etc/tmux.conf` -- edit `config/includes.chroot/etc/tmux.conf` and rebuild to
change it permanently.

## SSH access

`openssh-server` is enabled by default (`systemctl enable ssh`, done at build time). On real
hardware (or once *installed* in the VM), connect with `ssh <user>@<host-or-ip>` on port 22; the
user account itself is whatever you create during the Debian installer's user-setup step. In the
test VM, it's forwarded to `localhost:2222` (see above).

**Live-boot only (before installing)**: SSH works too, using the same Debian Live default as the
serial console -- `ssh -p 2222 user@localhost`, password `live`. See the note under "Testing in a
VM" above about that default.

On first boot, `chuckos-firstboot.service` runs once and adds that first regular user to the
`audio`, `dialout`, and `plugdev` groups (needed for real-time priority and raw device access).
**Log out and back in** (or reboot) after first boot for the new group membership to take effect.

## Audio device selection: HDA vs. Scarlett

Default is the onboard HDA. Switch with:
```
audio-select hda        # onboard HDA (default)
audio-select scarlett   # Focusrite Scarlett USB interface
audio-select status     # show current selection + what chuck --probe sees
```
This just remembers your choice (per-user, under `~/.config/chuckos/audio-device`). To actually
run ChucK against it, use the wrapper instead of calling `chuck` directly:
```
chuck-run myfile.ck                       # uses whichever device audio-select picked
chuck-run --bufsize:64 --bufnum:4 myfile.ck   # extra args pass straight through to chuck
```
Selection is done by matching device *names* (via ChucK's own `--dac:<name>` substring match
against what `chuck --probe` reports) rather than fixed device numbers, since USB card indices
can shift depending on plug order and boot timing.

## Network toggle

```
net-toggle wifi on|off|status
net-toggle eth  on|off|status
net-toggle all  on|off|status
```
Uses `rfkill` for wifi and `ip link` for the wired interface; both need `sudo` (you'll be
prompted for your password).

## Keyboard, mouse, power

- **Keyboard**: French/AZERTY by default, for both the running system (`/etc/default/keyboard`,
  `XKBLAYOUT="fr"`) and the Debian Installer's own keyboard-selection screen. This is the
  *console* keymap -- it only matters for a physical keyboard plugged directly into the machine;
  SSH and serial sessions use whatever layout your own terminal/client is already set to. To use a
  different layout, edit `config/includes.chroot/etc/default/keyboard` (`XKBLAYOUT`) and the
  `keymap=fr` in `build.sh`'s `--bootappend-install`, then rebuild.
- **Mouse**: `gpm` provides mouse support at the physical/local console (e.g. for text
  selection), and tmux's own mouse mode is on (click to switch panes/windows, wheel to scroll,
  drag to resize -- hold Shift while selecting to bypass tmux and use your terminal's native
  text selection instead).
- **Power**:
  ```
  chuckos-power off         # shut down
  chuckos-power reboot
  chuckos-power suspend     # sleep to RAM -- works out of the box on most hardware
  chuckos-power hibernate   # sleep to disk -- needs swap >= RAM, see below
  chuckos-power status      # shows RAM/swap and which of the above are actually usable
  ```
  Hibernate needs a swap partition/file at least as large as RAM. On a live-boot USB session
  there's no persistent swap at all, so hibernate is never available there -- only after
  installing to disk, and only if you gave it enough swap during partitioning. `chuckos-power
  status` tells you where you stand; `chuckos-power hibernate` refuses with a clear error instead
  of failing unpredictably if swap isn't sufficient.

## Tuning latency

The kernel is already PREEMPT_RT (`linux-image-rt-amd64`), and the following are handled
automatically -- nothing to do by hand:

- **CPU core isolation**: `chuckos-firstboot.service` reserves cores 2-3 for audio via the kernel
  command line (`isolcpus=2,3 nohz_full=2,3 rcu_nocbs=2,3`, appended to `GRUB_CMDLINE_LINUX_DEFAULT`
  in `/etc/default/grub`, followed by `update-grub`), assuming a 4-core machine. It checks `nproc`
  first and skips itself on a machine with fewer than 4 cores (e.g. some Raspberry Pi models)
  rather than misconfiguring it. **Takes effect after a reboot** -- reboot once after first boot
  for it to apply. To change which cores are isolated (or the minimum-core check), edit
  `ISOLATED_CORES`/`MIN_CORES` at the top of
  `config/includes.chroot/usr/local/bin/chuckos-firstboot.sh` and rebuild.
- **CPU governor**: `chuckos-cpu-governor.service` runs `cpupower frequency-set -g performance` on
  every boot (governors don't persist across reboots on their own, unlike the cmdline change
  above, so this re-applies it each time).
- **rtprio/memlock limits** for the `audio` group are set in
  `/etc/security/limits.d/99-chuckos-audio.conf` (rtprio 95, memlock unlimited, nice -19).
- **Actually requesting RT priority for ChucK itself**: the limits above only raise the *ceiling* --
  a process still has to explicitly ask for real-time scheduling. ChucK does this on its own (see
  `core/util_thread.cpp`/`host/chuck_main.cpp` in the ChucK source), but its *default* request is
  `sched_get_priority_max(SCHED_RR)` -- 99 on Linux, the literal system max, above our 95 ceiling --
  so the self-promotion silently fails (`EPERM`) and ChucK just runs as a normal process with no RT
  priority at all. `chuck-run` passes `--level:90` explicitly to avoid this (comfortably under the
  ceiling, and comfortably under 99, which is conventionally reserved for kernel RT threads --
  raising the ceiling to 99 instead would be the wrong fix). **Always use `chuck-run`, not bare
  `chuck`, to actually get real-time scheduling** -- `chuckos-checklist` verifies the `--level:`
  value stays within the configured ceiling, but running plain `chuck` skips this entirely.

The one knob left to tune by hand, per ChucK invocation, is buffer size/count:
```
chuck-run --bufsize:<N> --bufnum:<N> myfile.ck
```
Smaller buffers mean lower latency but more risk of xruns -- find the smallest stable value by
testing on real hardware (see the VM latency caveat above).

## Raspberry Pi (future)

This image (kernel package, live-build tooling) is x86-specific. Moving to a Raspberry Pi will
need a separate SD-card image build, but the *recipe* -- package list, tmux/limits.d/systemd
config under `includes.chroot`, the audio-select/chuck-run/net-toggle scripts, the ChucK build
hook -- should carry over largely unchanged, swapping only the kernel package for an RT-patched
Raspberry Pi kernel and the image-building tool (not `live-build`, which is Debian-live/x86
oriented).
