# ChuckOS manual

A minimal, terminal-only Debian (bookworm) built for running [ChucK](https://chuck.stanford.edu/)
with low, tunable audio latency: PREEMPT_RT kernel, no graphical desktop, tmux as the
multi-terminal front end, real-time scheduling priority for the audio group, and ChucK built
from the source tree in `../chuck-1.5.5.8`.

## Building the image

On the host machine:
```
sudo apt install live-build qemu-system-x86 qemu-utils rsync
cd chuckos
sudo ./build.sh
```
This produces `live-image-<arch>.hybrid.iso` in this directory. `build.sh` never calls `sudo`
itself -- you always run it as root explicitly, so it's obvious when privileged work is happening.

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

Once it's up:
```
ssh -p 2222 <your-user>@localhost
chuckos-checklist
```
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
| `Ctrl-b` `[` | enter scrollback/copy mode (`q` to exit) |
| `tmux attach -t main` | reattach manually if you ever exit the shell entirely |

Config lives at `/etc/tmux.conf` -- edit `config/includes.chroot/etc/tmux.conf` and rebuild to
change it permanently.

## SSH access

`openssh-server` is enabled by default (`systemctl enable ssh`, done at build time). On real
hardware, connect with `ssh <user>@<host-or-ip>` on port 22; the user account itself is whatever
you create during the Debian installer's user-setup step. In the test VM, it's forwarded to
`localhost:2222` (see above).

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

## Tuning latency

The kernel is already PREEMPT_RT (`linux-image-rt-amd64`). Further tuning is reboot-based, via
the kernel command line:
1. Edit `/etc/default/grub`, add to `GRUB_CMDLINE_LINUX_DEFAULT`, e.g.:
   `isolcpus=2,3 nohz_full=2,3 rcu_nocbs=2,3`
   (reserve CPU cores 2-3 for audio; adjust core numbers to your machine -- check with `nproc`)
2. `sudo update-grub && sudo reboot`
3. Set the CPU governor to performance: `sudo cpupower frequency-set -g performance` (or make
   this persistent via a systemd unit/udev rule if you want it every boot).
4. Tune ChucK's own buffer size/count via `chuck-run --bufsize:<N> --bufnum:<N>` -- smaller
   buffers mean lower latency but more risk of xruns; find the smallest stable value by testing.

rtprio/memlock limits for the `audio` group are already set in
`/etc/security/limits.d/99-chuckos-audio.conf` (rtprio 95, memlock unlimited, nice -19).

## Raspberry Pi (future)

This image (kernel package, live-build tooling) is x86-specific. Moving to a Raspberry Pi will
need a separate SD-card image build, but the *recipe* -- package list, tmux/limits.d/systemd
config under `includes.chroot`, the audio-select/chuck-run/net-toggle scripts, the ChucK build
hook -- should carry over largely unchanged, swapping only the kernel package for an RT-patched
Raspberry Pi kernel and the image-building tool (not `live-build`, which is Debian-live/x86
oriented).
