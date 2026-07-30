# Buck Rogers starfield steps ~2x too fast — root cause

**Status: root-caused.** The sub CPU's main→sub command channel is almost
entirely broken in this core. The starfield's 2x speed is one downstream
symptom of that, not a bug in the star code path.

Short version: PPI0 is programmed in **8255 mode 2**, where PC7 is the
`/OBF` handshake output (auto-asserted by a port-A write) and PC6 is the
`/ACK` input (from the sub CPU's `/IORQ`). `rtl/io/i8255.v` implements
**mode 0 only** and ignores the mode field, so a port-A command write never
raises the sub CPU's `/INT`. The sub CPU therefore misses ~92% of the
commands the main CPU sends it, and its star-motion state bytes are stale.


## 1. The hard count asked for

Sub-CPU **interrupt acceptances** per video frame, identical coin(90-99)/
start1(150-159) schedules, frames 0-459:

| | total over 460 frames | frames with >=1 | max in one frame |
|---|---|---|---|
| MAME  | **627** | 287 | 4 |
| our RTL | **52** | 52 | 1 |

Not 2:1. It is **12:1 in the wrong direction** — we take far *too few*.

Inside the star-tracking window (frames 420-459) specifically, MAME takes
**0** and the RTL takes **5**; neither is sending commands there, so the
state divergence that produces the 2x was already established earlier
(first commands are exchanged from frame ~45 on).

**Star-update routine runs per frame** (sub ROM `$030B`, the 4th star bank):

| | invocations/frame | per-star iterations/frame |
|---|---|---|
| MAME | 1-2 | **0** (`$F40B` = 0 -> `RET Z` at `$030F`) |
| our RTL | 1-2 | **48-96** (`$F40B` = 0x30) |

**bitmap_ram writes per frame**, frames 420-459: MAME 138-168, RTL 180-234.

So: the routine does not run twice per frame in either. The 2x is a
per-call step-size difference, located below.


## 2. Where the "2x" literally lives

Disassembling the sub ROM (`epr-5200.cpu-ic66`) gives four near-identical
star banks. Each per-star iteration is:

```
0318  CALL $0365        ; clear star at DE     -> LD (HL),$00 at $036E
0321  LD A,($F402)      ; per-frame X step
0324  ADD A,(HL)  ...   ; star.x += dx
0329  LD A,($F403)      ; per-frame Y step
032C  ADD A,(HL)  ...   ; star.y += dy
032F  CALL $034F        ; set star at DE       -> LD (HL),$01 at $035F
```

Bitmap addressing is `addr = y*256 + x`, so `$F403` **is** the per-frame dy.

| sub work RAM | MAME | our RTL | meaning |
|---|---|---|---|
| `$F402` | 00 | 00 | star dx |
| `$F403` | **00** | **FA (-6)** | star dy |
| `$F40B` | **00** | **30** | 4th-bank star count |
| `$F410` | 70 | 70 | plot row limit (matches — row 111 cutoff) |

Measured median dy was -6. `$F403 = 0xFA` is exactly that. In MAME the
whole `$F402/$F403` drift is zero and the residual -3 comes from the
per-star perspective scaler at `$01A8` in banks 1-3.

`$F402/$F403` are computed at `$009D-$00B4` from `$F602/$F603`:

```
00A9  LD A,($F603) / BIT 3,A / OR $F0 (sign-extend 4 bits)
00B2  NEG
00B4  LD ($F403),A
```

and `$F40B` at `$00E2-$00F9` is `table[$0129 + ($F605 & 7)*4 + 3]`.

`$F600..$F60F` is written **only** by the sub CPU's interrupt handler:

```
0038  PUSH AF
0039  IN A,($00)        ; read the command latch
003D  LD HL,$F600
0040  RRCA x4 / AND $0F / ADD A,L / LD L,A   ; HL = $F600 + (cmd >> 4)
0048  LD A,C / AND $0F / LD (HL),A           ; store the low nibble
004E  EI / RET
```

That is the entire main->sub protocol: **one command byte per accepted
interrupt**. Miss the interrupt, miss the command. MAME's per-frame `IN`
count equals its ISR count exactly (3/3, 3/3, 2/2, 3/3, 1/1 over frames
161-165) — one `IN` per interrupt, no more.

With ~92% of commands dropped, `$F603` and `$F605` hold stale nibbles:
dy = -6 instead of 0, and star-count row 2/3 instead of row 4 (which is
also why we plot 46 stars/frame and ~195 bitmap writes vs MAME's 40-44 and
~155).


## 3. Why the interrupts are missed — the actual bug

### 3a. PPI0 is in mode 2, our i8255 only does mode 0

The game writes the PPI0 control word **once**, at boot:

```
$C803 <= 0xC0     (MAME frame 8; our RTL writes the same byte)
```

`0xC0` = `1 10 0 0 0 0 0`:

* D7=1 mode-set
* **D6-D5 = 10 -> group A mode 2** (strobed bidirectional)
* D4=0 port A output, D3=0 port C upper output, D2-D0 group B mode 0

In 8255 mode 2 the port C upper bits are **not** data:

* **PC7 = /OBF** — driven LOW automatically by the chip when the CPU
  writes port A, driven HIGH by a /ACK pulse.
* **PC6 = /ACK** — an input.

`rtl/io/i8255.v` says so itself: *"Generic Intel 8255 PPI, mode 0 only"*,
and the control-word decode carries the comment *"mode field is assumed 00
= mode 0"* — D6/D5 are discarded. So in this core PC7 is a plain data
latch. The game's port-C data writes are `0xA0/0xA1/0xA2` — **bit 7 always
1** — so on the mode-0 model the sub CPU's `/INT` should never assert at
all.

Schematic confirms the mode-2 reading (reference priority: schematic wins):

* CPU Bd. 834-5120 **sheet 5** (PDF p33): 8255-5 **IC90**, `/CS = CSE8`.
  Of the port C upper bits only **PC7 (pin 10)** and **PC6 (pin 11)** are
  wired; **PC3/PC4/PC5 are drawn unconnected** — exactly the two mode-2
  handshake lines and nothing else.
* Both nets run to the second Z80 (**IC50**, same sheet): PC7 -> `/INT`
  (pin 16), PC6 <- `/IOREQ` (pin 20).

So on real hardware the command write *is* the interrupt, and the sub
CPU's own `IN` (which pulses `/IORQ` -> `/ACK`) is what clears it. That is
a hardware handshake with no software `/INT`-clear step anywhere — and it
is why MAME's ISR count and `IN` count match 1:1, and why each MAME ISR
fires ~5 us after a port-A write:

```
PPI0WR frame=45 t=0.764819 addr=0 data=17
ISR    frame=45 t=0.764823
PPI0WR frame=45 t=0.769042 addr=0 data=20
ISR    frame=45 t=0.769048
```

MAME's `delayed_i8255_w` / 600 Hz quantum is irrelevant here — it only
orders the write against the sub CPU's execution. The `/OBF` handshake is
real 8255 silicon behaviour, present in the schematic.

`rtl/z80_3d.v`'s `ack_reg` is a hand-rolled half of this: it captures the
sub CPU's `IN` for the main CPU to read back on PC6, but it is not wired to
`/INT`, so the assert half of the handshake is simply missing.

### 3b. The 52 interrupts we *do* take are a glitch, not the game

`sub_int_n = ppi0_pc[7]` is combinational, and PC7 does briefly go low once
per frame — for exactly **one Z80 T-state**:

```
INTEDGE frame=45 tick=4146486 int_n=0
INTEDGE frame=45 tick=4146487 int_n=1
PPI0WR  frame=45 tick=4146486 addr=2 first=01 last=b9
```

`cpu_z80.v` registers `mreq_n_r`/`wr_n_r` on every `posedge clk`, **not**
gated by `cen`, while `cpu_do` changes on the `cen` edge. The write strobe
is therefore misaligned with valid data by one core clock in eight, and
`z80_3d.v` latches on *every* clock the strobe is high. The correct byte is
the one present on the **last** cycle (independently confirmed: PPI0 port B
write, sim last = `0x19`, MAME = `0x19`); the leading 7 cycles carry a
stale bus value. For the port-C write that stale value is `0x01`, whose
bit 7 = 0 momentarily asserts `/INT`.

A 1-T-state runt pulse is only seen by the Z80 if it happens to land on an
instruction boundary — hence 52 accidental acceptances over 460 frames
instead of 0, and hence which commands get through is essentially random.

This skew affects every memory-mapped write in the design (the final
latched value is still correct, so RAM writes are unharmed); it only
becomes visible where a transient value has a side effect, as here.


## 4. Instruments used (and validated)

* `rtl/z80_3d.v`, under `VERILATOR_SIM`, plusarg-gated:
  * `+subintcount` — per-frame `SUBINT` line: sub interrupt acceptances,
    `IN` count, bitmap writes, `/INT`-low T-states, PPI0 port-C writes,
    star-loop invocations/iterations, and `$F402/$F403/$F40B/$F410`.
  * `+bmwrtrace_lo=N +bmwrtrace_hi=N` — per-write `BMWR` trace (address,
    data, sub PC), plus `INTEDGE` / `PPI0WR` lines.
* `tools/mame/dump_subint_census.lua` — the MAME counterpart.

Two probe defects were found and fixed *before* any conclusion was drawn
from them, per the standing caution in
`docs/INVESTIGATION_title_logo_garbling.md`:

1. **MAME taps were being garbage-collected.** `install_write_tap`'s return
   value must be kept in a live (global) variable; otherwise the tap is
   silently removed mid-run and the counter reads 0 forever. First run
   showed `bmwr` dropping to 0 at frame ~240 while stars were demonstrably
   still moving.
2. **Sampling the write strobe on its leading edge read garbage.** The
   first `BMWR` trace reported `do=f0/f1` at both the plot and erase sites,
   which is impossible — both stores are immediates (`LD (HL),$01` /
   `LD (HL),$00`). Sampling at the *end* of the strobe gives `do=01` at
   `$035F` and `do=00` at `$036E`, matching MAME exactly. (This defect is
   itself a symptom of the skew in 3b.)
3. MAME's PPI0 is mapped `.mirror(0x07fc)`; a tap on `$C800-$C803` alone
   sees only part of the traffic. Widened to `$C800-$CFFF`.

Sanity checks that the probes are non-degenerate: `$F410` reads `0x70` in
both (matching the known row-111 star cutoff); MAME's `IN` count equals its
ISR count exactly; sim and MAME agree on the port-B write value and on the
PPI0 control word `0xC0`.


## 5. What this does *not* explain

The residual per-star motion in MAME (median dy -3) comes from the
perspective scaler at `$01A8` in star banks 1-3, driven by `$F404-$F40A`.
That path is not implicated here and was not audited.


## 6. The fix

### 6a. Primary: implement the 8255 mode-2 group-A handshake

`rtl/io/i8255.v` — decode D6 of the control word (D6=1 selects mode 2 for
group A, regardless of D5) and add the handshake:

* new input `ack_n`, driven from the sub CPU's `~sub_iorq_n` in `z80_3d.v`
* `obf_n` register: reset high; cleared low by a port-A write; set high by a
  falling edge on `ack_n`
* port C readback in mode 2: bit 7 = `obf_n`, bit 6 = `ack_n` (live pin),
  bits 5-3 = IBF / `/STB` / INTR (unconnected on this board)
* a port-C **data** write in mode 2 must only affect PC2-PC0 (group B lower)
  — bits 7-3 are handshake pins and are not writable
* BSR to PC7/PC6 in mode 2 addresses the INTE flip-flops, not the pins

`rtl/z80_3d.v` — `sub_int_n` still comes from PPI0 PC7, but that bit is now
`obf_n` rather than a data latch. Wire `~sub_iorq_n` into the new `ack_n`.
The hand-rolled `ack_reg` bit-6 override becomes dead and should go: the
main CPU polls **PC7**, not PC6 (see 6c).

Nothing else in the star path needs touching. With commands arriving,
`$F603`/`$F605` track the game state and dy/star-count follow.

### 6b. Independent latent bug: write-strobe / data skew

Measured directly (`BUSWIN` probe, main CPU write to `$C802`):

```
7 core clks:  mreq_n=0 wr_n=0  do=01   <- stale
1 core clk :  mreq_n=0 wr_n=0  do=b9   <- the real byte, arrives on the
                                          cen edge that ends the T-state
then       :  mreq_n=1 wr_n=1  do=b9
```

Valid write data is present only on the **final** core clock of the
`mreq_n & wr_n` window. Every RAM in the design latches on each clock while
the strobe is high, so last-write-wins hides this — but any *combinational*
consumer of a latched value sees a 7-cycle glitch. That is what produced
the 1-T-state `/INT` runt pulse in 3b.

Fix: derive a single-cycle write pulse on the **trailing** edge of the
strobe and use it everywhere, instead of latching every cycle:

```verilog
reg  cpu_write_d;
always @(posedge clk) cpu_write_d <= cpu_write;
wire cpu_we = cpu_write_d && !cpu_write;   // cpu_a / cpu_do still valid here
```

Do **not** gate on `ce_z80` — the `cen` pulse lands mid-strobe, where the
data is still stale.

Note the ordering: once 6a lands, PC7 stops following written data at all,
so the starfield symptom is gone without 6b. 6b is hygiene and deserves its
own regression pass.

### 6c. Why this is schematic-hardened, not MAME-derived

Every load-bearing claim was read off the hardware or the game's own bus
traffic, not from MAME's C++:

1. **Mode 2 is the game's own choice**, observed on the bus in *both* MAME
   and our sim: `$C803 <= 0xC0` exactly once at boot. D6=1 -> mode 2.
2. **The 8255 drives PC7 by itself.** Main CPU at PC `$4B57` does
   read-portC / write-portA / read-portC:
   ```
   PPI0RD addr=2 data=a1 pc=4b57      ; /OBF high, idle
   PPI0WR addr=0 data=20              ; command written
   PPI0RD addr=2 data=21 pc=4b57      ; bit 7 now 0 -- /OBF low
   ```
   `a1 -> 21` differs in bit 7 only, and the CPU never wrote `0x21`. That is
   `/OBF` asserting, observed. It also shows the main CPU's "command
   consumed" poll is on **PC7**, which is why `ack_reg` (bit 6) is wrong.
3. **Schematic, CPU Bd. 834-5120 sheet 5 (PDF p33):** on 8255-5 **IC90**,
   port C upper has **only PC7 (pin 10) and PC6 (pin 11)** wired;
   **PC3/PC4/PC5 are drawn with open terminals and no net**. Both wired nets
   run as plain point-to-point traces across the sheet — **no gates of any
   kind in between** — to the second Z80 **IC50**: PC7 -> `/INT` (pin 16),
   PC6 <- `/IOREQ` (pin 20). PC7 output / PC6 input is forced by direction
   (Z80 `/INT` is an input, `/IOREQ` an output), so the assignment is
   unambiguous. That pinout *is* the mode-2 handshake pair and is
   inconsistent with mode 0.
4. **The mode-2 reading also explains the port-C data writes.** The game
   writes `0xA0/0xA1/0xA2`; in mode 2 those touch only PC2-PC0, i.e.
   `FCHG0-2` = 0/1/2. Under our mode-0 model the same bytes stomp PC7,
   which is precisely the wrong behaviour. Under mode 2 they cannot.
5. **`/ACK` is the raw sub `/IORQ`, ungated.** With no `/M1` or `/RD`
   qualification in the path, hardware also pulses `/ACK` during the
   interrupt-acknowledge cycle (`/M1` + `/IORQ`), so `/INT` self-clears at
   accept time. Mode 2 additionally gates port A onto the sub data bus with
   `/ACK`, which is why the board needs no I/O address decoder at all and
   why the sub port map is `map(0x00,0xff)`.

**Where the schematic beats MAME:** MAME clears the handshake in
`subcpu_command_r` (`pc6_w(CLEAR_LINE)`), i.e. on the ISR's `IN`. Hardware
clears it one machine cycle earlier, on the interrupt-acknowledge `/IORQ`.
Follow the schematic. In IM1 the byte the sub CPU reads during int-ack is
ignored, so port A driving the bus there is harmless; `z80_3d.v`'s existing
`sub_di` mux (`~sub_iorq_n ? ppi0_pa : ...`) already matches hardware,
including during int-ack, and needs no change.

**Not verified:** the exact readback values of the unused mode-2 status bits
(PC5/PC4/PC3). They are unconnected on this board and the main CPU's poll
only tests PC7, so any sane value works; pick the datasheet values.


## 7. Implemented, and the result

Both fixes are in.

**6a — mode 2** (`rtl/io/i8255.v`, `rtl/z80_3d.v`): `ack_n` input, `mode2_a`
from control-word D6, `obf_n` flip-flop (cleared on the trailing edge of a
port-A write, set by `/ACK` falling, initialised by a mode-set), port C
readback/pin vector switched to the handshake bits in mode 2, port-C data
writes and BSR blocked from bits 7-3 in mode 2. `sub_int_n` still reads
`ppi0_pc[7]` — that bit is now `/OBF`. `ack_reg` and `ppi0_dout_ovr` deleted.

**6b — write-strobe skew** (`rtl/z80_3d.v`): `cpu_write` and `sub_write` are
now one-core-clock strobes derived from the **trailing** edge of
`~mreq_n & ~wr_n`, where the data bus is valid. Behaviourally neutral on the
RAMs (as predicted — they already got the same byte via last-write-wins); it
removes the 7-clock garbage excursion that combinational consumers saw,
including `fchg`, a live video register.

### Results

| | before | after | MAME |
|---|---|---|---|
| sub interrupt acceptances / 460 frames | 52 | **1136** | 627 |
| `intack` == `ioread` (the hardware 1:1 invariant) | no | **yes, every frame** | yes |
| port-A writes vs acceptances | — | **114 / 114, lossless** | — |
| `$F403` (star dy) in window | `FA` (-6) | `FE` (-2) | `00` |
| measured median dy | **-6** | **-2** | -3 |
| measured mean dy | **-4.575** | **-2.318** | -2.473 |

The 2x is gone: mean |dy| is now within 6% of MAME's, and the measured median
`dx/dy` of `+4 / -2` is **exactly** the sub CPU's own received `$F402/$F403`
of `04 / FE` — the starfield now moves precisely as the delivered commands
say, which is the check that does not depend on matching MAME's game state.

`tools/measure_star_motion.py` reproduces the metric from the bitmap dumps;
run against MAME it returns mean dy -2.473 / median -3 / 33-49 stars, matching
the independently-reported reference numbers, so the tracker is validated.

### What still differs from MAME, and why that is expected

Our `$F600` command state tracks MAME's exactly until frame 44 (the only
earlier difference is frame 18, where the same command lands one frame early
— the known non-persisting blip). From frame 44 the two runs' *main CPUs*
emit different command bytes and the game states separate: at frames 420-459
we sit at `dx=04 dy=FE nstars=30 horiz=70` while MAME sits at
`dx=00 dy=00 nstars=00 horiz=70`. Hence the residual `dx` and star-count
differences.

