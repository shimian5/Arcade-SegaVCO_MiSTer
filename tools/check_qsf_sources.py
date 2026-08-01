#!/usr/bin/env python3
"""Verify every RTL source on disk is listed in the Quartus project file.

Quartus needs each file named explicitly in Arcade-SegaVCO.qsf, while the
Verilator harnesses glob the directory. That asymmetry silently bites: a new
channel simulates perfectly and then fails to synthesise, and the gap is only
found at compile time.

    python tools/check_qsf_sources.py          # report, exit 1 if anything missing
    python tools/check_qsf_sources.py --fix    # append the missing entries

Run it after adding any file under rtl/.
"""

import argparse
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
QSF = REPO / "Arcade-SegaVCO.qsf"

# Directories whose contents must appear in the qsf. tv80 is vendored and
# already listed file-by-file; pll is pulled in via pll.qip.
WATCHED = ["rtl/audio", "rtl/video", "rtl/io"]
SUFFIX_KIND = {".sv": "SYSTEMVERILOG_FILE", ".v": "VERILOG_FILE"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fix", action="store_true",
                    help="append missing entries to the qsf")
    args = ap.parse_args()

    qsf_text = QSF.read_text(encoding="utf-8", errors="replace")
    listed = set(re.findall(r"(?:SYSTEMVERILOG_FILE|VERILOG_FILE)\s+\"?([^\"\s]+)\"?",
                            qsf_text))

    missing = []
    for d in WATCHED:
        for f in sorted((REPO / d).glob("*")):
            if f.suffix not in SUFFIX_KIND:
                continue
            rel = f"{d}/{f.name}"
            if rel not in listed:
                missing.append((rel, SUFFIX_KIND[f.suffix]))

    if not missing:
        print(f"ok: all sources under {', '.join(WATCHED)} are listed in the qsf")
        return 0

    print(f"MISSING from {QSF.name} ({len(missing)}):")
    for rel, _ in missing:
        print(f"  {rel}")

    if not args.fix:
        print("\nrun with --fix to append them")
        return 1

    anchor = "set_global_assignment -name VERILOG_FILE rtl/io/i8279.v"
    if anchor not in qsf_text:
        print("could not find the anchor line to append after; add them by hand")
        return 1
    block = "\n".join(f"set_global_assignment -name {kind} {rel}"
                      for rel, kind in missing)
    qsf_text = qsf_text.replace(anchor, anchor + "\n" + block, 1)
    QSF.write_text(qsf_text, encoding="utf-8", newline="")
    print(f"\nappended {len(missing)} entries")
    return 0


if __name__ == "__main__":
    sys.exit(main())
