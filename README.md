# quiet-mic

A working, reusable acoustic echo cancellation (AEC) setup for PipeWire — stops
desktop/speaker output from bleeding into a microphone during recording.

## The problem

Trigger case: recording with OBS while desktop audio (a Bluetooth speaker) bleeds into
a USB condenser mic, with no built-in AEC on Linux the way Windows/macOS have.

`libpipewire-module-echo-cancel` already ships with PipeWire (confirmed present in
1.6.8, along with its `webrtc-audio-processing` backend, both v1 and v2). The DSP is not
the missing piece — **no working, reboot-safe example config exists anywhere**:
`/usr/share/pipewire/filter-chain/` ships examples for rnnoise, dolby, and upmix, but
not echo-cancel, and no prior user-level config existed on this machine.

Configs found in forum posts hardcode today's PipeWire node names
(`bluez_output.51_65_E6_58_40_2C.1`, `alsa_input.usb-DCMT_..._mono-fallback`) — these
are **not stable** across reboots or Bluetooth reconnects, so a config that works today
silently breaks later. That instability, not the DSP, is the real unsolved gap.

## Install

```
git clone https://github.com/vanshdev0101/quiet-mic
cd quiet-mic
./scripts/install.sh
```

This targets **this specific machine** (this USB mic's serial, this Bluetooth MAC) —
edit `pipewire-pulse.conf.d/10-echo-cancel.conf` and the two `wireplumber.conf.d/*.conf`
files first if installing elsewhere (swap in your own device identifiers; find them via
`pw-dump | grep device.name`). The script only symlinks three config files and restarts
the three affected services — nothing else, no package manager, no daemon.

After install, follow the printed next steps: set `aec_sink` as your default output, make
sure your default *source* isn't a Bluetooth mic (see Known limitations below), and point
your recording app at `aec_source`. Then run `./scripts/verify-aec.sh` to confirm.

To uninstall: remove the three symlinks (`~/.config/pipewire/pipewire-pulse.conf.d/10-echo-cancel.conf`,
`~/.config/wireplumber/wireplumber.conf.d/51-alsa-usb-mic.conf`, `51-bluez-desktop.conf`) and restart
`pipewire pipewire-pulse wireplumber`. Nothing else is touched.

## Evidence

`evidence/baseline-status.txt` — full `wpctl status` / `pactl` dump of the real audio
graph on the target machine before any fix.

`evidence/before.wav` / `evidence/after.wav` — the same 440Hz test tone
(`evidence/tone.wav`) played through the desktop sink while recording from the raw mic
(`before.wav`) vs. the AEC source (`after.wav`). Measured via `ffmpeg -af astats`:

| | RMS level |
|---|---|
| Silence (mic only, nothing playing) | -24.5 dB |
| During playback, raw mic, no AEC (`before.wav`) | -13.8 dB, peak -0.65 dB (near clipping) |
| During playback, AEC source (`after.wav`) | -56.1 dB |

The raw-mic number confirms the bleed is real and severe (near clipping, not a marginal
effect); the AEC number is a ~42dB drop from it. `verify-aec.sh` re-measures this live
every run rather than trusting these two fixed recordings — see Known limitations for
why the exact number varies run to run.

## What it is

Config-only: no custom DSP, no daemon. Three pieces, all additive PipeWire/WirePlumber
drop-ins:

1. `pipewire-pulse.conf.d/10-echo-cancel.conf` — loads the pulse-compat
   `module-echo-cancel` on every `pipewire-pulse` startup via plain `key=value` args
   against fixed node targets. (Not the native `libpipewire-module-echo-cancel` JSON
   form originally planned — see S2 notes below for why.)
2. `wireplumber.conf.d/51-alsa-usb-mic.conf`, `51-bluez-desktop.conf` — pin stable
   `node.name`s (`usb_condenser_mic`, `bt_desktop_speaker`) to the USB mic and
   Bluetooth sink by hardware identity (USB serial, Bluetooth MAC), so the AEC
   config's targets don't rot after a reboot or reconnect.
3. `scripts/verify-aec.sh` — first checks that the mic, speaker, and AEC nodes exist and
   that the module is actually wired to them (PipeWire silently falls back to a default
   device otherwise), then plays a known tone and asserts the AEC source is measurably
   quieter than the raw mic during playback. Fails on a raw/unpatched or missing-hardware
   setup, passes on the fixed one.

## Status

Done: S0-S6 all complete. `scripts/install.sh` tested end to end on the target machine
(fresh symlink + service restart + reconnect + verify all passing). See `PLAN.md` for
the full staged build history.

## Known limitations

- **Restarting `pipewire`/`pipewire-pulse`/`wireplumber` disconnects the Bluetooth
  speaker entirely**, every time, on this machine — confirmed repeatedly during
  development. This isn't something this config can fix (it's below PipeWire, in
  BlueZ/the kernel Bluetooth stack); `install.sh` restarts these services, so if you're
  on Bluetooth, expect to run `bluetoothctl connect <MAC>` once afterward.
