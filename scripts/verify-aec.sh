#!/usr/bin/env bash
# Plays a known tone through the desktop sink, records simultaneously from the
# raw mic and the echo-cancelled source, and asserts the AEC path is at least
# MIN_DB_DELTA quieter during playback. Exits non-zero if not — this is meant
# to fail on a broken/unloaded AEC setup, not just print numbers.
set -euo pipefail
cd "$(dirname "$0")/.."

RAW_MIC="${RAW_MIC:-alsa_input.usb-DCMT_Technology_USB_Condenser_Microphone_214b206000000178-00.mono-fallback}"
AEC_SOURCE="${AEC_SOURCE:-aec_source}"
PLAYBACK_SINK="${PLAYBACK_SINK:-aec_sink}"
MIN_DB_DELTA="${MIN_DB_DELTA:-10}"
TONE="evidence/tone.wav"
DURATION=5

if [[ ! -f "$TONE" ]]; then
    echo "generating $TONE"
    ffmpeg -y -f lavfi -i "sine=frequency=440:duration=$DURATION" -ar 48000 -ac 2 "$TONE" >/dev/null 2>&1
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

rms_db() {
    ffmpeg -i "$1" -af astats -f null - 2>&1 | grep -m1 "RMS level dB" | awk '{print $NF}'
}

echo "== recording raw mic ($RAW_MIC) =="
timeout $((DURATION + 2)) parecord --device="$RAW_MIC" --file-format=wav --rate=48000 --channels=1 "$tmpdir/raw.wav" &
RAW_PID=$!
sleep 0.5
paplay --device="$PLAYBACK_SINK" "$TONE"
wait "$RAW_PID" 2>/dev/null || true

echo "== recording AEC source ($AEC_SOURCE) =="
timeout $((DURATION + 2)) parecord --device="$AEC_SOURCE" --file-format=wav --rate=48000 --channels=1 "$tmpdir/aec.wav" &
AEC_PID=$!
sleep 0.5
paplay --device="$PLAYBACK_SINK" "$TONE"
wait "$AEC_PID" 2>/dev/null || true

RAW_DB=$(rms_db "$tmpdir/raw.wav")
AEC_DB=$(rms_db "$tmpdir/aec.wav")
DELTA=$(awk -v a="$RAW_DB" -v b="$AEC_DB" 'BEGIN{printf "%.1f", a-b}')

echo
echo "raw mic RMS:  ${RAW_DB} dB"
echo "aec source RMS: ${AEC_DB} dB"
echo "delta: ${DELTA} dB (need >= ${MIN_DB_DELTA})"

if awk -v d="$DELTA" -v m="$MIN_DB_DELTA" 'BEGIN{exit !(d>=m)}'; then
    echo "PASS: AEC source is ${DELTA}dB quieter than raw mic during playback"
    exit 0
else
    echo "FAIL: AEC source only ${DELTA}dB quieter than raw mic (threshold ${MIN_DB_DELTA}dB)"
    exit 1
fi
