#!/usr/bin/env bash
# Run scenarios 34, 29, 30 in parallel into an output folder (default out/audio_ic17_20260929).
cd "$(dirname "$0")" || exit 1
OUT="${1:-out/audio_ic17_20260929}"
mkdir -p "$OUT"
rm -f "$OUT"/run.log
for s in 34 29 30; do
    ( TURBO_AUDIO_OUT_DIR="$OUT" ./obj_dir_audio/Vaudio_top "$s" > "$OUT/run$s.log" 2>&1; echo "RUN_RC=$?" >> "$OUT/run$s.log" ) &
done
wait