That is the already-closed reset-phase divergence (commit 02f18f2: the
schematic shows no reset-to-vblank phase lock on real hardware, so the two
runs are not expected to stay in lockstep), **not** a handshake defect — the
`114 / 114` lossless-delivery count rules that out. Star counts differ because
`horiz`/`nstars` differ, which follows from the game state, not the transport.

### Not done

* Mode 1 is still unimplemented (nothing in this core uses it), and only the
  output half of mode 2 is modelled — no `/STB`//IBF input path.
* PC5/PC4/PC3 readback values in mode 2 are the idle levels; unconnected on
  this board and never polled.
* `fchg` is still taken as `ppi0_pc[1:0]` while MAME uses `data & 0x07`;
  pre-existing and out of scope here.


## 8. The mode-2 fix was necessary but NOT sufficient — the real root cause

**Status: root-caused and fixed.** Section 7's fix made the *transport*
work (interrupts arrive, 1:1, lossless) but the *payload* was still garbage:
the sub CPU's `IN A,($00)` was latching the wrong byte entirely. Section 7's
validation counted events (interrupt acceptances, port-A writes) and never
once checked that the byte the sub CPU stored equalled the byte the main CPU
wrote. It did not.

### 8a. The observation

Sub ROM `$0038` disassembles (bytes `f5 db 00 d9 4f 21 00 f6 0f 0f 0f 0f e6
0f 85 6f 79 e6 0f 77 d9 f1 fb c9`) to:

