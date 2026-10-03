#!/usr/bin/env bash
set +e
mkdir -p out/audio

run_one() {
    local scen="$1"
    TURBO_AUDIO_OUT_DIR=out/audio ./obj_dir_audio/Vaudio_top "$scen" >"out/audio/run$scen.log" 2>&1
    local rc="$?"
    printf '%s\n' "$rc" >"out/audio/run$scen.status"
    return "$rc"
}

if [ "$#" -eq 0 ]; then
    set -- 29 30 33 34
fi
pids=""
scenarios=""
for scen in "$@"; do
    run_one "$scen" &
    pids="$pids $!"
    scenarios="$scenarios $scen"
done

status=0
for pid in $pids; do
    wait "$pid" || status=1
done

printf 'RUN_STATUS=%s\n' "$status"
for scen in $scenarios; do
    f="out/audio/run$scen.status"
    printf '%s=' "$f"
    cat "$f"
done
exit "$status"
