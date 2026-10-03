#!/usr/bin/env bash
# usage: build_and_run.sh OUT_DIR SCEN [SCEN ...]   (builds the audio sim, then runs the scenarios in parallel)
cd "$(dirname "$0")" || exit 1
OUT="$1"; shift
mkdir -p "$OUT"
rm -f "$OUT"/build.log "$OUT"/run*.log
make audio > "$OUT/build.log" 2>&1
echo "BUILD_RC=$?" >> "$OUT/build.log"
grep -q "BUILD_RC=0" "$OUT/build.log" || exit 1
for s in "$@"; do
    ( TURBO_AUDIO_OUT_DIR="$OUT" ./obj_dir_audio/Vaudio_top "$s" > "$OUT/run$s.log" 2>&1; echo "RUN_RC=$?" >> "$OUT/run$s.log" ) &
done
wait