```
0038  F5        PUSH AF
0039  DB 00     IN A,($00)     ; command byte
003B  D9        EXX
003C  4F        LD C,A
003D  21 00 F6  LD HL,$F600
0040  0F 0F 0F 0F  RRCA x4
0044  E6 0F     AND $0F        ; index = cmd >> 4
0046  85        ADD A,L
0047  6F        LD L,A
0048  79        LD A,C
0049  E6 0F     AND $0F        ; value = cmd & 0x0F
004B  77        LD (HL),A
004C  D9        EXX
004D  F1        POP AF
004E  FB        EI
004F  C9        RET
```

Tracing frame 44, the main CPU writes commands `01, 44, 54, 44, 17`, which
must produce `f600 = 0107000004040000`. Instead every store went to `$F600`
with the wrong data:

```
SUBIN  suba=df00 subdi=01 -> F600WR addr=f600 data=00
SUBIN  suba=df00 subdi=44 -> F600WR addr=f600 data=00
SUBIN  suba=df00 subdi=54 -> F600WR addr=f600 data=00
SUBIN  suba=0500 subdi=44 -> F600WR addr=f600 data=02
```

`suba` is the I/O address bus — for `IN A,(n)` the Z80 puts **A** on A15-A8,
so those reads addressed `$DF00` and `$0500`. The stored bytes are exactly
what lies at those addresses in the sub CPU's **memory** map:
`sub_workram[$700]` (`$DF00 & 0x7FF`) = `00`, and **`sub_rom[$0500] = 02`**.
The `IN` was returning the memory-path byte, not the PPI0 command latch.

