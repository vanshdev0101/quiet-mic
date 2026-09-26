# pw-aec

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

1. `pipewire.conf.d/10-echo-cancel.conf` — loads `module-echo-cancel` against fixed
   node targets.
2. `wireplumber.conf.d/51-alsa-usb-mic.conf`, `51-bluez-desktop.conf` — pin stable
   `node.name`s to the USB mic and Bluetooth sink by hardware identity (USB serial,
   Bluetooth MAC), so the AEC config's targets don't rot after a reboot or reconnect.
3. `scripts/verify-aec.sh` — plays a known tone and asserts the AEC source is
   measurably quieter than the raw mic during playback; fails on the raw/unpatched
   setup, passes on the fixed one.

## Status

S0 (baseline) complete — bleed reproduced and measured. See `PLAN.md` for the full
staged build (S1: live spike, S2: persist config, S3: stable node names, S4: verify
script, S5: unrelated default-source fix, S6: package). No `module-echo-cancel` config
has been loaded or written yet.
