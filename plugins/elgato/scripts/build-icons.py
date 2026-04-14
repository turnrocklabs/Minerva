#!/usr/bin/env python3
"""
Build Stream Deck plugin icons for Minerva.

Generates 7 × 72×72 px PNG icons from Minerva's existing icon sources.
All icons use centered glyphs on color-filled backgrounds.

Requirements:
  - Pillow (PIL): pip install pillow
  - For SVG support: cairosvg (pip install cairosvg) or rsvg-convert CLI
"""

import os
import sys
import subprocess
import tempfile
from pathlib import Path
from PIL import Image, ImageDraw

# ============================================================================
# Configuration
# ============================================================================

# Output icon size in pixels
ICON_SIZE = 72

# Glyph target size (leaves ~14px margin all around on 72×72 canvas)
GLYPH_SIZE = 44

# Colors (RGB tuples, will be converted to RGBA)
COLOR_DARK_NEUTRAL = (0x1E, 0x21, 0x28)  # Dark grey: #1E2128
COLOR_LIME_GREEN = (0x32, 0xCD, 0x32)   # Godot Color.LIME_GREEN: #32CD32
COLOR_AMBER = (0xE0, 0xA0, 0x20)        # Amber: #E0A020
COLOR_RED = (0xCC, 0x20, 0x20)          # Red (error): #CC2020

# Source icon paths (relative to repo root)
SOURCES = {
    "mic": "src/assets/icons/mic_icons/microphone_68.png",
    "speaker": "src/assets/icons/speaker-24.png",
    "send": "src/assets/icons/send_icons/send_icon_48_no_bg.png",
    "clear_svg": "src/assets/icons/line_edit_clear.svg",
}

# Output paths (relative to this script's directory)
OUTPUT_DIR = Path(__file__).parent.parent / "assets"


# ============================================================================
# Utility Functions
# ============================================================================

def find_repo_root():
    """Find Minerva repo root by walking up from this script."""
    path = Path(__file__).resolve()
    while path != path.parent:
        if (path / ".git").exists() or (path / "CLAUDE.md").exists():
            return path
        path = path.parent
    raise RuntimeError("Cannot find Minerva repo root")


def draw_clear_icon(width, height):
    """
    Draw a simple × (X) clear icon manually.
    Matches the line_edit_clear.svg visual (white X on transparent).
    """
    img = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    # Draw diagonal lines forming an X
    margin = 3
    x0, y0 = margin, margin
    x1, y1 = width - margin, height - margin
    # Line width as integer
    draw.line((x0, y0, x1, y1), fill=(255, 255, 255, 191), width=2)
    draw.line((x1, y0, x0, y1), fill=(255, 255, 255, 191), width=2)
    return img


def svg_to_png_rsvg(svg_path, width, height):
    """
    Convert SVG to PNG using rsvg-convert CLI.
    Returns PIL Image or None if rsvg-convert unavailable.
    """
    try:
        with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as tmp:
            tmp_path = tmp.name

        subprocess.run(
            ["rsvg-convert", "-w", str(width), "-h", str(height), str(svg_path), "-o", tmp_path],
            check=True,
            capture_output=True,
        )
        img = Image.open(tmp_path).convert("RGBA")
        os.unlink(tmp_path)
        return img
    except (FileNotFoundError, subprocess.CalledProcessError):
        return None


def load_glyph(source_path, target_size=GLYPH_SIZE):
    """
    Load a glyph from a PNG or SVG source, scale to target size,
    and return as RGBA PIL Image.
    """
    source_path = Path(source_path)

    if source_path.suffix.lower() == ".svg":
        # Try rsvg-convert first, then fallback to manual drawing
        img = svg_to_png_rsvg(source_path, target_size, target_size)
        if img is None:
            print(f"  Warning: rsvg-convert not available; drawing placeholder X for {source_path.name}")
            img = draw_clear_icon(target_size, target_size)
    else:
        # PNG: load and convert to RGBA
        img = Image.open(source_path).convert("RGBA")
        # Scale to target size using LANCZOS for quality
        img = img.resize((target_size, target_size), Image.Resampling.LANCZOS)

    return img