- **Leaving a Bluetooth mic as your default audio *source*** forces BlueZ to negotiate
  bidirectional HSP/HFP instead of output-only A2DP, silently downgrading your speaker
  from stereo/48kHz to mono/16kHz. `install.sh` tells you to check this; it doesn't fix
  it automatically since "your default source" is a judgment call the script shouldn't
  make for you on a machine it doesn't know.
- **The measured dB reduction varies run to run** (28.9 / 26.2 / 14.6 / 17.0 / 35.9 dB
  across this project's own testing) — likely the AEC filter's adaptive convergence
  state after a reload, or minor volume/acoustic differences between runs. All
  comfortably clear `verify-aec.sh`'s 10dB pass threshold, but don't treat any single
  number as precise; treat the script's pass/fail as the signal.
- **Missing hardware fails silently at the PipeWire level.** If the USB mic is unplugged
  or the speaker is off when the services start, PipeWire doesn't error — named targets
  quietly resolve to some other default device. `verify-aec.sh` preflights for this and
  fails loudly; nothing else in the setup will tell you. (An earlier version of the
  script lacked these checks and passed at 46.1dB with the mic unplugged — found and
  fixed during final review.)
- **Tested only on one machine and one acoustic setup**: a USB condenser mic and a
  Bluetooth speaker, measured with a synthetic 440Hz tone. It has not been tested with
  music/speech through the speaker, other hardware, or a real OBS recording (that last
  one is the intended human check).
- **Apps must be manually pointed at the new devices.** This config creates
  `aec_sink`/`aec_source` alongside your existing devices — it doesn't retroactively
  reconfigure an app (OBS, Discord, etc.) that's already set to the raw mic or a
  specific output. You do that once, per app.

## Development log

Per-stage notes, newest first. These are the real debugging story, mistakes included —
useful if something here doesn't behave the way the summary above says it should.

### S3 notes — a real regression found live, and S5 pulled forward because of it

Renaming worked exactly as designed (`monitor.alsa.rules`/`monitor.bluez.rules` with a
`node.name` regex match + `update-props`, confirmed against a system test before
committing — the officially documented example config only lists `node.nick`/
`node.description` as renamable, not `node.name` itself, so this was verified
empirically rather than assumed). But testing it live surfaced a real, disruptive
side effect: restarting WirePlumber to apply a rename briefly invalidated the
already-loaded echo-cancel module's `source_master` reference (which was still
pointing at the pre-rename name), so it silently fell back to the **Bluetooth mic**
instead of the USB mic — and because the Bluetooth mic role requires bidirectional
audio, this forced the speaker from A2DP (stereo, 48kHz) down to HSP/HFP
(mono, 16kHz), audibly degrading quality. It happened twice, on two separate restarts.

Root cause traced further: this always happens on any full service restart because
the machine's **default source has been the Bluetooth mic since before this project
started** (visible all the way back in the S0 baseline dump). Every restart re-opens
whatever the default source is, and if that's the Bluetooth mic, BlueZ negotiates
HSP/HFP regardless of what any app actually wants. This was originally scoped as S5,
a separate unrelated cleanup item — it isn't separate. It's a live cause of S3's
unreliability, so it was fixed now: `wpctl set-default` to `usb_condenser_mic`, plus
a Bluetooth disconnect/reconnect cycle to force A2DP renegotiation back.

