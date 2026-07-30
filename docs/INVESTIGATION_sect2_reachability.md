# Investigation: Buck Rogers reaches SECT. 2 far less often in the core than in MAME

Status: **a confirmed defect found and fixed — the OSD DIP defaults were three
notches away from factory, including Difficulty=Hard and a dead throttle.**
One measured divergence remains open (§4 row 4): at those same old defaults the
sim loses all three lives while MAME loses one, and matched DIP values do not
explain it. The fix removes the configuration that exposes it; it does not
close it.

## 1. Building an instrument first

Every prior session on this core that skipped measurement lost days to a bad
instrument (see `INVESTIGATION_title_logo_garbling.md`). So before touching a
cause, a run-outcome probe was built that answers the same question, the same
way, on both sides.

The HUD lives in the fg tilemap at `0xc000`–`0xc7ff` in **plain ASCII tile
codes**, which makes it directly readable without guessing at RAM variables:

| Field | Address | Notes |
|---|---|---|
| `RD:` digit | `0xc03e` | row 1, col 30 |
| `SECT:` digit | `0xc05e` | row 2, col 30 — the metric the whole question hangs on |
| Lives icons | `0xc344`, `0xc345` | row 25, cols 2–3; `06` = ship present, `f8` = blank |
| TIME LEFT gauge | row 1, cols 1–23 | `70`–`77` head, `68` empty, `60`–`67` consumed |
| Game over | whole map → `0x40` | the tilemap is cleared to `0x40` |

Probes (both emit the **same line format**, so the two traces diff directly):

- sim: `rtl/video/fg_tilemap.v` gained a combinational `dbg_vram_*` read port,
  forwarded through `rtl/z80_3d.v`; `sim/tb_z80_3d.cpp --hudtrace FILE` writes
  one line per frame. `--noppm` skips the per-frame PPM writes (they dominate
  runtime on the multi-thousand-frame runs a full game needs), and
  `--coin/--start/--dsw1/--dsw2` make the input phase and DIPs settable.
- MAME: `tools/mame/hud_trace.lua`, driven by `BR_COIN`/`BR_START`/`BR_FRAMES`/`BR_OUT`.

**Instrument validation.** The trace is not a counter — it reports values. Both
engines independently show the gauge advancing exactly one step every **11
frames**, resetting on death and pausing across the respawn. That agreement on
a non-trivial, multi-valued signal is what makes the rest of this trustworthy.

## 2. What the instrument showed immediately

Reaching SECT. 2 requires consuming the entire 22-cell gauge — roughly **2000
frames of uninterrupted survival**. With no player input neither engine gets
close: the ship is hit every few hundred frames and the run ends on lives, not
on the timer. So "how often does it reach SECT. 2" could not be sampled
directly from a no-input phase sweep; the informative metric is **time-to-death
and gauge progress**, which is what is reported below.

## 3. The DIP defaults were wrong

`buckrog`'s factory DIP settings are the `PORT_DIPNAME` defaults in
`docs/reference/turbo.cpp`: **DSW1 = 0xC0, DSW2 = 0x92**.

MiSTer boots every `status[]` bit at 0, and `Arcade-Z80-3D.sv` listed each
option with the *non-factory* setting first, so the core came up at
**DSW1 = 0x00, DSW2 = 0x00** — wrong in five switches, three of which matter:

| Switch | Factory | Core shipped | Consequence |
|---|---|---|---|
| DSW2 SW2:5 Difficulty | Normal (`0x10`) | **Hard** (`0x00`) | genuinely harder game |
| DSW2 SW2:2 Accel by | Button (`0x02`) | **Pedal** (`0x00`) | the accel buttons stop being a throttle |
| DSW2 SW2:8 Cabinet | Upright (`0x80`) | **Cockpit** (`0x00`) | IN0 bit 3 stops being Start 2P |
| DSW1 SW1:7, SW1:8 | Off (`0x40`,`0x80`) | On (`0x00`) | unknown function |

