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

## Evidence

`evidence/baseline-status.txt` — full `wpctl status` / `pactl` dump of the real audio
graph on the target machine before any fix.

`evidence/before.wav` — a 440Hz test tone (`evidence/tone.wav`) played through the
Bluetooth sink while recording from the raw USB mic. Measured via `ffmpeg -af astats`:

| | RMS level |
|---|---|
| Silence (mic only, nothing playing) | -24.5 dB |
| During playback (raw mic, no AEC) | -13.8 dB, peak -0.65 dB (near clipping) |

An ~11 dB rise during playback, on a mic with a hot preamp, confirms the bleed is real
and severe enough to matter — not a marginal effect.

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
3. `scripts/verify-aec.sh` — plays a known tone and asserts the AEC source is
   measurably quieter than the raw mic during playback; fails on the raw/unpatched
   setup, passes on the fixed one.

## Status

S0-S3 complete; verification script (S4) built early since manual by-ear testing
doesn't scale. S5 (default-source fix) also pulled forward — see S3 notes for why.
See `PLAN.md` for the full staged build.

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

Still open: node names are still hardcoded to today's real hardware identifiers (S3
not done), and OBS/any app must still explicitly select `aec_sink`/`aec_source` — this
config doesn't retroactively fix an app already pointed at the raw devices.

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

Lesson for S2/S3: never pass free-form quoted strings as `pactl load-module` argument
values — use plain `key=value` args, and put anything needing quoting/nesting into the
native `pipewire.conf.d` JSON form instead (S2), where it's parsed properly.