After both fixes, a full `pipewire`+`pipewire-pulse`+`wireplumber` restart resolves
`usb_condenser_mic` → `echo-cancel-capture` and `echo-cancel-playback` →
`bt_desktop_speaker` correctly, A2DP stays stereo, and `scripts/verify-aec.sh` passes
at 17.0dB. (Numbers have varied run to run through this session — 28.9dB, 26.2dB,
14.6dB, 17.0dB — likely the AEC filter's adaptive convergence state after repeated
reloads, or minor acoustic/volume differences between runs; all comfortably clear the
10dB pass threshold, but this variability is noted honestly rather than picking the
best number to report.)

Install: copy `wireplumber.conf.d/*.conf` into `~/.config/wireplumber/wireplumber.conf.d/`,
update `pipewire-pulse.conf.d/10-echo-cancel.conf`'s `source_master`/`sink_master` to
the stable names (already done in this repo's copy), then restart all three services.
If your default source is currently a Bluetooth mic, fix that too (`wpctl set-default`)
or you'll hit the same regression documented above.

### S2 notes — persisted config, one deviation from the original plan

The plan originally called for the native `libpipewire-module-echo-cancel` via
`~/.config/pipewire/pipewire.conf.d/`. Instead, S2 persists the **pulse-compat**
module (`module-echo-cancel` via `pipewire-pulse`'s `pulse.cmd` mechanism, plain
`key=value` args) — because that's the exact form S1 already validated working, and
switching to an untested config format at persistence time would have reintroduced
the same class of risk S1 just spent time debugging. `pipewire-pulse.conf.d` supports
the same `pulse.cmd = [ { cmd = "load-module" args = "..." } ]` syntax as
PulseAudio's old `default.pa`, documented in `/usr/share/pipewire/pipewire-pulse.conf`.

Install: copy `pipewire-pulse.conf.d/10-echo-cancel.conf` into
`~/.config/pipewire/pipewire-pulse.conf.d/`, then
`systemctl --user restart pipewire pipewire-pulse wireplumber`.

Verified: a full restart of all three services (closest local approximation to a real
logout/login) brought back `aec_sink`/`aec_source` and the default-sink selection with
zero manual commands. `scripts/verify-aec.sh` re-run afterward: **26.2dB reduction**,
consistent with S1's 28.9dB.

One transient found and noted, not chased further: restarting `pipewire-pulse` alone
(without also restarting `pipewire`/`wireplumber`) caused the default sink to
temporarily revert to the wired headphones before being reset manually — a full
three-service restart didn't have this issue. Not investigated further since it
doesn't affect the real reboot/login path this project targets.

At the time, node names were still hardcoded to the raw hardware identifiers — that
was fixed in S3 (above).

### S1 notes — two real bugs found and fixed along the way

The first live-loaded module used `pactl load-module module-echo-cancel` with
`source_properties`/`sink_properties` values containing embedded single quotes
(`device.description='...'`). That corrupted pactl's own argument tokenization for
every property *after* the broken one — `sink_name` silently fell back to a default,
and worse, **`source_master` silently fell back to whatever the default source was at
load time**, which was the Bluetooth headset mic (`bluez_input`), not the real USB
condenser mic. Confirmed via `pw-link -l`: `echo-cancel-capture` was wired to
`bluez_input`, not `alsa_input.usb-DCMT_...`.

This meant the very first "it works" measurement (aec_source RMS -71dB) wasn't
measuring anything real — it was reading an mostly-silent Bluetooth earpiece mic, not
an echo-cancelled signal from the actual recording mic. It also meant a live listening
test (via OBS, which was separately still wired directly to the raw USB mic and never
touched `aec_source` at all) correctly showed almost no improvement — because the
module was never actually listening to the right microphone.

Fixed by dropping the property strings entirely (cosmetic only) and reloading with
plain `key=value` args. Confirmed via `pw-link -l` that `echo-cancel-capture` now
pulls from the real USB mic and `echo-cancel-playback`/its rename forwards to the real
Bluetooth sink. Re-measured with `scripts/verify-aec.sh`: **28.9dB reduction** (raw mic
-25.9dB vs. aec_source -54.8dB during identical tone playback), and the script
correctly **fails** (-1.0dB delta) when pointed at the raw mic on both sides — proof
it discriminates rather than always passing.

Lesson: never pass free-form quoted strings as `pactl load-module` argument values —
use plain `key=value` args. (S2 kept the pulse-compat module for exactly this reason:
once the quoted properties were dropped, nothing needed the native JSON config form.)
