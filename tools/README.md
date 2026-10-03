# tools/

Build-time generators and verification/analysis helpers. Nothing here is needed to
compile the core; `rtl/tables/*.hex` and `releases/*.mra` are committed outputs.

## Generators (rerun when their inputs change)
- `gen_tables.py` - sprite X-scale and palette lookup tables -> `rtl/tables/*.hex` (`--check` verifies invariants).
- `gen_mra.py` - writes the two `releases/*.mra` files (Turbo, Buck Rogers not encrypted).
- `gen_playercar_ic17_tables.py`, `gen_playercar_step_lut.py` - MC3340 gain and player-car pitch tables used by `rtl/audio/turbo_playercar_chan.sv`.
- `check_qsf_sources.py` - checks `files.qip` against the files on disk.

## Reference models (Python mirrors of the RTL, used to choose fixed-point constants)
- `playercar_*.py` - player-car oscillator, VCA, divider and SLF reference models and the tests that compare them with cabinet recordings.
- `skid_fm_mirror.py` - bit-style reference of the skid IC1 -> 555 FM chain.
- `ambulance_reference.py`, `othercars_*.py`, `comparator_delay_study.py`.

## Cabinet-recording analysis
- `analyze_*.py`, `compare_playercar_evidence.py`, `track_playercar_warble.py`, `measure_*.py`, `speaker_guess_listen.py`.

## MAME probes
- `mame/*.lua` - headless MAME tap/dump scripts used to cross-check CPU, video and sound-trigger behaviour.

## Timing
- `timequest_*.tcl` - report worst paths from a finished Quartus compile.

## Simulation
See `../sim/Makefile`; `sim/run_audio_scenario.sh <N>` builds the Turbo audio testbench and runs one scenario.
