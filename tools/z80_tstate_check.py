#!/usr/bin/env python3
"""Check TV80's measured per-instruction T-state costs (sim/out/optrace.txt,
produced by rtl/z80_3d.v's OPTRACE probe under SIM_DEBUG_TRACE) against the
real Zilog Z80 timing tables.

Each OPTRACE line is one M1 opcode-fetch event: "frame=N pc=XXXX op=XX
tstates=T irq=0|1 next_pc=YYYY". `tstates` is T-states measured from THIS
fetch to the NEXT M1 fetch -- i.e. this fetch's own M-cycle plus however long
the rest of the instruction (or, for a prefix byte, the rest of the prefixed
instruction's remaining bytes) took to execute. Prefixed instructions (CB/DD/
ED/FD) show up as multiple consecutive OPTRACE lines (one per M1-cycle byte);
this script recombines them into one logical instruction before checking.
`irq=1` means an interrupt was accepted somewhere in that window, so the
measured cost includes 13T of interrupt-accept plus however much of the ISR
ran before the next M1 fetch -- not comparable to the plain opcode-table
value, so those lines are skipped rather than flagged.

Usage: python3 z80_tstate_check.py sim/out/optrace.txt
"""
import sys
import re
from collections import Counter

LINE_RE = re.compile(
    r"frame=(?P<frame>\d+) pc=(?P<pc>[0-9a-f]+) op=(?P<op>[0-9a-f]+) "
    r"tstates=(?P<tstates>\d+) irq=(?P<irq>\d) next_pc=(?P<next_pc>[0-9a-f]+)"
)

# Unprefixed base opcode T-states (Zilog Z80 Family CPU User Manual timing
# tables). Only entries actually observed in sim/out/optrace.txt are filled
# in below (plus a few immediate neighbors); anything else is "unknown" and
# reported separately rather than guessed. Conditional instructions (JR cc,
# JP cc, CALL cc, RET cc) are handled specially in classify(), not here.
BASE = {
    0x00: 4,   # NOP
    0x01: 10,  # LD BC,nn
    0x02: 7,   # LD (BC),A
    0x03: 6,   # INC BC
    0x04: 4,   # INC B
    0x05: 4,   # DEC B
    0x06: 7,   # LD B,n
    0x07: 4,   # RLCA
    0x09: 11,  # ADD HL,BC
    0x0c: 4,   # INC C
    0x0d: 4,   # DEC C
    0x0e: 7,   # LD C,n
    0x0f: 4,   # RRCA
    0x10: None,  # DJNZ e -- conditional, handled in classify()
    0x11: 10,  # LD DE,nn
    0x12: 7,   # LD (DE),A
    0x13: 6,   # INC DE
    0x14: 4,   # INC D
    0x15: 4,   # DEC D
    0x17: 4,   # RLA
    0x18: 12,  # JR e (unconditional)
    0x19: 11,  # ADD HL,DE
    0x1c: 4,   # INC E
    0x1d: 4,   # DEC E
    0x1f: 4,   # RRA
    0x20: None,  # JR NZ,e -- conditional
    0x21: 10,  # LD HL,nn
    0x22: 16,  # LD (nn),HL
    0x23: 6,   # INC HL
    0x26: 7,   # LD H,n
    0x27: 4,   # DAA
    0x28: None,  # JR Z,e -- conditional
    0x29: 11,  # ADD HL,HL
    0x2a: 16,  # LD HL,(nn)
    0x2b: 6,   # DEC HL
    0x2c: 4,   # INC L
    0x2d: 4,   # DEC L
    0x2f: 4,   # CPL
    0x32: 13,  # LD (nn),A
    0x34: 11,  # INC (HL)
    0x35: 11,  # DEC (HL)
    0x36: 10,  # LD (HL),n
    0x3a: 13,  # LD A,(nn)
    0x3d: 4,   # DEC A
    0x3e: 7,   # LD A,n
    0x3f: 4,   # CCF
    0x42: 4,   # LD B,D
    0x44: 4,   # LD B,H
    0x47: 4,   # LD B,A
    0x4f: 4,   # LD C,A
    0x56: 7,   # LD D,(HL)
    0x57: 4,   # LD D,A
    0x5f: 4,   # LD E,A
    0x68: 4,   # LD L,B
    0x69: 4,   # LD L,C
    0x6e: 7,   # LD L,(HL)
    0x6f: 4,   # LD L,A
    0x70: 7,   # LD (HL),B
    0x76: 4,   # HALT
    0x77: 7,   # LD (HL),A
    0x78: 4,   # LD A,B
    0x79: 4,   # LD A,C
    0x7a: 4,   # LD A,D
    0x7d: 4,   # LD A,L
    0x7e: 7,   # LD A,(HL)
    0x97: 4,   # SUB A
    0xa3: 4,   # AND E
    0xa7: 4,   # AND A
    0xb0: 4,   # OR B
    0xb1: 4,   # OR C
    0xb2: 4,   # OR D
    0xb4: 4,   # OR H
    0xb5: 4,   # OR L
    0xb7: 4,   # OR A
    0xb8: 4,   # CP B
    0xb9: 4,   # CP C
    0xbb: 4,   # CP E
    0xc0: None,  # RET NZ -- conditional
    0xc1: 10,  # POP BC
    0xc2: None,  # JP NZ,nn -- always 10 regardless of taken (JP has no branch penalty)
    0xc3: 10,  # JP nn
    0xc5: 11,  # PUSH BC
    0xc6: 7,   # ADD A,n
    0xc8: None,  # RET Z -- conditional
    0xc9: 10,  # RET
    0xca: None,  # JP Z,nn -- always 10
    0xcd: 17,  # CALL nn (unconditional)
    0xd1: 10,  # POP DE
    0xd2: None,  # JP NC,nn -- always 10
    0xd5: 11,  # PUSH DE
    0xd6: 7,   # SUB n
    0xda: None,  # JP C,nn -- always 10
    0xe1: 10,  # POP HL
    0xe5: 11,  # PUSH HL
    0xe6: 7,   # AND n
    0xf1: 10,  # POP AF
    0xf3: 4,   # DI
    0xf5: 11,  # PUSH AF
    0xf6: 7,   # OR n
    0xfb: 4,   # EI
    0xd9: 4,   # EXX
    0xfe: 7,   # CP n
}

