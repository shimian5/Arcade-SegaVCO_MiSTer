# Turbo audio model: basis for every choice

Rule: each modelling choice is explained by **(A)** the schematic, **(B)** the parts list or a part datasheet/photo,
**(C)** a physical cabinet component, or **(D)** component tolerance (the reference cabinet is assumed recapped:
new parts inside their stated tolerance). Anything else is an **exception (X)** and is listed here.

## Schematic / parts-list derived (A, B)
- Player car (sheets D-8/11, D-9/11): tone cells and IC7 gate, 4.7k/15k bus divider with its DC-loaded tap (0.6727),
  C18/C20 unfitted, IC17 gating, tunnel (BSEL1) chain with the IC38 555 ramp, loaded R219/R220 tap (x2.234).
- SLF sub-audio branch (W bus only): IC3/IC5 cells, D8, IC17-lower, IC30, R198/R199 divider.
- Other Cars (D-6/11): three triangle oscillators with PROM-selected F/L/R/W gains.
- Ambulance: two relaxation cells frequency-modulated by a 555 sawtooth.
- Skid (D-3/11): IC1-A relaxation oscillator (15.2 Hz), IC1-B summer, coupling capacitor into the NE555 CONT pin,
  NE555 astable with CONT-controlled thresholds, VCA. Noise reaches the sound only as modulation of the 555.
- Noise source S2688 = MM5837 (National datasheet): 17-bit shift register, feedback from stages 17 and 14.
- STK-439 output stage: F amplifier into two 12 cm 4 ohm speakers in series, W amplifier into one 30 cm 8 ohm woofer.

## Tolerance choices (D) - one reference cabinet
Player-car C5 -0.75 %, C19 -2.2 %, C21 +3.05 % (warble about 3.5-3.9 Hz instead of 18.9 Hz nominal); SLF cells 23.18 /
36.92 Hz; Other Cars 77.130 / 202.310 / 202.396 Hz; ambulance repeat 3.003 Hz (nominal 2.853 Hz, plus a fix of an
arithmetic rounding error in the earlier constants). These fit one recorded cabinet and assume a recapped board;
the film capacitors C154 and C19 have no stated tolerance grade in the parts list.

## Proxies and assumptions (not from the original documents)
- MB4391 = two Motorola MC3340s (Sega custom, no datasheet); original MC3340 12 V gain curve; SLF absolute gain x2.88.
- S2688 clock 100 kHz (datasheet bounds the cycle time to 1.1-2.4 s, i.e. about 55-119 kHz); output swing 9.5 Vpp.
- Op-amp output limits (+-4.5 V around the 6 V reference, symmetric) and VCA input resistance are exceptions (X):
  the sheets show a single 0/12 V supply, so real limits are asymmetric.
- Skid: op-amp endpoints 10.5 / 0.02 V, noise-amplitude polynomial, 4 V p-p tone amplitude, 22 uF (layout) versus
  33 uF (hand-drawn sheet) coupling capacitor.
- Mixer trims (crash.S 1.0, crash.L 0.75, skid 0.40, ambulance 0.05, alarm 0.76): the board has trimmers for these
  channels but their cabinet positions are unknowable; these values are listening-balance choices (X), not tolerances,
  and depend on engine / Other Cars absolute gains that are not yet applied.

## Output
The two STK-439 outputs are summed (x0.707) into one mono signal: the cabinet's speakers share one box and are heard
as one acoustic field. There is no speaker simulation, roll-off or stereo option: a woofer and enclosure model would be
an exception without published speaker data and an unvalidated measurement.

## Known mismatches against the cabinet recording
Engine upper products (444 / 743 Hz) 7-9 dB weak; Other Cars B/C second harmonic about 10 dB strong; tunnel room
character not reproduced; the alarm and the CRASH.L filter networks not re-derived from the schematic (CRASH.S is
never triggered by the game, so its one-pole filter does not matter); absolute VCA gains for the engine and Other Cars
not applied; comparator delay not modelled; op-amp output limits are symmetric where the single-supply sheet implies
asymmetric ones (follow-up). The CRASH.L tail one-shot uses R330 = 47K from the schematic (72.9 ms).
