# Debug brief: chuck hangs on Ctrl-C with MIDI devices connected

Status as of 2026-10-27. Written so a fresh Claude Code session (e.g. one running
directly on the installed ChuckOS machine) has full context without needing this
conversation's history, which can't be transferred between machines.

## Symptom

On the installed ChuckOS (real hardware, not the VM), running a ChucK program that
opens MIDI input from the AKAI LPD8 and/or Novation Launchpad and pressing Ctrl-C:
the process never exits. `kill -9` on it does nothing. Confirmed NOT reproducible
with no MIDI devices open (clean exit) or in the `vm-test.sh` VM with a virtual
ALSA "Midi Through" MIDI port (also exits cleanly there, 3/3 runs). The bug appears
specific to real USB MIDI hardware on real hardware.

## Diagnosis so far

`ps -L -p <pid> -o tid,stat,wchan` on the stuck process shows a thread in `D`
state (uninterruptible, hence unkillable) with wchan `snd_use_lock_sync_helper`.
Its kernel stack (`/proc/<pid>/task/<tid>/stack`):

```
snd_use_lock_sync_helper+0x3e/0x50 [snd_seq]
port_delete+0x29/0x80 [snd_seq]
snd_seq_delete_all_ports+0x152/0x1b0 [snd_seq]
seq_free_client1.part.0+0x44/0xa0 [snd_seq]
seq_free_client+0x38/0x60 [snd_seq]
snd_seq_release+0x1a/0x50 [snd_seq]
__fput+0x89/0x250
...
do_exit / do_group_exit / exit_group
```

`dmesg` shows: `ALSA: seq_lock: waiting [118 left] in sound/core/seq/seq_ports.c:250`.

Interpretation: at process exit, the kernel closes the ALSA sequencer client fd,
which deletes the client's MIDI ports. Deleting a port waits (`snd_use_lock_sync`)
for every outstanding reference on that port to be released. Something is holding
such a reference and never releases it, so the wait never ends. This is a kernel
wait, which is why `SIGKILL` has no effect.

## Fixes already applied (in `../chuck-1.5.5.8/src`, NOT a git repo -- it's a source
drop, so these are plain uncommitted edits, visible via diffing against a fresh
download of chuck 1.5.5.8 if needed)

1. **`host/chuck_audio.cpp`**, `ChuckAudio::shutdown()`: changed `stop()` (which
   calls RtAudio's `stopStream()`, which does `snd_pcm_drain()` on ALSA) to
   `abortStream()` (does `snd_pcm_drop()` instead). Rationale: `stopStream()`'s
   drain never completes once the audio callback thread has stopped on a
   non-synchronized duplex stream. This fixed a *separate*, now-confirmed-resolved
   hang (reproduced and fixed, confirmed via VM testing across all 7 `otf_*`
   examples). This fix stands regardless of the MIDI issue below.

2. **`core/midiio_rtmidi.h`** and **`core/midiio_rtmidi.cpp`**: added
   `MidiInManager::shutdown()` and `MidiOutManager::shutdown()`. Each iterates the
   manager's static port vector (`the_mins` / `the_mouts`) and calls `closePort()`
   on every open one (which stops and joins the ALSA input thread, per RtMidi's own
   `MidiInAlsa::closePort()` -- writes to a trigger pipe the thread's `poll()` is
   waiting on, then `pthread_join`s it). Also logs a count via
   `EM_log(CK_LOG_SYSTEM, "closed %lu open MIDI input/output port(s)", ...)`.

3. **`core/chuck.cpp`**: in `global_cleanup()` / `global_cleanup` (the function
   logging "detaching all resources..."), replaced the commented-out
   `// midirw_detach();` with calls to `MidiInManager::shutdown()` and
   `MidiOutManager::shutdown()`.

All three files were checked with `g++ -fsyntax-only` using the same defines/
includes as the real build (`-D__LINUX_ALSA__ -D__PLATFORM_LINUX__ -I. -Icore
-Icore/lo -Ihost/RtAudio`) and compile cleanly. Built via `./build-chuck-target.sh`
(builds in a Debian bookworm chroot for ABI compatibility -- see that script) and
installed via `sudo install -m 755 chuck-target/chuck /usr/local/bin/chuck`.

## Current result: fix #2/#3 is necessary but NOT sufficient

Latest `-v 5` log from the user, with the LPD8 and Launchpad connected, confirms
the new shutdown code runs:
```
[chuck:2:SYSTEM]:  | closed 3 open MIDI input port(s)
[chuck:2:SYSTEM]:  | closed 1 open MIDI output port(s)
```
...followed by the rest of the normal shutdown log, ending at "ChucK instance
shutdown complete." -- and the process still hangs afterward (same kernel stack as
before, confirmed via a second hang capture after this fix was installed).

