#!/usr/bin/env python3
"""Generate a Retina background image for the Owlenda DMG installer.

Creates a clean, modern background with a drag-to-install arrow
between the app icon and Applications folder positions.

The image is generated at 2x resolution (144 DPI) for crisp
Retina display. Window size: 660x400 → image: 1320x800 pixels.
"""

import os
import math
from PIL import Image, ImageDraw, ImageFont

# Window dimensions (points)
WIN_W, WIN_H = 660, 400

# Retina 2x
SCALE = 2
IMG_W, IMG_H = WIN_W * SCALE, WIN_H * SCALE

# Icon center positions (points) — must match create-dmg --icon / --app-drop-link
APP_X, APP_Y = 180, 200
DROP_X, DROP_Y = 480, 200

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(SCRIPT_DIR)
OUTPUT_DIR = os.path.join(PROJECT_DIR, "Owlenda", "Resources")


def draw_arrow(draw, x1, y1, x2, y2, color, width=3, head_size=14):
    """Draw an arrow from (x1,y1) to (x2,y2) in scaled coordinates."""
    sx1, sy1 = x1 * SCALE, y1 * SCALE
    sx2, sy2 = x2 * SCALE, y2 * SCALE
    sw = width * SCALE
    sh = head_size * SCALE

    draw.line([(sx1, sy1), (sx2, sy2)], fill=color, width=sw)

    angle = math.atan2(sy2 - sy1, sx2 - sx1)
    tip_x, tip_y = sx2, sy2
    left_x = tip_x - sh * math.cos(angle - math.pi / 6)
    left_y = tip_y - sh * math.sin(angle - math.pi / 6)
    right_x = tip_x - sh * math.cos(angle + math.pi / 6)
    right_y = tip_y - sh * math.sin(angle + math.pi / 6)

    draw.polygon([(tip_x, tip_y), (left_x, left_y), (right_x, right_y)],
                 fill=color)


def generate_background():
    """Generate the DMG background image."""
    img = Image.new("RGBA", (IMG_W, IMG_H), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # Subtle gradient background (light gray top → slightly darker bottom)
    for y in range(IMG_H):
        t = y / IMG_H
        r = int(245 - 15 * t)
        g = int(245 - 15 * t)
        b = int(248 - 12 * t)
        draw.line([(0, y), (IMG_W, y)], fill=(r, g, b, 255))

    # Arrow between icon positions
    arrow_color = (180, 180, 185, 255)
    arrow_y = APP_Y
    arrow_left = APP_X + 80   # right of app icon
    arrow_right = DROP_X - 80  # left of Applications icon
    draw_arrow(draw, arrow_left, arrow_y, arrow_right, arrow_y,
               arrow_color, width=3, head_size=14)

    # "Drag to install" text below arrow
    text_color = (140, 140, 145, 255)
    text = "Drag to Applications"
    try:
        font = ImageFont.truetype(
            "/System/Library/Fonts/Helvetica.ttc", 13 * SCALE
        )
    except (OSError, IOError):
        try:
            font = ImageFont.truetype(
                "/System/Library/Fonts/SFNSText.ttf", 13 * SCALE
            )
        except (OSError, IOError):
            font = ImageFont.load_default()

    bbox = draw.textbbox((0, 0), text, font=font)
    tw = bbox[2] - bbox[0]
    text_x = ((APP_X + DROP_X) * SCALE - tw) // 2
    text_y = (arrow_y + 30) * SCALE
    draw.text((text_x, text_y), text, fill=text_color, font=font)

    # Save with 144 DPI for Retina
    output_path = os.path.join(OUTPUT_DIR, "dmg_background.png")
    img.save(output_path, dpi=(144, 144))
    print(f"Created {output_path} ({IMG_W}x{IMG_H} @ 144 DPI)")
    return output_path


if __name__ == "__main__":
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    generate_background()
