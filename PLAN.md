# PipeWire Acoustic Echo Cancellation (AEC) project

## Context

You wanted a project a senior engineer would respect — something that solves a real
problem, not another rice tweak. The trigger case is concrete and yours: recording with
OBS while your desktop audio (currently a Bluetooth speaker) bleeds into your USB
condenser mic, with no clean fix on PipeWire the way Windows/macOS have built-in AEC.

A read-only survey of this machine confirmed the shape of the real gap:

- `libpipewire-module-echo-cancel.so` **already ships** with the installed `pipewire`
  package (1.6.8) — the DSP itself (webrtc-audio-processing, both v1 and v2) is already
  installed. **No new code or dependency is needed for the hard part.**
- Nobody has published a config that actually works long-term: `/usr/share/pipewire/filter-chain/`
  ships example configs for rnnoise/dolby/upmix but **not** echo-cancel, and no user-level
  PipeWire/WirePlumber config exists on this machine yet.
- The real, unsolved problem is that raw `module-echo-cancel` configs (the kind found in
  forum posts) hardcode today's PipeWire node names, which are **not stable** across
  reboots/reconnects — especially for a Bluetooth sink (profile-dependent naming) and a
  USB mic (fallback-suffix naming). A config that works today silently breaks after the
  next boot.
- Current real graph: desktop sink `bluez_output.51_65_E6_58_40_2C.1`; target mic
  `alsa_input.usb-DCMT_Technology_USB_Condenser_Microphone_214b206000000178-00.mono-fallback`.
  Separately noticed (not the core project): the *default* source right now is the
  Bluetooth mic, not the USB mic.
- No EasyEffects/NoiseTorch installed — no simpler existing tool sidesteps this.

So the actual project isn't "write echo cancellation" — it's **make PipeWire's existing
AEC module survive reboots and prove it actually works**, packaged so someone else could
adopt it. Ladder call: config + one verification script, no custom DSP, no install
framework.

## Recommended approach — staged, with a checkpoint before each stage

Repo: new `~/git/pw-aec/` (sibling to `~/git/qs-popup-scope`, same repo-per-problem
convention: `README.md` with the problem statement + evidence, `PLAN.md` mirroring this
file). Work happens directly in this repo's tracked config files, not scattered live
edits — copy the same "edit, test live, then commit" discipline used for `qs-popup-scope`.

**S0 — Baseline capture.** Record `pactl`/`wpctl` state and one "before" recording (play a
known clip through the Bluetooth sink while recording the raw USB mic) into `evidence/before.wav`.
Checkpoint: confirm the recording audibly contains the bleed — if it doesn't reproduce,
nothing downstream has anything to prove.

**S1 — Minimal spike, session-scoped, hardcoded names.** Load `module-echo-cancel` via
`pw-cli`/`wpctl` at runtime (not written to disk yet) with `capture.props.target.object`
pinned to today's real USB mic node and `playback.props.target.object` pinned to today's
real Bluetooth sink node. Confirm empirically (this session found the exact topology
ambiguous from the man page alone) whether apps should point at the new AEC sink directly
or whether the module forwards to the real sink automatically. Checkpoint: you personally
confirm "yes, audibly less echo" before anything persists across a restart.

**S2 — Persist to `~/.config/pipewire/pipewire.conf.d/10-echo-cancel.conf`**, exactly
matching what S1 proved, still with today's hardcoded node names. Checkpoint: confirm
`systemctl --user restart pipewire pipewire-pulse wireplumber` brings the AEC sink/source
back with zero manual commands, and system audio isn't otherwise broken.

**S3 — Stable node names.** Two WirePlumber rule files
(`~/.config/wireplumber/wireplumber.conf.d/51-alsa-usb-mic.conf`,
`51-bluez-desktop.conf`) that rename the USB mic and Bluetooth sink to fixed
`node.name`s keyed on hardware identity (USB serial substring, Bluetooth MAC) rather than
today's volatile computed names, matched via `device.name` regex on the parent card (not
the profile-suffixed node name). Then repoint S2's config at the new stable names.
Checkpoint: this is the highest-risk stage — a wrong regex silently orphans the AEC
module. Verify via `wpctl status` before moving on, and ideally test across an actual
unplug/replug or Bluetooth reconnect.

