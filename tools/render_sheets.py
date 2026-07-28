#!/usr/bin/env python3
"""Render pages of the reference schematic PDFs to PNG.

poppler (pdftoppm) is not available on this machine, so the usual PDF page
rendering path does not work. pypdfium2 + Pillow do, and give better results
anyway: the D-size sheets are legible at scale=400/72 (6800x4400).

Examples
--------
    # whole sheet, one PNG
    python tools/render_sheets.py buck 45

    # a range, tiled 4x3 with overlap so each tile is readable on its own
    python tools/render_sheets.py buck 45-47 --tile 4x3

    # zoom in on one region (fractions of the page) at higher DPI
    python tools/render_sheets.py buck 47 --scale 800 --crop 0.5,0.0,0.8,0.4

Page numbers are 1-based PDF pages, not the printed page numbers in the manual.
For Buck_Schematics.pdf, printed page = PDF page + 146.

Known landmarks in Buck_Schematics.pdf:
    1-16    theory of operation (text)
    20      Sound Board assembly drawing (all R/C values)
    29-34   CPU board 834-5120 schematic sheets
    35-44   EPROM board 834-5121 schematic sheets
    45-47   Sound board 834-5122 schematic sheets 1-3
"""

import argparse
import sys
from pathlib import Path

import pypdfium2 as pdfium

REPO = Path(__file__).resolve().parent.parent
REFERENCE = REPO / "docs" / "reference"

PDFS = {
    "buck": REFERENCE / "Buck_Schematics.pdf",
    "turbo": REFERENCE / "Turbo_Schematics.pdf",
}


def parse_pages(spec):
    """"45" -> [45]; "45-47" -> [45, 46, 47]; "20,45-46" -> [20, 45, 46]."""
    pages = []
    for part in spec.split(","):
        if "-" in part:
            lo, hi = part.split("-")
            pages.extend(range(int(lo), int(hi) + 1))
        else:
            pages.append(int(part))
    return pages


def parse_tile(spec):
    cols, rows = spec.lower().split("x")
    return int(cols), int(rows)


def parse_crop(spec):
    values = [float(v) for v in spec.split(",")]
    if len(values) != 4:
        raise ValueError("--crop wants x0,y0,x1,y1 as fractions of the page")
    return values


def render(pdf_key, pages, outdir, scale, tile, crop, overlap):
    path = PDFS[pdf_key]
    if not path.exists():
        sys.exit(f"missing {path}")

    pdf = pdfium.PdfDocument(str(path))
    outdir.mkdir(parents=True, exist_ok=True)
    written = []

    for page_no in pages:
        if not 1 <= page_no <= len(pdf):
            print(f"skipping page {page_no}: out of range (1-{len(pdf)})")
            continue

        try:
            image = pdf[page_no - 1].render(scale=scale / 72).to_pil()
        except pdfium.PdfiumError as exc:
            print(f"skipping page {page_no}: {exc}")
            continue

        width, height = image.size
        stem = f"{pdf_key}_p{page_no:02d}"

        if crop:
            x0, y0, x1, y1 = crop
            image = image.crop(
                (int(x0 * width), int(y0 * height), int(x1 * width), int(y1 * height))
            )
            width, height = image.size
            stem += "_crop"

        if tile:
            cols, rows = tile
            for row in range(rows):
                for col in range(cols):
                    x0 = max(0, int(col * width / cols) - overlap)
                    x1 = min(width, int((col + 1) * width / cols) + overlap)
                    y0 = max(0, int(row * height / rows) - overlap)
                    y1 = min(height, int((row + 1) * height / rows) + overlap)
                    out = outdir / f"{stem}_r{row}c{col}.png"
                    image.crop((x0, y0, x1, y1)).save(out)
                    written.append(out)
        else:
            out = outdir / f"{stem}.png"
            image.save(out)
            written.append(out)

    for out in written:
        print(out.relative_to(REPO))
    return written


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("pdf", choices=sorted(PDFS), help="which reference PDF")
    parser.add_argument("pages", help="1-based PDF page(s), e.g. 45 or 45-47 or 20,45")
    parser.add_argument("--out", default=None,
                        help="output directory (default docs/schematics)")
    parser.add_argument("--scale", type=float, default=400,
                        help="render DPI; 400 is legible for D-size sheets, 800 to zoom")
    parser.add_argument("--tile", type=parse_tile, default=None,
                        help="split each page into COLSxROWS overlapping tiles, e.g. 4x3")
    parser.add_argument("--crop", type=parse_crop, default=None,
                        help="crop to x0,y0,x1,y1 as fractions of the page before tiling")
    parser.add_argument("--overlap", type=int, default=140,
                        help="tile overlap in pixels, so nothing is lost at a seam")
    args = parser.parse_args()

    outdir = Path(args.out) if args.out else REPO / "docs" / "schematics"
    render(args.pdf, parse_pages(args.pages), outdir, args.scale,
           args.tile, args.crop, args.overlap)


if __name__ == "__main__":
    main()