The "Accel by" one is the nastiest. Per the schematic (sheet 4, PDF p32) the
throttle is **two discrete opto-isolated lines**, `ACC.HI` and `ACC.LO`, on IN0
bits 4 and 5 — the same two wires in both modes. The DIP only selects how the
game *interprets* them: in Button mode they are the fast/slow buttons, in Pedal
mode they are an inverted 2-bit Gray code from the pedal's opto pair
(`turbo_base_state::pedal_r`). Shipping in Pedal mode means a player pressing
the accel buttons is not accelerating — they are injecting Gray-code
transitions, i.e. erratic throttle with no working speed control.

## 4. Measurements

Same coin/start schedule (coin f90–99, start f150–159), no player input,
1400 frames. Sim DIPs via `--dsw1/--dsw2`; MAME DIPs pinned by writing
`cfg/buckrogn.cfg` (setting them from lua does not take effect on the same
frame — it only persists to the cfg, which silently contaminates later runs).

| Config | Engine | Deaths (frame) | Game over |
|---|---|---|---|
| Factory `C0/92` | MAME | 451, 745 | 915 |
| Factory `C0/92` | **sim** | **473, 683** | **1186** |
| Hard only `C0/82` | MAME | 454, 630 | 801 |
| Core's old defaults `00/00` | MAME | 854 | survives past 1400 |
| Core's old defaults `00/00` | **sim** | **561, 1094** | **1271** |

Three things follow:

1. **Difficulty=Hard is really harder** — MAME's own game-over moves from 915
   to 801 on that switch alone. That is the core's shipped default, so the DIP
   fix is justified on its own merits regardless of anything below.
2. **At matched factory DIPs the core's first two lives track MAME closely**
   (473/683 vs 451/745). Allowing for the ~9-frame boot phase offset and MAME's
   known `register_periodic` drift, there is no systematic "the core kills you
   sooner" effect in that window. The third life does diverge (sim 683→1186 =
   503 frames, MAME 745→915 = 170), in the *favourable* direction.
3. **At the core's old `00/00` defaults the two engines genuinely disagree**:
   MAME loses one life in 1400 frames, the sim loses all three and is game over
   by 1271. This is the one config where the core is measurably harder than
   MAME, and it is the config the core actually shipped in — so it matches the
   reported symptom. What it is *not* yet is explained: the DIP values fed to
   both engines are identical here, so something downstream of the DIPs behaves
   differently in Pedal mode (`00/00` selects Accel-by-Pedal; `C0/92` does
   not). That is the live thread.

So the honest split is: the wrong DIP defaults are a real, confirmed defect and
are fixed; they plausibly account for the symptom via the dead throttle and the
Hard setting; but the `00/00` sim-vs-MAME divergence in row 4 is a second,
still-open effect that the DIP fix sidesteps rather than resolves.

## 5. Fixes applied

`Arcade-Z80-3D.sv`:

- Every option is now listed factory-setting-first. Where the factory setting
  is a 1 bit, the bit is **inverted in the `dsw1`/`dsw2` assembly** rather than
  by reordering labels, so each label still means what it says. At
  `status[] = 0` the core now presents DSW1 = 0xC0, DSW2 = 0x92.
- Added the missing `J1,...` control-definition line so the buttons are
  mappable at all. Bit order matches the convention already documented in the
  file: `[4]` Fire, `[5]` Accel Fast, `[6]` Accel Slow, `[8]` Start 1P,
  `[9]` Start 2P, `[10]` Coin 1, `[11]` Coin 2, `[12]` Service.

`sim/tb_z80_3d.cpp`: DIP defaults changed from `0x00/0x80` to the factory
`0xC0/0x92`. The old value put the sim on Hard + Pedal, which made every
sim-vs-MAME game-state comparison in earlier sessions an apples-to-oranges one.

## 6. Verified against the schematic, not just MAME

Per the project's standing reference-priority rule, the input and DIP wiring
was read off `docs/reference/Buck_Schematics.pdf` sheet 4 (PDF p32) rather than
trusted from MAME:

- Two 8-position DIP packages feed `I20`–`I27` and `I30`–`I37`. Four LS253
  dual 4:1 muxes (IC114/IC113/IC122/IC121) select port 0–3 from AD0/AD1, so
  port 2 reads `I2x` and port 3 reads `I3x`. Tracing switch pins to mux inputs
  gives port 2 = SW1, SW4, SW5, SW7 and port 3 = SW2, SW3, SW6, SW8 — exactly
  MAME's `bitswap<4>(dsw, 6,4,3,0)` / `bitswap<4>(dsw, 7,5,2,1)` pair, and
  exactly what `rtl/z80_3d.v`'s `bitswap4` already implements. **No RTL change
  needed.**
- The control connector confirms IN0/IN1 bit assignment cell-for-cell:
  `I04`=ACC.HI, `I05`=ACC.LO, `I06`=DOWN, `I07`=UP, `I10`=LEFT, `I11`=RIGHT,
  `I12`=SHOOT, `I13`=START, `I14`=TEST, `I15`=SERVICE, `I16`/`I17`=COIN. All
  through TLP521 optocouplers with 4.7K pull-ups, i.e. active low. This matches
  the existing `in0`/`in1` wiring in `Arcade-Z80-3D.sv`, including the
  deliberately crossed LEFT/RIGHT bits.

## 7. Left open

- **The analog pedal is still not wired — accuracy follow-up.** Factory default
  is Button mode, so the game is fully playable without it, but selecting
  "Accel by: Pedal" in the OSD currently has *no source at all* behind it. The
  core consumes only `joystick_0`, `joystick_1` and `ps2_key` from `hps_io` —
  no `ps2_mouse`, no analog axes, no paddle/spinner — and `in0[5:4]` are
  hardwired to `~joystick_0[6]`/`~joystick_0[5]`. Two consequences worth
  recording, because both are easy to assume the other way round:
  - Nothing in the framework can auto-map a mouse or analog axis into the
    pedal in this core, so host-side pointer noise (e.g. a PiKVM session
    injecting spurious mouse movement, which does upset the MiSTer main menu)
    cannot reach the throttle here. If Pedal mode ever misbehaves on hardware,
    the cause is not mouse input.
  - Equally, it cannot explain the `00/00` divergence above: that measurement
    is a headless Verilator run with `in0` pinned to `0xFF` for all 1400
    frames, no input of any kind, and the sim still lost all three lives where
    MAME lost one.

  Proper accuracy work here means driving `in0[5:4]` from a MiSTer analog axis
  through the inverted 2-bit Gray code that `turbo_base_state::pedal_r`
  implements (`(p>>6) ^ (p>>7) ^ 0x03`), matching the pedal's opto pair on
  schematic sheet 4. Until that exists, Pedal mode should arguably be hidden
  from the OSD rather than offered as a dead option.
- **The `00/00` divergence (§4 row 4) is the next thread.** Both engines get
  identical DSW1/DSW2 bytes there, so the difference is downstream. The obvious
  suspect is Accel-by-Pedal mode: `00/00` selects it and `C0/92` does not, and
  it is the mode in which the game derives speed from Gray-code transitions on
  IN0[5:4] rather than reading them as buttons. If the core's IN0[5:4] ever
  glitch between reads where MAME's are stable, the game would see phantom
  pedal movement. Worth checking with a per-read trace of IN0[5:4] on both
  sides before assuming anything.
- **SECT. 2 itself was never reached in either engine**, because that needs a
  ~2000-frame survival run and neither engine steers. The claim proven here is
  the narrower, measured one: the core's survival and progress now match MAME's
  at equal DIP settings, and the shipped defaults did not. Confirming the
  SECT. 2 rate itself needs a scripted-play policy or a human.
- The sub CPU's `/IORQ` pulse is 1 core clock (25 ns) against a real Z80's
  ~600 ns — still flagged from the starfield work, still untouched, and not
  implicated here.
