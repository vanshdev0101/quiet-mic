#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

MIC=alsa_input.usb-DCMT_Technology_USB_Condenser_Microphone_214b206000000178-00.mono-fallback
SINK=bluez_output.51_65_E6_58_40_2C.1

timeout 6 parecord --device="$MIC" --file-format=wav --rate=48000 --channels=1 evidence/before.wav &
REC_PID=$!
sleep 0.5
paplay --device="$SINK" evidence/tone.wav
wait "$REC_PID" 2>/dev/null || true
