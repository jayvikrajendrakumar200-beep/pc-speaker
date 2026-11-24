#!/usr/bin/env python3
"""
Generate iOS app icons from SVG
Requires: pip install cairosvg pillow
"""

import os
import sys
from pathlib import Path

try:
    import cairosvg
    from PIL import Image
except ImportError:
    print("Installing dependencies...")
    import subprocess
    subprocess.check_call([sys.executable, "-m", "pip", "install", "cairosvg", "pillow"])
    import cairosvg
    from PIL import Image

# Icon sizes needed for iOS
ICON_SIZES = [
    (20, 2, "icon-20@2x.png"),
    (20, 3, "icon-20@3x.png"),
    (29, 1, "icon-29.png"),
    (29, 2, "icon-29@2x.png"),
    (29, 3, "icon-29@3x.png"),
    (40, 2, "icon-40@2x.png"),
    (40, 3, "icon-40@3x.png"),
    (60, 2, "icon-60@2x.png"),
    (60, 3, "icon-60@3x.png"),
    (1024, 1, "icon-1024.png"),
]

def main():
    svg_path = Path("assets/icon.svg")
    output_dir = Path("ios/Runner/Assets.xcassets/AppIcon.appiconset")

    if not svg_path.exists():
        print(f"SVG not found: {svg_path}")
        return 1

    output_dir.mkdir(parents=True, exist_ok=True)

    print(f"Generating icons from {svg_path}...")
    for base_size, scale, filename in ICON_SIZES:
        size = base_size * scale
        output_path = output_dir / filename

        # Convert SVG to PNG
        png_data = cairosvg.svg2png(
            url=str(svg_path),
            output_width=size,
            output_height=size,
        )

        # Save with PIL for better quality
        img = Image.open(cairosvg.svg2png(url=str(svg_path), output_width=size, output_height=size))
        img.save(output_path, optimize=True)

        print(f"  ✓ {filename} ({size}x{size})")

    print(f"\nDone! Icons saved to {output_dir}")
    return 0

if __name__ == "__main__":
    sys.exit(main())