So: chuck's own MIDI input threads ARE being stopped and joined before exit. The
kernel is still waiting on a port reference held by something else -- most likely
either (a) an ALSA sequencer *subscription* from the USB MIDI kernel client (the
LPD8/Launchpad's own kernel-side sequencer port) that wasn't explicitly
unsubscribed, or (b) an event still in flight/queued for delivery to the port.

Note: `MidiInAlsa::closePort()` (in `core/rtmidi.cpp`) DOES call
`snd_seq_unsubscribe_port()` when `connected_` is true, before stopping the
thread -- so this ought to already be covered, assuming `connected_` is set
correctly for these ports. Worth re-checking.

## Requested next diagnostic (not yet obtained)

Asked the user to run, both while chuck is still running (MIDI devices connected,
before Ctrl-C) and again during the hang:
```
aconnect -l
cat /proc/asound/seq/clients
```
If chuck's MIDI ports still show subscriptions/connections to the LPD8 or
Launchpad clients after the "closed N ports" log lines (or during the hang),
that confirms the kernel-side subscription is the leaked reference.

## Candidate next fixes, not yet attempted

- If subscriptions are confirmed still present: make `MidiInManager::shutdown()` /
  `MidiOutManager::shutdown()` explicitly delete the underlying ALSA ports too
  (not just `closePort()`), i.e. actually destruct/delete the `RtMidiIn`/
  `RtMidiOut` objects (triggers `~MidiInAlsa()`/`~MidiOutAlsa()`, which call
  `snd_seq_delete_port()` and `snd_seq_close()`) rather than leaving them merely
  disconnected. Current code deliberately does NOT delete them (to avoid touching
  objects the VM/ChucK-side `MidiIn`/`MidiOut` wrapper objects might still
  reference) -- this tradeoff may need revisiting.
- If that still hangs: the wait would then be happening in our own explicit
  `snd_seq_delete_port()` call instead of at kernel-exit time -- same root cause,
  different call site, but at least isolates it further (e.g. confirms it's not
  specifically an exit-path/process-teardown race).
- Larger fallback option, not started: switch chuck's MIDI backend away from the
  ALSA sequencer (`snd_seq`) to the ALSA raw MIDI interface (`snd_rawmidi`) for
  class-compliant USB MIDI devices. Avoids the sequencer port/subscription model
  entirely. This is a bigger change to `core/midiio_rtmidi.cpp` / `core/rtmidi.cpp`
  and hasn't been scoped.

## Where things live

- This project (ChuckOS build system, docs, scripts): `chuckos/` -- see
  `chuckos/MANUAL.md` for the full system, `chuckos/build.sh` for the image build,
  `chuckos/build-chuck-target.sh` for building just the `chuck` binary for the
  installed system without rebuilding the whole image.
- ChucK source (being patched): `../chuck-1.5.5.8/src/` relative to `chuckos/`
  (i.e. sibling directory). Not a git repo -- a source drop from the upstream
  release. `chuckos/chuck-1.5.5.8/CLAUDE.md`-equivalent doc:
  `linux4chuck/CLAUDE.md` at the top of the whole working tree describes its
  architecture (parser -> type-checker -> emitter -> VM, core/host split, etc).
- `chuckos/chuck-target/chuck` -- last binary built by `build-chuck-target.sh`,
  what's currently installed on the hardware (md5 `eaac03c1...` as of the abort-
  stream-only fix; a newer one exists after the MIDI shutdown fix, not yet
  re-verified against the installed binary's md5sum).

## How to reproduce / test

No physical MIDI hardware is available in this development environment (a QEMU
VM was used throughout, with a virtual Intel HDA sound device for audio testing,
and only the virtual ALSA "Midi Through" port for MIDI -- which does NOT
reproduce this bug). All testing of the actual hang has to happen on the real
ChuckOS hardware with the LPD8/Launchpad connected. A minimal repro `.ck` file
(just opens MIDI input 0 and polls) was used in earlier VM attempts; see
conversation context or recreate: `MidiIn min; min.open(0); MidiMsg msg; while(
true ){ min => now; while(min.recv(msg)){} 100::ms => now; }`.
