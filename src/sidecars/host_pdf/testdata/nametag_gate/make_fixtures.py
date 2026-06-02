#!/usr/bin/env python3
"""Generate committable fixtures for the nametag pixel-diff gate.

Produces:
  - sample.xlsx : 8 rows, EXACT columns Name / Class / Group # / Room Assignment.
                  Mix of short and deliberately long names so the auto-shrink
                  (fit) path in _draw_name is exercised.
  - icon.png    : a tiny 64x64 PNG (simple shapes, opaque).

Run with the gate venv's python. Idempotent.
"""
import os
from openpyxl import Workbook
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))

# 8 rows. Long names (e.g. row 2, 5, 8) overflow the ~225pt content width at
# 20pt DejaVu Bold, forcing the shrink loop down toward the 12pt floor.
ROWS = [
    # Name, Class, Group #, Room Assignment
    ("Ada",                              "Math 1",  1, "A101"),
    ("Maximilian Hohenzollern-Sigmaringen", "Physics", 2, "B205"),
    ("Bob Smith",                        "Chem",    3, "C300"),
    ("Grace Hopper",                     "CS 200",  1, "A101"),
    ("Wolfgang Amadeus Mozart-Beethoven", "Music",  2, "D404"),
    ("Liu",                              "Art",     3, "E12"),
    ("Katherine Johnson",                "Math 2",  1, "A102"),
    ("Bartholomew Featherstonehaugh III", "History", 2, "F555"),
]


def make_xlsx(path):
    wb = Workbook()
    ws = wb.active
    ws.append(["Name", "Class", "Group #", "Room Assignment"])
    for r in ROWS:
        ws.append(list(r))
    wb.save(path)


def make_icon(path):
    img = Image.new("RGB", (64, 64), (255, 255, 255))
    d = ImageDraw.Draw(img)
    d.ellipse([4, 4, 59, 59], fill=(30, 120, 200), outline=(10, 40, 90), width=3)
    d.rectangle([22, 22, 41, 41], fill=(250, 220, 40))
    img.save(path, "PNG")


if __name__ == "__main__":
    make_xlsx(os.path.join(HERE, "sample.xlsx"))
    make_icon(os.path.join(HERE, "icon.png"))
    print("wrote sample.xlsx and icon.png to", HERE)