### 8b. The bug: `di` sampled after `/IORQ` was released

`rtl/cpu_z80.v` (bus decode copied from `tv80s.v`):

```verilog
// iorq_n_r asserted only during tstate_w[1] (T2):
if ((tstate_w[1] || (tstate_w[2] && wait_n == 1'b0)) && !no_read_w && !write_w) begin
    rd_n_r <= 1'b0; iorq_n_r <= ~iorq_w; mreq_n_r <= iorq_w;
end
// ...but di latched throughout T3, ungated by `cen`:
if (tstate_w[2] && wait_n == 1'b1 && !write_w && !no_read_w)
    di_reg <= di;
```

In stock `tv80s` there is no `cen`, so T3 is **one** clock and this samples
`di` on the single edge where `iorq_n_r` still reads 0. This core drives
`tv80_core` from a `cen` strobe (core clock / 8), so T3 lasts **8 core
clocks** and `di_reg` was re-sampled on all eight — last-write-wins. By clock
2 of T3 `iorq_n_r` was already back high, so `z80_3d.v`'s bus mux

```verilog
sub_di = ~sub_iorq_n ? ppi0_pa : (sub_a < 16'h2000 ? sub_rom_dout : sub_workram_dout);
```

had reverted to the memory path, and that is the byte the CPU kept.

