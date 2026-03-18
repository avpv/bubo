#!/usr/bin/env python3
"""Generate AppIcon.icns for Bubo from owl.svg.

Uses cairosvg to render the SVG at each required resolution for
crisp vector-quality icons at every size.

The .icns format is documented by Apple. We pack PNG data for each
required size into the correct icon types.
"""

import struct
import io
import os
import cairosvg
from PIL import Image

# icns type codes mapped to pixel sizes (only PNG-based types, macOS 10.7+)
ICNS_TYPES = [
    (b'ic07', 128),    # 128x128
    (b'ic08', 256),    # 256x256
    (b'ic09', 512),    # 512x512
    (b'ic10', 1024),   # 1024x1024 (512x512@2x)
    (b'ic11', 32),     # 16x16@2x
    (b'ic12', 64),     # 32x32@2x
    (b'ic13', 256),    # 128x128@2x
    (b'ic14', 512),    # 256x256@2x
]

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(SCRIPT_DIR)
SVG_PATH = os.path.join(PROJECT_DIR, 'Bubo', 'Resources', 'owl.svg')


def render_svg_to_png(size: int) -> bytes:
    """Render owl.svg to PNG bytes at the given pixel size."""
    return cairosvg.svg2png(
        url=SVG_PATH,
        output_width=size,
        output_height=size,
    )


def build_icns(output_path: str):
    """Build an .icns file from SVG-rendered icons."""
    size_to_png = {}
    entries = []
    for type_code, pixel_size in ICNS_TYPES:
        if pixel_size not in size_to_png:
            size_to_png[pixel_size] = render_svg_to_png(pixel_size)
        png_data = size_to_png[pixel_size]
        entries.append((type_code, png_data))

    # Build icns binary
    # Header: 'icns' + total file length (4 bytes each)
    # Each entry: type (4 bytes) + entry length (4 bytes) + data
    body = b''
    for type_code, png_data in entries:
        entry_len = 8 + len(png_data)
        body += type_code + struct.pack('>I', entry_len) + png_data

    total_len = 8 + len(body)
    icns_data = b'icns' + struct.pack('>I', total_len) + body

    with open(output_path, 'wb') as f:
        f.write(icns_data)

    print(f"Created {output_path} ({total_len:,} bytes)")

    # Also save a preview PNG
    preview_path = output_path.replace('.icns', '_preview.png')
    preview_png = render_svg_to_png(512)
    with open(preview_path, 'wb') as f:
        f.write(preview_png)
    print(f"Saved preview PNG")


if __name__ == '__main__':
    os.makedirs(os.path.join(PROJECT_DIR, 'Bubo', 'Resources'), exist_ok=True)
    build_icns(os.path.join(PROJECT_DIR, 'Bubo', 'Resources', 'AppIcon.icns'))