def create_icon(glyph_img, bg_color):
    """
    Create a 72×72 icon with the glyph centered on a solid background.

    Args:
        glyph_img: PIL Image (RGBA) of the glyph
        bg_color: RGB tuple (r, g, b)

    Returns:
        PIL Image (RGBA) of the final icon
    """
    # Create canvas with background color
    canvas = Image.new("RGBA", (ICON_SIZE, ICON_SIZE), bg_color + (255,))

    # Calculate centering offset
    glyph_w, glyph_h = glyph_img.size
    offset_x = (ICON_SIZE - glyph_w) // 2
    offset_y = (ICON_SIZE - glyph_h) // 2

    # Composite glyph onto canvas
    canvas.paste(glyph_img, (offset_x, offset_y), glyph_img)

    return canvas


def verify_icon(icon_path):
    """
    Verify icon dimensions and report pixel-level sanity checks.
    """
    img = Image.open(icon_path)
    print(f"  ✓ {icon_path.name}: {img.size} {img.mode}")

    # Sample corner pixels to verify background color
    try:
        pixel = img.getpixel((0, 0))
        print(f"    Corner pixel (0,0): {pixel}")
    except Exception as e:
        print(f"    (Could not sample pixel: {e})")


# ============================================================================
# Main Build
# ============================================================================

def main():
    # Find repo root
    try:
        repo_root = find_repo_root()
    except RuntimeError as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)

    print(f"Building Stream Deck icons for Minerva")
    print(f"Repo root: {repo_root}")
    print(f"Output dir: {OUTPUT_DIR}")
    print()

    # Verify output directory
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    # Load source glyphs
    print("Loading source glyphs...")
    try:
        mic_glyph = load_glyph(repo_root / SOURCES["mic"])
        print(f"  ✓ Microphone: {mic_glyph.size}")

        speaker_glyph = load_glyph(repo_root / SOURCES["speaker"])
        print(f"  ✓ Speaker: {speaker_glyph.size}")

        send_glyph = load_glyph(repo_root / SOURCES["send"])
        print(f"  ✓ Send: {send_glyph.size}")

        clear_glyph = load_glyph(repo_root / SOURCES["clear_svg"])
        print(f"  ✓ Clear (from SVG): {clear_glyph.size}")
    except Exception as e:
        print(f"Error loading glyphs: {e}", file=sys.stderr)
        sys.exit(1)

    print()
    print("Generating icons...")

    # Generate the 7 icons
    icons = [
        ("ptt-idle.png", mic_glyph, COLOR_DARK_NEUTRAL),
        ("ptt-recording.png", mic_glyph, COLOR_LIME_GREEN),
        ("ptt-transcribing.png", mic_glyph, COLOR_AMBER),
        ("ptt-error.png", mic_glyph, COLOR_RED),
        ("mic.png", mic_glyph, COLOR_DARK_NEUTRAL),
        ("speaker.png", speaker_glyph, COLOR_DARK_NEUTRAL),
        ("clear.png", clear_glyph, COLOR_DARK_NEUTRAL),
        ("submit.png", send_glyph, COLOR_DARK_NEUTRAL),
    ]

    for filename, glyph, bg_color in icons:
        output_path = OUTPUT_DIR / filename
        icon = create_icon(glyph, bg_color)
        icon.save(output_path, "PNG")
        print(f"  ✓ Created {filename}")

    print()
    print("Verifying output...")
    for filename, _, _ in icons:
        verify_icon(OUTPUT_DIR / filename)

    print()
    print(f"Success! All {len(icons)} icons created in {OUTPUT_DIR}")


if __name__ == "__main__":
    main()