**S4 — Verification script**, `~/git/pw-aec/scripts/verify-aec.sh`: play a fixed test
tone through the Bluetooth sink, record simultaneously from the raw mic and from the new
AEC source, compare RMS-during-playback via `sox stat` (already-likely-installed, no new
dependency; fall back to `ffmpeg -af astats` if not present), and assert the AEC source is
at least N dB quieter — exit non-zero otherwise. Prove it actually discriminates by running
it once against the raw mic / unloaded module (must fail) and once against the working
setup (must pass). This is the "test fails on the unpatched setup" bar from your OSS
standards, applied to your own project.

**S5 — Fix the default-source mismatch**, as an explicitly separate, small change: current
default source is the Bluetooth mic, not the USB mic. Try `wpctl set-default` first (WirePlumber
persists it in `~/.local/state/wireplumber/`); only add a config rule if that doesn't
survive reboot. Committed separately from the AEC work so it's never conflated with it.

**S6 — Package for reuse.** Finalize `~/git/pw-aec/` layout:
```
README.md                                  # problem, evidence, how it works
PLAN.md                                     # this plan
pipewire.conf.d/10-echo-cancel.conf
wireplumber.conf.d/51-alsa-usb-mic.conf
wireplumber.conf.d/51-bluez-desktop.conf
scripts/verify-aec.sh
scripts/install.sh                          # a handful of `ln -sf` lines, nothing more
evidence/before.wav
evidence/after.wav
```
`install.sh` stays a symlink script, not a package manager — if it grows past that, cut
it back. README written for a stranger: the trigger scenario, why hardcoded configs found
online don't survive reboots (the actual gap this closes), and the verify script's real
before/after numbers as evidence rather than a claim.

## Rollback safety (applies from S2 onward)

Every config change is spiked live via `pw-cli`/`wpctl` before being written to a
conf.d file — never write untested config straight to disk. Rollback for any stage is
`rm`/`mv .disabled` the relevant conf.d file plus a `systemctl --user restart pipewire
pipewire-pulse wireplumber` — these are additive drop-ins, not edits to shipped files, so
nothing destructive to undo.

## Critical files

- `~/.config/pipewire/pipewire.conf.d/10-echo-cancel.conf`
- `~/.config/wireplumber/wireplumber.conf.d/51-alsa-usb-mic.conf`
- `~/.config/wireplumber/wireplumber.conf.d/51-bluez-desktop.conf`
- `~/git/pw-aec/scripts/verify-aec.sh`
- `~/git/pw-aec/README.md`, `~/git/pw-aec/PLAN.md`

## Verification (end-to-end)

1. `verify-aec.sh` passes against the finished S3 setup and fails against the raw
   mic/unloaded-module case — this is the real proof, not "sounds fine."
2. A full logout/login (or `systemctl --user restart pipewire pipewire-pulse wireplumber`)
   restores AEC automatically with no manual `pw-cli` calls.
3. Unplug/replug the USB mic (or a Bluetooth reconnect) and confirm the stable node names
   from S3 hold and AEC keeps targeting the right devices — this is the specific failure
   mode raw online configs don't survive, and the one this project is actually for.
S0: done - bleed reproduced, 11dB rise measured (see evidence/)
S1: verified live (see README for the two bugs found: pactl quoting + wrong source_master)
S4 (verify-aec.sh) built early: PASS at 28.9dB delta on real setup, FAIL at -1.0dB on raw-vs-raw sanity check
S2: done via pipewire-pulse.conf.d/pulse.cmd (not native pipewire.conf.d as originally
planned -- persists the exact form S1 validated). Survives full pipewire+pipewire-pulse+
wireplumber restart with zero manual commands; verify-aec.sh re-passed at 26.2dB. Next: S3
(stable node names via WirePlumber rules).
