#!/bin/sh
# Build the Turbo audio testbench and run one scenario.
#   usage: sim/run_audio_scenario.sh <scenario-number> [output-dir]
# Run from anywhere; WAV/CSV outputs land in sim/out/<output-dir> (default audio_s<N>).
cd "$(dirname "$0")" || exit 1
n="$1"; out="${2:-audio_s$n}"
[ -n "$n" ] || { echo "usage: $0 <scenario-number> [output-dir]"; exit 1; }
make audio || exit 1
mkdir -p "out/$out"
TURBO_AUDIO_OUT_DIR="out/$out" ./obj_dir_audio/Vaudio_top "$n"