This is the **read-side twin of the write-side `cen`/strobe skew found in
6b**, which was fixed while this one was left in place. It only bites where a
read is qualified by something other than the address: every other read in
the design (both CPUs' memory reads, all the main CPU's I/O) is decoded
purely from the address bus, which is stable across T1-T3. The sub CPU's
`IN` is the only address-independent read in the whole core — and it is the
entire main->sub command channel.

**Fix** (`rtl/cpu_z80.v`): sample `di` on the FIRST core clock of T3, which
is what the ungated `tv80s` does:

```verilog
if (tstate_w[2] && !ts3_d && wait_n == 1'b1 && !write_w && !no_read_w)
    di_reg <= di;
ts3_d <= tstate_w[2];
```

This is structurally correct, not a lucky alignment: `iorq_n_r` is driven
back high *by the same clock edge* that now samples `di`, so the sample lands
on the last clock at which `/IORQ` still reads low.

### 8c. Why this is schematic/spec-derived, not a MAME hack

Nothing here comes from MAME. MAME has no bus, no T-states and no `/IORQ`;
`subcpu_command_r` simply returns a variable, so MAME cannot exhibit or
inform this bug either way. The authorities are:

1. **Z80 bus timing** (Zilog UM0080, "Input or Output Cycles"): in an I/O
   read the CPU asserts `/IORQ` + `/RD` in T2, auto-inserts one wait state,
   and **latches the data bus while `/IORQ` and `/RD` are still asserted**,
   releasing them at the end of T3. Latching after releasing `/IORQ` — which
   is what this core did — is not a thing a Z80 does.
