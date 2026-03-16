#!/usr/bin/env python3
"""Generate AppIcon.icns for CalendarReminder using only Pillow.

The .icns format is documented by Apple. We pack PNG data for each
required size into the correct icon types.
"""

import struct
import io
from PIL import Image, ImageDraw, ImageFont

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


def render_icon(size: int) -> Image.Image:
    """Render the calendar icon at the given pixel size."""
    s = size
    img = Image.new('RGBA', (s, s), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # Rounded rectangle helper
    def rounded_rect(xy, radius, fill):
        x0, y0, x1, y1 = xy
        r = int(radius)
        # Draw using ellipses at corners + rectangles
        draw.ellipse([x0, y0, x0 + 2*r, y0 + 2*r], fill=fill)
        draw.ellipse([x1 - 2*r, y0, x1, y0 + 2*r], fill=fill)
        draw.ellipse([x0, y1 - 2*r, x0 + 2*r, y1], fill=fill)
        draw.ellipse([x1 - 2*r, y1 - 2*r, x1, y1], fill=fill)
        draw.rectangle([x0 + r, y0, x1 - r, y1], fill=fill)
        draw.rectangle([x0, y0 + r, x1, y1 - r], fill=fill)

    # 1. Blue rounded background
    bg_radius = s * 0.18
    rounded_rect((0, 0, s, s), bg_radius, fill=(26, 115, 232, 255))

    # 2. White calendar body
    margin_x = int(s * 0.13)
    body_top = int(s * 0.28)
    body_bottom = int(s * 0.87)
    body_radius = s * 0.06
    rounded_rect(
        (margin_x, body_top, s - margin_x, body_bottom),
        body_radius,
        fill=(255, 255, 255, 255)
    )

    # 3. Dark blue calendar header
    header_top = int(s * 0.18)
    header_bottom = int(s * 0.40)
    rounded_rect(
        (margin_x, header_top, s - margin_x, header_bottom),
        body_radius,
        fill=(21, 87, 176, 255)
    )
    # Fill bottom of header (squared off where it meets body)
    draw.rectangle(
        [margin_x, int(s * 0.32), s - margin_x, header_bottom],
        fill=(21, 87, 176, 255)
    )

    # 4. Calendar ring/pins
    pin_width = max(2, int(s * 0.045))
    pin_height = max(4, int(s * 0.12))
    pin_radius = pin_width // 2
    for pin_cx in [int(s * 0.30), int(s * 0.70)]:
        pin_top = int(s * 0.12)
        px0 = pin_cx - pin_width
        px1 = pin_cx + pin_width
        rounded_rect(
            (px0, pin_top, px1, pin_top + pin_height),
            pin_radius,
            fill=(255, 255, 255, 255)
        )

    # 5. Letter "C" centered on calendar body
    font_size = max(10, int(s * 0.34))
    try:
        font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", font_size)
    except (OSError, IOError):
        try:
            font = ImageFont.truetype("/usr/share/fonts/TTF/DejaVuSans-Bold.ttf", font_size)
        except (OSError, IOError):
            font = ImageFont.load_default()

    text = "C"
    bbox = draw.textbbox((0, 0), text, font=font)
    tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
    text_area_top = int(s * 0.40)
    text_area_bottom = int(s * 0.87)
    tx = (s - tw) // 2
    ty = text_area_top + (text_area_bottom - text_area_top - th) // 2
    draw.text((tx, ty), text, fill=(26, 115, 232, 255), font=font)

    # 6. Small grid dots on calendar (3x2 grid below header)
    if s >= 64:
        dot_r = max(1, int(s * 0.018))
        grid_top = int(s * 0.44)
        grid_bottom = int(s * 0.54)
        grid_left = int(s * 0.22)
        grid_right = int(s * 0.78)
        for row in range(2):
            for col in range(3):
                cx = grid_left + col * (grid_right - grid_left) // 2
                cy = grid_top + row * (grid_bottom - grid_top)
                # Skip dots that overlap with the "C" letter area
                # (these are decorative, only show in corners)

    return img


def image_to_png_bytes(img: Image.Image) -> bytes:
    buf = io.BytesIO()
    img.save(buf, format='PNG')
    return buf.getvalue()


def build_icns(output_path: str):
    """Build an .icns file from rendered icons."""
    size_to_png = {}
    entries = []
    for type_code, pixel_size in ICNS_TYPES:
        if pixel_size not in size_to_png:
            img = render_icon(pixel_size)
            size_to_png[pixel_size] = image_to_png_bytes(img)
        png_data = size_to_png[pixel_size]
        entries.append((type_code, png_data))

    # Build icns binary
    # Header: 'icns' + total file length (4 bytes each)
    # Each entry: type (4 bytes) + entry length (4 bytes) + data
    body = b''
    for type_code, png_data in entries:
        entry_len = 8 + len(png_data)  # 4 type + 4 length + data
        body += type_code + struct.pack('>I', entry_len) + png_data

    total_len = 8 + len(body)  # 4 magic + 4 length + body
    icns_data = b'icns' + struct.pack('>I', total_len) + body

    with open(output_path, 'wb') as f:
        f.write(icns_data)

    print(f"Created {output_path} ({total_len:,} bytes)")

    # Also save a preview PNG
    preview = render_icon(512)
    preview.save(output_path.replace('.icns', '_preview.png'))
    print(f"Saved preview PNG")


if __name__ == '__main__':
    import os
    os.makedirs('CalendarReminder/Resources', exist_ok=True)
    build_icns('CalendarReminder/Resources/AppIcon.icns')
