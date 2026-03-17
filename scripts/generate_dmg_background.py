#!/usr/bin/env python3
"""Generate a Retina background image for the Owlenda DMG installer.

Run once locally, commit the output. Not part of CI.

Output: Owlenda/Resources/dmg_background.png (1320x800 @144 DPI)

Icon positions must match create-dmg flags in release.yml:
  --icon "Owlenda.app" 180 200
  --app-drop-link 480 200
  --window-size 660 400
"""

import math
import os

import cairosvg
from PIL import Image, ImageDraw, ImageFont

# Layout (points) — single source of truth
WIN_W, WIN_H = 660, 400
APP_X, APP_Y = 180, 200
DROP_X, DROP_Y = 480, 200

SCALE = 2
IMG_W, IMG_H = WIN_W * SCALE, WIN_H * SCALE

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(SCRIPT_DIR)
SVG_PATH = os.path.join(PROJECT_DIR, "Owlenda", "Resources", "owl.svg")
OUTPUT_PATH = os.path.join(
    PROJECT_DIR, "Owlenda", "Resources", "dmg_background.png"
)

# Brand palette
BG_TOP = (28, 28, 32)
BG_BOTTOM = (20, 20, 24)
ARROW_COLOR = (255, 255, 255, 80)
TEXT_COLOR = (255, 255, 255, 90)


def draw_gradient(img):
    """Dark vertical gradient."""
    draw = ImageDraw.Draw(img)
    for y in range(IMG_H):
        t = y / IMG_H
        r = int(BG_TOP[0] + (BG_BOTTOM[0] - BG_TOP[0]) * t)
        g = int(BG_TOP[1] + (BG_BOTTOM[1] - BG_TOP[1]) * t)
        b = int(BG_TOP[2] + (BG_BOTTOM[2] - BG_TOP[2]) * t)
        draw.line([(0, y), (IMG_W, y)], fill=(r, g, b, 255))


def draw_watermark(img):
    """Small owl brand mark at the bottom center, below the icons."""
    owl_size = 64 * SCALE
    owl_png = cairosvg.svg2png(
        url=SVG_PATH, output_width=owl_size, output_height=owl_size
    )
    owl = Image.open(__import__("io").BytesIO(owl_png)).convert("RGBA")

    # Very subtle
    alpha = owl.split()[3]
    alpha = alpha.point(lambda p: min(p, 20))
    owl.putalpha(alpha)

    x = (IMG_W - owl_size) // 2
    y = IMG_H - owl_size - 30 * SCALE  # bottom center, clear of icons
    img.paste(owl, (x, y), owl)


def draw_curved_arrow(draw):
    """Subtle curved arrow between icon positions."""
    sx = (APP_X + 72) * SCALE
    ex = (DROP_X - 72) * SCALE
    cy = APP_Y * SCALE
    mid_x = (sx + ex) // 2
    curve = -25 * SCALE

    points = []
    for i in range(61):
        t = i / 60
        x = (1 - t) ** 2 * sx + 2 * (1 - t) * t * mid_x + t ** 2 * ex
        y = (1 - t) ** 2 * cy + 2 * (1 - t) * t * (cy + curve) + t ** 2 * cy
        points.append((x, y))

    for i in range(len(points) - 1):
        draw.line([points[i], points[i + 1]], fill=ARROW_COLOR, width=2 * SCALE)

    # Arrowhead
    last = points[-1]
    prev = points[-4]
    angle = math.atan2(last[1] - prev[1], last[0] - prev[0])
    head = 10 * SCALE
    for da in [-math.pi / 5, math.pi / 5]:
        bx = last[0] - head * math.cos(angle + da)
        by = last[1] - head * math.sin(angle + da)
        draw.line([last, (bx, by)], fill=ARROW_COLOR, width=2 * SCALE)


def draw_text(draw):
    """Minimal hint text below the arrow."""
    try:
        font = ImageFont.truetype(
            "/System/Library/Fonts/Helvetica.ttc", 11 * SCALE
        )
    except (OSError, IOError):
        font = ImageFont.load_default()

    bbox = draw.textbbox((0, 0), "drag to Applications", font=font)
    tw = bbox[2] - bbox[0]
    x = (IMG_W - tw) // 2
    y = (APP_Y + 48) * SCALE
    draw.text((x, y), "drag to Applications", fill=TEXT_COLOR, font=font)


def generate():
    img = Image.new("RGBA", (IMG_W, IMG_H))
    draw_gradient(img)
    draw_watermark(img)

    draw = ImageDraw.Draw(img)
    draw_curved_arrow(draw)
    draw_text(draw)

    img.save(OUTPUT_PATH, dpi=(144, 144))
    print(f"Created {OUTPUT_PATH} ({IMG_W}x{IMG_H} @144 DPI)")


if __name__ == "__main__":
    generate()