2. **8255 mode 2** (datasheet): the port A tri-state output buffer is enabled
   *only while `/ACK` is low*. Outside that window port A floats.
3. **Schematic, CPU Bd. 834-5120 sheet 5 (PDF p33)**, verified directly:
   * IC90 (8255-5) pins 4,3,2,1,40,39,38,37 = **PA0-PA7**, wired to net
     **`D0`-`D7`**; IC50 (sub Z80-B) pins 14,15,12,8,7,9,10,13 = **D0-D7**,
     the *same* net. The 8255's port A pins **are** the sub CPU's data bus.
   * IC90's CPU-side data pins 34-27 are `DO0`-`DO7` — a *different* net
     (the main CPU bus). That split is the mode-2 bidirectional arrangement.
   * PC3 (19), PC4 (13), PC5 (12) are drawn with open terminals — **no net**.
     PC6 (11) and PC7 (10) are wired; IC50 pin 16 = `/INT`, pin 20 = `/IOREQ`.
   * IC50 has **no I/O address decoder anywhere** — `/IOREQ` runs straight to
     PC6. Nothing else on the board can drive D0-D7 during an I/O read.

So on real hardware the command byte is present on the sub CPU's data bus
**exactly while `/IOREQ` is low, and at no other time**. `z80_3d.v`'s mux was
already a faithful model of that; the CPU wrapper was sampling outside the
window. The fix moves the sample back inside it.

