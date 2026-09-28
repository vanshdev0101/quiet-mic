#!/usr/bin/env bash
# Symlinks this repo's config into place and restarts the affected services.
# That's it -- no package manager, no daemon. If you need more than this,
# something has gone wrong with the scope of this project.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$(pwd)"

mkdir -p ~/.config/pipewire/pipewire-pulse.conf.d
mkdir -p ~/.config/wireplumber/wireplumber.conf.d

ln -sf "$REPO/pipewire-pulse.conf.d/10-echo-cancel.conf" \
    ~/.config/pipewire/pipewire-pulse.conf.d/10-echo-cancel.conf
ln -sf "$REPO/wireplumber.conf.d/51-alsa-usb-mic.conf" \
    ~/.config/wireplumber/wireplumber.conf.d/51-alsa-usb-mic.conf
ln -sf "$REPO/wireplumber.conf.d/51-bluez-desktop.conf" \
    ~/.config/wireplumber/wireplumber.conf.d/51-bluez-desktop.conf

echo "Symlinked. These configs target THIS machine's specific USB mic serial and"
echo "Bluetooth MAC -- edit the three files in $REPO before installing on a"
echo "different machine (see README.md for what to change)."
echo
echo "Restarting pipewire, pipewire-pulse, and wireplumber to apply..."
systemctl --user restart pipewire pipewire-pulse wireplumber
sleep 2

echo
echo "Next steps (one-time, not automated by this script):"
echo "  1. Set aec_sink as your default output:"
echo "       wpctl set-default \$(wpctl status | grep -m1 aec_sink | grep -oE '^\\s*[0-9]+')"
echo "  2. If your default source is a Bluetooth mic, switch it to the USB mic:"
echo "       wpctl set-default \$(wpctl status | grep -m1 'USB Condenser Mic' | grep -oE '^\\s*[0-9]+')"
echo "     (leaving a Bluetooth mic as default forces HSP/HFP and breaks A2DP -- see README)"
echo "  3. Point your recording app (OBS, etc.) at the 'Echo-Cancel Source' /"
echo "     aec_source device instead of the raw mic."
echo "  4. Verify: ./scripts/verify-aec.sh"
