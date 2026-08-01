# Arcade-SegaVCO

A MiSTer FPGA core for Sega's "Z80-3D" arcade board family (Buck Rogers:
Planet of Zoom, Turbo, Subroc-3D) — three Z80-based games built around a
shared sprite engine and an analog VCO-driven scaling/road-generator front
end, targeted at the DE10-Nano (Cyclone V).

## Status

**Known working**
- **Buck Rogers: Planet of Zoom** (`buckrogn`, the unencrypted ROM set) —
  main CPU, sub CPU, video (tilemap, sprite engine, starfield/bitmap
  background, priority mixer), controls/DIP switches, and a fully discrete
  (non-sample-based) model of the sound board: noise generator, six sound
  channels (ALARM, EXP, FIRE, HIT, REBOUND, SHIP) and the LA4460 output
  stage, each modeled from the schematic as fixed-point DSP rather than
  approximated with WAV playback.

**Not yet implemented**
- **`buckrog`** (the encrypted ROM set) — needs the `315-5014` CPU opcode
  decryption; not started.
- **Turbo** — road generator, collision detection, and its own bit-serial
  mixer are a materially different video pipeline from Buck Rogers'; its
  sound board is a separate discrete circuit. Neither is implemented yet.
- **Subroc-3D** — out of scope for now; it's an active-shutter
  stereoscopic game with no practical way to test it on real hardware.

This project is still under active development — please report issues.

## Credits

- **[MAME](https://www.mamedev.org/)** — reference driver source
  (`turbo.cpp`/`turbo_v.cpp`/`turbo_a.cpp`/`resnet.h`) used throughout for
  memory maps, table derivations, and behavioral cross-checking against
  real hardware.
- **Sorgelig (Alexey Melnikov)** — the [MiSTer](https://github.com/MiSTer-devel)
  framework this core is built on (`sys/`), and the broader MiSTer FPGA
  project.
- **Guy Hutchison / Daniel Wallner** — the TV80 Z80 core (`rtl/tv80/`),
  ported from Daniel Wallner's original T80 VHDL core.
- Additional `sys/` framework contributors credited in-file: Till Harbaum,
  Ludvig Strigeus, bellwood420.

## License

[GPL-3.0-or-later](LICENSE), matching the MiSTer framework (`sys/`) this
core builds on.
