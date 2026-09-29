#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Raw devices, deliberately bypassing AEC. Names are the stable ones from
# wireplumber.conf.d/ (S0 originally ran against the pre-rename raw node names).
MIC="${MIC:-usb_condenser_mic}"
SINK="${SINK:-bt_desktop_speaker}"

timeout 6 parecord --device="$MIC" --file-format=wav --rate=48000 --channels=1 evidence/before.wav &
REC_PID=$!
sleep 0.5
paplay --device="$SINK" evidence/tone.wav
wait "$REC_PID" 2>/dev/null || true
