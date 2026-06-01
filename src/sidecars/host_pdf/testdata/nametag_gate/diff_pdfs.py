#!/usr/bin/env python3
"""Pixel-diff two PDFs page-by-page at 150 DPI.

Rasterizes reference.pdf (fpdf2) and candidate.pdf (gofpdf via the host.pdf
contract) with PyMuPDF (fitz), forces both pages of a pair to identical pixel
dimensions, and reports per-page + overall:
  - mean absolute pixel difference (0-255)
  - max pixel difference (0-255)
  - % of pixels differing by more than TOL (default 16/255)

Exit code is always 0; this tool REPORTS numbers, it does not gate. The gate
decision (PASS/FALLBACK) is made by a human from these numbers.
"""
import os
import sys

import fitz  # PyMuPDF
from PIL import Image
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
DPI = 150
TOL = 16  # per-channel difference (0-255) considered "meaningful"


def render_pages(path, dpi):
    doc = fitz.open(path)
    imgs = []
    for page in doc:
        zoom = dpi / 72.0
        pix = page.get_pixmap(matrix=fitz.Matrix(zoom, zoom), colorspace=fitz.csRGB, alpha=False)
        img = Image.frombytes("RGB", (pix.width, pix.height), pix.samples)
        imgs.append(img)
    return imgs


def to_same_size(a, b):
    if a.size == b.size:
        return a, b
    w = min(a.size[0], b.size[0])
    h = min(a.size[1], b.size[1])
    return a.crop((0, 0, w, h)), b.crop((0, 0, w, h))


def main():
    ref_path = os.path.join(HERE, "reference.pdf")
    cand_path = os.path.join(HERE, "candidate.pdf")
    for p in (ref_path, cand_path):
        if not os.path.exists(p):
            print(f"missing {p}", file=sys.stderr)
            sys.exit(2)

    ref = render_pages(ref_path, DPI)
    cand = render_pages(cand_path, DPI)

    print(f"reference.pdf: {len(ref)} pages   candidate.pdf: {len(cand)} pages   @ {DPI} DPI")
    npages = min(len(ref), len(cand))
    if len(ref) != len(cand):
        print(f"WARNING: page-count mismatch ({len(ref)} vs {len(cand)})")

    print()
    hdr = f"{'page':>4} | {'dims':>12} | {'mean_abs':>9} | {'max':>4} | {'pct>%d/255' % TOL:>11}"
    print(hdr)
    print("-" * len(hdr))

    all_ref = []
    all_cand = []
    for i in range(npages):
        ra, ca = to_same_size(ref[i], cand[i])
        # save rasterized PNGs for inspection (gitignored)
        ra.save(os.path.join(HERE, f"page{i}_reference.png"))
        ca.save(os.path.join(HERE, f"page{i}_candidate.png"))
        ar = np.asarray(ra, dtype=np.int16)
        ac = np.asarray(ca, dtype=np.int16)
        diff = np.abs(ar - ac)
        mean_abs = diff.mean()
        mx = int(diff.max())
        # per-pixel max-channel diff for the tolerance metric
        per_pixel = diff.max(axis=2)
        pct = 100.0 * (per_pixel > TOL).sum() / per_pixel.size
        print(f"{i:>4} | {ra.size[0]:>5}x{ra.size[1]:<6} | {mean_abs:>9.4f} | {mx:>4} | {pct:>10.4f}%")
        # diff heat image (amplified) for inspection
        heat = np.clip(diff.sum(axis=2), 0, 255).astype("uint8")
        Image.fromarray(heat, mode="L").save(os.path.join(HERE, f"page{i}_diff.png"))
        all_ref.append(ar)
        all_cand.append(ac)

    print("-" * len(hdr))
    AR = np.concatenate([a.reshape(-1) for a in all_ref])
    AC = np.concatenate([a.reshape(-1) for a in all_cand])
    D = np.abs(AR - AC)
    overall_mean = D.mean()
    overall_max = int(D.max())
    overall_pct = 100.0 * (D > TOL).sum() / D.size
    print(f"OVERALL mean_abs={overall_mean:.4f}  max={overall_max}  pct>{TOL}/255={overall_pct:.4f}%")


if __name__ == "__main__":
    main()
