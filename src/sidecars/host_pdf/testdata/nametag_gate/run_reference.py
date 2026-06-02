#!/usr/bin/env python3
"""Produce reference.pdf from the ORIGINAL generate_tags.py, unmodified in logic.

The only adaptation: generate_tags.py hardcodes Ubuntu system font paths
(/usr/share/fonts/.../DejaVuSans*.ttf) which do not exist on macOS. We monkey-
patch those two module-level constants to point at the SAME DejaVu TTFs the Go
sidecar bundles (src/sidecars/host_pdf/fonts/), so both the reference and the
candidate render with byte-identical font files. No layout/render code is
touched. This is the documented font-portability fix the contract calls out (§4).
"""
import os
import sys
import importlib.util

HERE = os.path.dirname(os.path.abspath(__file__))
SIDECAR = os.path.abspath(os.path.join(HERE, "..", ".."))
FONTS = os.path.join(SIDECAR, "fonts")
REF_TOOL = os.path.expanduser(
    "~/gitlab/minervaservices/experiments/NameTagMaker/generate_tags.py"
)

# Import the original module by path.
spec = importlib.util.spec_from_file_location("generate_tags", REF_TOOL)
gt = importlib.util.module_from_spec(spec)
sys.modules["generate_tags"] = gt
spec.loader.exec_module(gt)

# Repoint the two font-path constants to the bundled DejaVu TTFs (identical files).
gt.DEJAVU_REGULAR = os.path.join(FONTS, "DejaVuSans.ttf")
gt.DEJAVU_BOLD = os.path.join(FONTS, "DejaVuSans-Bold.ttf")
assert os.path.exists(gt.DEJAVU_REGULAR), gt.DEJAVU_REGULAR
assert os.path.exists(gt.DEJAVU_BOLD), gt.DEJAVU_BOLD

excel = os.path.join(HERE, "sample.xlsx")
icon = os.path.join(HERE, "icon.png")
out = os.path.join(HERE, "reference.pdf")

tag_data = gt.load_tag_data(excel)
print(f"loaded {len(tag_data)} tags")
layout = gt.LayoutConfig.cardstock_4x2()
generator = gt.NameTagPDFGenerator(layout, icon, 0.40)
generator.generate(tag_data, out, back_mode="same", back_offset_x=0.0,
                   back_offset_y=0.0, full_guides=False)
print("wrote", out)