The confirming check is also MAME-independent: the sub CPU now stores exactly
the bytes the main CPU wrote (`01`->`$F600`=1, `44`->`$F604`=4,
`54`->`$F605`=4, `17`->`$F601`=7). That is our own design agreeing with the
game ROM's own ISR, not agreement with an emulator.

### 8d. Results

Sim frame 44 now yields `f600 = 0107000004040000`, `dx=00 dy=00 nstars=00
horiz=70` — byte-identical to MAME's steady state, and it holds thereafter
exactly as MAME's does. The star-state machine now matches MAME's transition
sequence exactly (`horiz`: `00 -> e0 -> 70 -> e0 -> 70`).

| star state | before (broken) | after | MAME |
|---|---|---|---|
| `dx` | thrashes `00/02/f8/fa/fe` | **`00` throughout** | `00` |
| `dy` | picks up `06`, `08` | **`00` throughout** | `00` |
| `horiz` (plot row limit) | flips `e0`/`90`/`70` | **`e0` attract, `70` in game** | same |
| measured median dx | `+4` | **`0.0`** | `0` |

This accounts for all three symptoms reported from real hardware, which the
counter-only validation in section 7 could never have caught:

* **"stars veer hard right or hard left"** — `dx` swinging between `f8` (-8)
  and `02` (+2) as corrupt bytes landed in `$F602`.
* **"speed seems off"** — spurious `dy` of `06`/`08`.
* **"stars display below the horizon line, often but not always"** —
  `$F410` (`horiz`, the plot row limit) corrupted to `e0` (224 = the whole
  screen) or `90` (144) instead of `70` (112). Post-fix the star bitmap is
  confined to rows 1-110.

### 8e. Related fidelity gap found, NOT fixed

The sub CPU's `/IORQ` pulse is **1 core clock (25 ns)** wide (measured with
the `IORQW` probe). A real Z80 holds `/IORQ` low for T2 + TW + T3 ≈ 600 ns at
4.992 MHz. Since this net *is* the 8255's `/ACK`, the modelled `/ACK` pulse
is ~24x narrower than hardware and below the 8255-5's minimum `/ACK` pulse
width. It causes no functional error here — our `i8255.v` is synchronous and
edge-detects `/ACK` for `/OBF`, and the port-A gating window now covers the
CPU's sample instant — but the waveform is not hardware-faithful and is worth
closing separately.
