#!/usr/bin/env python3
"""Generate AppIcon.icns for CalendarReminder using only Pillow.

Renders an owl icon matching the owl.svg design:
- Dark purple rounded-rect background (#1B1464)
- Tan/orange owl body
- White eyes with dark pupils
- Orange beak, feet, and ear tufts

The .icns format is documented by Apple. We pack PNG data for each
required size into the correct icon types.
"""

import struct
import io
import math
from PIL import Image, ImageDraw

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

# Colors from owl.svg
BG_COLOR = (27, 20, 100, 255)       # #1B1464
BODY_COLOR = (248, 194, 145, 255)   # #F8C291
BELLY_COLOR = (232, 168, 124, 255)  # #E8A87C
EYE_WHITE = (255, 255, 255, 255)
PUPIL_COLOR = (27, 20, 100, 255)    # #1B1464
HIGHLIGHT_COLOR = (255, 255, 255, 255)
BEAK_COLOR = (255, 99, 72, 255)     # #FF6348
FEET_COLOR = (255, 99, 72, 255)     # #FF6348


def render_icon(size: int) -> Image.Image:
    """Render the owl icon at the given pixel size, matching owl.svg."""
    s = size
    img = Image.new('RGBA', (s, s), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # Helper: rounded rectangle
    def rounded_rect(xy, radius, fill):
        x0, y0, x1, y1 = [int(v) for v in xy]
        r = int(radius)
        r = min(r, (x1 - x0) // 2, (y1 - y0) // 2)
        if r < 1:
            draw.rectangle([x0, y0, x1, y1], fill=fill)
            return
        draw.ellipse([x0, y0, x0 + 2*r, y0 + 2*r], fill=fill)
        draw.ellipse([x1 - 2*r, y0, x1, y0 + 2*r], fill=fill)
        draw.ellipse([x0, y1 - 2*r, x0 + 2*r, y1], fill=fill)
        draw.ellipse([x1 - 2*r, y1 - 2*r, x1, y1], fill=fill)
        draw.rectangle([x0 + r, y0, x1 - r, y1], fill=fill)
        draw.rectangle([x0, y0 + r, x1, y1 - r], fill=fill)

    # SVG viewBox is 680x680, icon content in rect at (90,90) 500x500
    # Owl centered at (340, 360) in viewBox
    # We map to our size with some padding

    pad = s * 0.13  # padding around the background
    bg_size = s - 2 * pad
    corner_r = bg_size * 0.22  # rx=110 out of 500

    # 1. Dark purple rounded background
    rounded_rect((pad, pad, s - pad, s - pad), corner_r, fill=BG_COLOR)

    # Center of owl in our coordinate system
    # SVG center is at (340, 360) within 680x680 viewBox
    # Background rect is (90,90)-(590,590)
    # So owl center relative to bg rect: (250/500, 270/500) = (0.5, 0.54)
    cx = pad + bg_size * 0.5
    cy = pad + bg_size * 0.54

    # Scale factor: SVG owl coords are roughly ±130 pixels in a 500px box
    scale = bg_size / 500.0

    def sx(v):
        """Scale SVG x coordinate (relative to center 340,360)."""
        return cx + (v) * scale

    def sy(v):
        """Scale SVG y coordinate (relative to center 340,360)."""
        return cy + (v) * scale

    # 2. Main body ellipse: cx=0, cy=30, rx=110, ry=130
    body_x0 = sx(-110)
    body_y0 = sy(30 - 130)
    body_x1 = sx(110)
    body_y1 = sy(30 + 130)
    draw.ellipse([body_x0, body_y0, body_x1, body_y1], fill=BODY_COLOR)

    # 3. Belly ellipse: cx=0, cy=50, rx=85, ry=90
    draw.ellipse([sx(-85), sy(50-90), sx(85), sy(50+90)], fill=BELLY_COLOR)

    # 4. Left eye area: cx=-50, cy=-60, rx=50, ry=55
    draw.ellipse([sx(-50-50), sy(-60-55), sx(-50+50), sy(-60+55)], fill=BODY_COLOR)

    # 5. Right eye area: cx=50, cy=-60, rx=50, ry=55
    draw.ellipse([sx(50-50), sy(-60-55), sx(50+50), sy(-60+55)], fill=BODY_COLOR)

    # 6. Left eye white: cx=-50, cy=-60, r=36
    draw.ellipse([sx(-50-36), sy(-60-36), sx(-50+36), sy(-60+36)], fill=EYE_WHITE)

    # 7. Right eye white: cx=50, cy=-60, r=36
    draw.ellipse([sx(50-36), sy(-60-36), sx(50+36), sy(-60+36)], fill=EYE_WHITE)

    # 8. Left pupil: cx=-50, cy=-55, r=18
    draw.ellipse([sx(-50-18), sy(-55-18), sx(-50+18), sy(-55+18)], fill=PUPIL_COLOR)

    # 9. Right pupil: cx=50, cy=-55, r=18
    draw.ellipse([sx(50-18), sy(-55-18), sx(50+18), sy(-55+18)], fill=PUPIL_COLOR)

    # 10. Left eye highlight: cx=-44, cy=-60, r=6
    draw.ellipse([sx(-44-6), sy(-60-6), sx(-44+6), sy(-60+6)], fill=HIGHLIGHT_COLOR)

    # 11. Right eye highlight: cx=56, cy=-60, r=6
    draw.ellipse([sx(56-6), sy(-60-6), sx(56+6), sy(-60+6)], fill=HIGHLIGHT_COLOR)

    # 12. Beak: M-8,-20 L0,-8 L8,-20
    beak_points = [(sx(-8), sy(-20)), (sx(0), sy(-8)), (sx(8), sy(-20))]
    draw.polygon(beak_points, fill=BEAK_COLOR)

    # 13. Left wing: M-65,15 L-120,-10 L-60,35
    left_wing = [(sx(-65), sy(15)), (sx(-120), sy(-10)), (sx(-60), sy(35))]
    draw.polygon(left_wing, fill=BELLY_COLOR)

    # 14. Right wing: M65,15 L120,-10 L60,35
    right_wing = [(sx(65), sy(15)), (sx(120), sy(-10)), (sx(60), sy(35))]
    draw.polygon(right_wing, fill=BELLY_COLOR)

    # 15. Left foot: M-30,140 L-20,160 L-10,140
    left_foot = [(sx(-30), sy(140)), (sx(-20), sy(160)), (sx(-10), sy(140))]
    draw.polygon(left_foot, fill=FEET_COLOR)

    # 16. Right foot: M10,140 L20,160 L30,140
    right_foot = [(sx(10), sy(140)), (sx(20), sy(160)), (sx(30), sy(140))]
    draw.polygon(right_foot, fill=FEET_COLOR)

    # 17. Left ear tuft (stroke in SVG, draw as lines)
    if s >= 64:
        ear_width = max(1, int(6 * scale))
        # Left: M-70,-105 L-45,-130 L-20,-100
        draw.line([(sx(-70), sy(-105)), (sx(-45), sy(-130)), (sx(-20), sy(-100))],
                  fill=BODY_COLOR, width=ear_width)
        # Right: M70,-105 L45,-130 L20,-100
        draw.line([(sx(70), sy(-105)), (sx(45), sy(-130)), (sx(20), sy(-100))],
                  fill=BODY_COLOR, width=ear_width)

    # 18. Decorative stars (small white dots)
    if s >= 128:
        star_positions = [
            (-180, -200), (-140, -160), (180, -190), (150, -150),
            (-190, 40), (190, 80), (-160, 140), (160, 140),
        ]
        star_r = max(1, int(2 * scale))
        star_color = (255, 255, 255, 38)  # opacity 0.15
        for sx_off, sy_off in star_positions:
            x, y = sx(sx_off), sy(sy_off)
            draw.ellipse([x - star_r, y - star_r, x + star_r, y + star_r],
                         fill=star_color)

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
    preview = render_icon(512)
    preview.save(output_path.replace('.icns', '_preview.png'))
    print(f"Saved preview PNG")


if __name__ == '__main__':
    import os
    os.makedirs('CalendarReminder/Resources', exist_ok=True)
    build_icns('CalendarReminder/Resources/AppIcon.icns')