# DD/FD-prefixed opcodes actually observed in sim/out/optrace.txt (IX/IY
# forms; same costs for both prefixes -- only the register used differs).
DD_FD_TABLE = {
    0x36: 19,  # LD (IX+d),n
    0x70: 19,  # LD (IX+d),B
    0xe1: 14,  # POP IX
    0xe5: 15,  # PUSH IX
}

CB_BIT_OPS = set(range(0x40, 0x80))


def cb_cost(op2):
    is_hl = (op2 & 0x07) == 0x06
    if op2 in CB_BIT_OPS:
        return 12 if is_hl else 8
    # rotate/shift or RES/SET
    return 15 if is_hl else 8


def ed_cost(op2, taken_repeat=None):
    # Block instructions: LDIR/LDDR/CPIR/CPDR/INIR/INDR/OTIR/OTDR
    if op2 in (0xb0, 0xb8, 0xb1, 0xb9, 0xa0, 0xa8, 0xb2, 0xba, 0xa1, 0xa9,
               0xb3, 0xbb, 0xa2, 0xaa, 0xa3, 0xab):
        if op2 in (0xb0, 0xb8, 0xb1, 0xb9):  # LDIR/LDDR/LDI/LDD
            if op2 in (0xb0, 0xb8):
                return 21 if taken_repeat else 16
            return 16  # LDI/LDD never repeat
        if op2 in (0xb2, 0xba, 0xa1, 0xa9):  # CPIR/CPDR/CPI/CPD
            if op2 in (0xb2, 0xba):
                return 21 if taken_repeat else 16
            return 16
        if op2 in (0xb3, 0xbb, 0xa3, 0xab, 0xa2, 0xaa):  # INI/IND/INIR/INDR/OUTI/OUTD etc
            if op2 in (0xb3, 0xbb):
                return 21 if taken_repeat else 16
            return 16
    ED_MISC = {
        0x42: 15,  # SBC HL,BC
        0x44: 8,   # NEG
        0x45: 14,  # RETN
        0x46: 8,   # IM 0
        0x47: 9,   # LD I,A
        0x4a: 15,  # ADC HL,BC
        0x4d: 14,  # RETI
        0x4f: 9,   # LD R,A
        0x56: 8,   # IM 1
        0x5e: 8,   # IM 2
        0x6f: 18,  # RLD
        0x67: 18,  # RRD
        0x78: 12,  # IN A,(C)
        0x79: 12,  # OUT (C),A
    }
    return ED_MISC.get(op2)


