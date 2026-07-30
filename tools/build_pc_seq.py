import re, sys

LINE_RE = re.compile(
    r"frame=(?P<frame>\d+) pc=(?P<pc>[0-9a-f]+) op=(?P<op>[0-9a-f]+) "
    r"tstates=(?P<tstates>\d+) irq=(?P<irq>\d) next_pc=(?P<next_pc>[0-9a-f]+)"
)

def sim_seq(path):
    events = []
    with open(path) as f:
        for l in f:
            m = LINE_RE.search(l)
            if m:
                events.append({
                    "frame": int(m.group("frame")),
                    "pc": int(m.group("pc"), 16),
                    "op": int(m.group("op"), 16),
                    "irq": int(m.group("irq")),
                    "next_pc": int(m.group("next_pc"), 16),
                })
    seq = []
    i = 0
    n = len(events)
    halted_pc = None  # HALT-refetch: real Z80 re-fetches HALT_addr+1 every
    # M-cycle while waiting for an interrupt. Sim's OPTRACE logs each such
    # refetch as its own M1 event; MAME's trace command logs the HALT
    # instruction once and jumps straight to the ISR on interrupt. Drop the
    # refetch entries entirely (not just dedup) so the two sequences line up.
    while i < n:
        e = events[i]
        op = e["op"]
        pc = e["pc"]
        frame = e["frame"]
        irq = e["irq"]
        if halted_pc is not None and pc == halted_pc:
            i += 1
            continue
        halted_pc = None
        if op == 0x76:
            halted_pc = (pc + 1) & 0xffff
        if op in (0xcb, 0xed, 0xdd, 0xfd):
            if i + 1 < n:
                irq = irq or events[i+1]["irq"]
                i += 2
            else:
                i += 1
        else:
            i += 1
        seq.append((frame, pc, irq))
    return seq

MAME_LINE_RE = re.compile(r"^([0-9A-Fa-f]{4}): ")

def mame_seq(path):
    seq = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for l in f:
            m = MAME_LINE_RE.match(l)
            if m:
                seq.append(int(m.group(1), 16))
    return seq

if __name__ == "__main__":
    sim_path, mame_path = sys.argv[1], sys.argv[2]
    mame_offset = int(sys.argv[3]) if len(sys.argv) > 3 else 0
    sim = sim_seq(sim_path)
    mame = mame_seq(mame_path)
    print(f"sim logical instructions: {len(sim)}")
    print(f"mame logical instructions: {len(mame)}")
    n = min(len(sim), len(mame) - mame_offset)
    first_mismatch = None
    for i in range(n):
        if sim[i][1] != mame[i + mame_offset]:
            first_mismatch = i
            break
    if first_mismatch is None:
        print(f"No mismatch in first {n} instructions (offset={mame_offset})")
    else:
        print(f"FIRST MISMATCH at index {first_mismatch} (mame_offset={mame_offset})")
        lo = max(0, first_mismatch - 15)
        hi = min(n, first_mismatch + 15)
        for i in range(lo, hi):
            marker = " <== DIVERGE" if i == first_mismatch else ""
            print(f"  idx={i} sim_frame={sim[i][0]} sim_pc={sim[i][1]:04x} sim_irq={sim[i][2]}  mame_pc={mame[i+mame_offset]:04x}{marker}")