def check(path):
    total = 0
    skipped_irq = 0
    unknown = 0
    mismatches = []
    ok = 0

    # buffer of pending prefix bytes: list of (pc, op, tstates, irq, next_pc)
    pending = []

    with open(path) as f:
        lines = [LINE_RE.search(l) for l in f]
    events = []
    for m in lines:
        if not m:
            continue
        events.append({
            "frame": int(m.group("frame")),
            "pc": int(m.group("pc"), 16),
            "op": int(m.group("op"), 16),
            "tstates": int(m.group("tstates")),
            "irq": int(m.group("irq")),
            "next_pc": int(m.group("next_pc"), 16),
        })

    i = 0
    n = len(events)
    unknown_ops = Counter()
    halted_pc = None  # while set: CPU is parked in HALT, refetching (and
    # discarding, always as an internal 4T NOP) whatever byte sits at this
    # address every M-cycle until an interrupt breaks it out. Real Z80
    # behavior, not a TV80 quirk -- HALT is a 1-byte instruction, so once it
    # executes PC parks at HALT's own address + 1 and every subsequent fetch
    # there is a bus cycle in name only.
    while i < n:
        e = events[i]
        total += 1
        op = e["op"]

        if halted_pc is not None and e["pc"] == halted_pc and not e["irq"]:
            if e["tstates"] == 4:
                ok += 1
            else:
                mismatches.append((e["frame"], e["pc"], "HALT-refetch", 4, e["tstates"]))
            i += 1
            continue
        halted_pc = None

        if op == 0xcb:
            if i + 1 >= n:
                break
            e2 = events[i + 1]
            measured = e["tstates"] + e2["tstates"]
            irq = e["irq"] or e2["irq"]
            expected = cb_cost(e2["op"])
            i += 2
            desc = f"CB {e2['op']:02x}"
            pc = e["pc"]
        elif op == 0xed:
            if i + 1 >= n:
                break
            e2 = events[i + 1]
            measured = e["tstates"] + e2["tstates"]
            irq = e["irq"] or e2["irq"]
            # repeat vs final: block instructions loop by jumping back to
            # their OWN address (pc), so next_pc == pc means "repeated".
            taken_repeat = (e2["next_pc"] == e["pc"])
            expected = ed_cost(e2["op"], taken_repeat=taken_repeat)
            i += 2
            desc = f"ED {e2['op']:02x}" + (" (repeat)" if taken_repeat else " (final)")
            pc = e["pc"]
        elif op in (0xdd, 0xfd):
            if i + 1 >= n:
                break
            e2 = events[i + 1]
            if e2["op"] == 0xcb:
                # DD/FD CB d op -- fixed 4-byte format, displacement + opcode
                # fetched as data not a separate M1, so only 3 OPTRACE
                # events total (prefix, cb, but the trailing real opcode byte
                # is consumed as data within e2's own window). Total cost is
                # fixed: 23T for BIT b,(IX+d), 23T for RES/SET/rotate.
                measured = e["tstates"] + e2["tstates"]
                irq = e["irq"] or e2["irq"]
                expected = None  # not decoded further; needs the 4th byte
                i += 2
                desc = f"{op:02x} CB .. .."
                pc = e["pc"]
            else:
                measured = e["tstates"] + e2["tstates"]
                irq = e["irq"] or e2["irq"]
                expected = DD_FD_TABLE.get(e2["op"])
                i += 2
                desc = f"{op:02x} {e2['op']:02x}"
                pc = e["pc"]
        else:
            measured = e["tstates"]
            irq = e["irq"]
            pc = e["pc"]
            desc = f"{op:02x}"
            expected = BASE.get(op)
            if expected is None and op in BASE:
                # conditional instruction -- derive taken/not-taken from
                # control flow instead of a flag we can't see.
                fallthrough = {
                    0x10: e["pc"] + 2,  # DJNZ
                    0x20: e["pc"] + 2, 0x28: e["pc"] + 2,  # JR NZ/Z
                    0xc0: e["pc"] + 1, 0xc8: e["pc"] + 1,  # RET NZ/Z
                    0xc2: e["pc"] + 3, 0xca: e["pc"] + 3,  # JP NZ/Z,nn (cost is fixed anyway)
                    0xd2: e["pc"] + 3, 0xda: e["pc"] + 3,
                }.get(op)
                taken = fallthrough is not None and e["next_pc"] != fallthrough
                if op == 0x10:
                    expected = 13 if taken else 8
                elif op in (0x20, 0x28):
                    expected = 12 if taken else 7
                elif op in (0xc0, 0xc8):
                    expected = 11 if taken else 5
                elif op in (0xc2, 0xca, 0xd2, 0xda):
                    expected = 10
            if op == 0x76 and not irq:
                halted_pc = e["pc"] + 1
            i += 1

        if expected is None:
            unknown += 1
            unknown_ops[desc.split()[0]] += 1
            continue
        if irq:
            skipped_irq += 1
            continue
        if measured != expected:
            mismatches.append((e["frame"], pc, desc, expected, measured))
        else:
            ok += 1

    print(f"total logical instructions: {total}")
    print(f"  ok (matched spec):        {ok}")
    print(f"  skipped (irq in window):  {skipped_irq}")
    print(f"  skipped (unknown opcode): {unknown}")
    print(f"  MISMATCHES:                {len(mismatches)}")
    if unknown_ops:
        print("  unknown opcode counts:", dict(unknown_ops.most_common(20)))
    if mismatches:
        print("\nFirst 20 mismatches (frame, pc, opcode, expected_T, measured_T):")
        for frame, pc, desc, exp, meas in mismatches[:20]:
            print(f"  frame={frame} pc={pc:04x} op={desc} expected={exp} measured={meas}")
    return mismatches


if __name__ == "__main__":
    path = sys.argv[1] if len(sys.argv) > 1 else "sim/out/optrace.txt"
    check(path)
