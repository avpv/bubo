#!/usr/bin/env python3
"""Нанесение защитных водяных знаков на копию паспорта (или другого документа).

Зачем: копия паспорта без пометок может быть использована для оформления
кредита, SIM-карты, регистрации фирмы и т.п. Диагональная сетка полупрозрачного
текста «Копия для <цель>, <дата>» по всей площади (включая фото и машиночитаемую
зону) делает такую копию непригодной для других целей, при этом данные остаются
читаемыми для того, кому копия предназначена.

Что делает скрипт:
  * накладывает повторяющийся диагональный текст по всему изображению;
  * добавляет читаемую строку-плашку внизу с той же надписью;
  * удаляет EXIF/метаданные (геолокация, модель телефона и т.д.);
  * при желании уменьшает разрешение (--max-size), чтобы копию нельзя было
    использовать для качественной перепечатки.

Зависимости: Pillow (pip install pillow). Для PDF на входе — PyMuPDF
(pip install pymupdf), опционально.

Примеры:
  python3 scripts/watermark_passport.py passport.jpg --purpose "для банка Х"
  python3 scripts/watermark_passport.py scan.pdf --purpose "аренда квартиры" \\
      --date 02.09.2026 -o ~/Desktop/passport_copy.jpg
  python3 scripts/watermark_passport.py *.jpg --purpose "визовый центр" \\
      --out-dir marked/ --max-size 1600
  python3 scripts/watermark_passport.py passport.png --text "ТОЛЬКО ДЛЯ ХОСТЕЛА 'СОЛНЦЕ'"

Результат никогда не перезаписывает исходный файл: по умолчанию рядом
создаётся <имя>_watermarked.jpg.
"""

from __future__ import annotations

import argparse
import datetime as dt
import math
import os
import sys
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFont, ImageOps
except ImportError:  # pragma: no cover
    sys.exit("Нужен Pillow: pip install pillow")

# Шрифты с поддержкой кириллицы, в порядке предпочтения.
FONT_CANDIDATES = [
    # macOS
    "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
    "/System/Library/Fonts/Supplemental/Arial.ttf",
    "/System/Library/Fonts/Helvetica.ttc",
    "/Library/Fonts/Arial Bold.ttf",
    # Linux
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf",
    "/usr/share/fonts/truetype/freefont/FreeSansBold.ttf",
    # Windows
    "C:/Windows/Fonts/arialbd.ttf",
    "C:/Windows/Fonts/arial.ttf",
]

IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".bmp", ".tif", ".tiff", ".webp", ".heic"}


def load_font(size: int, font_path: str | None = None) -> ImageFont.FreeTypeFont:
    candidates = ([font_path] if font_path else []) + FONT_CANDIDATES
    for path in candidates:
        if path and os.path.isfile(path):
            try:
                return ImageFont.truetype(path, size)
            except OSError:
                continue
    print(
        "ПРЕДУПРЕЖДЕНИЕ: не найден TTF-шрифт с кириллицей, используется встроенный "
        "(русские буквы могут не отобразиться). Укажите --font /путь/к/шрифту.ttf",
        file=sys.stderr,
    )
    try:
        return ImageFont.load_default(size=size)  # Pillow >= 10.1
    except TypeError:
        return ImageFont.load_default()


def parse_color(value: str) -> tuple[int, int, int]:
    value = value.strip().lstrip("#")
    if len(value) == 3:
        value = "".join(ch * 2 for ch in value)
    if len(value) != 6:
        raise argparse.ArgumentTypeError(f"Неверный цвет: {value!r}, ожидается RRGGBB")
    return tuple(int(value[i : i + 2], 16) for i in (0, 2, 4))  # type: ignore[return-value]


def build_text(args: argparse.Namespace) -> str:
    if args.text:
        return args.text
    date = args.date or dt.date.today().strftime("%d.%m.%Y")
    purpose = args.purpose.strip()
    if not purpose:
        raise SystemExit("Укажите --purpose (для чего копия) или --text (полный текст)")
    if not purpose.lower().startswith(("для ", "на ")):
        purpose = "для " + purpose
    return f"КОПИЯ {purpose.upper()} • {date} • НЕ ДЛЯ ИНЫХ ЦЕЛЕЙ"


def load_pages(path: Path, dpi: int) -> list[Image.Image]:
    """Открывает изображение или PDF и возвращает список страниц (RGB)."""
    if path.suffix.lower() == ".pdf":
        try:
            import fitz  # PyMuPDF
        except ImportError:
            raise SystemExit(
                f"{path}: для PDF нужен PyMuPDF (pip install pymupdf) — "
                "или сначала сохраните страницу как JPG/PNG."
            )
        pages = []
        with fitz.open(path) as doc:
            for page in doc:
                pix = page.get_pixmap(dpi=dpi, alpha=False)
                pages.append(Image.frombytes("RGB", (pix.width, pix.height), pix.samples))
        return pages

    img = Image.open(path)
    img = ImageOps.exif_transpose(img)  # применить поворот из EXIF, затем EXIF отбросим
    return [img.convert("RGB")]


def watermark(
    img: Image.Image,
    text: str,
    *,
    opacity: int,
    angle: float,
    font_scale: float,
    color: tuple[int, int, int],
    font_path: str | None,
    footer: bool,
) -> Image.Image:
    w, h = img.size
    base = img.convert("RGBA")

    # Размер шрифта — доля от диагонали, чтобы масштаб не зависел от разрешения.
    diag = math.hypot(w, h)
    font_size = max(14, int(diag * font_scale))
    font = load_font(font_size, font_path)

    # Слой большего размера, чтобы после поворота сетка покрыла всё изображение.
    layer_size = int(diag * 1.5)
    layer = Image.new("RGBA", (layer_size, layer_size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)

    bbox = draw.textbbox((0, 0), text, font=font)
    text_w = bbox[2] - bbox[0]
    text_h = bbox[3] - bbox[1]
    step_x = int(text_w * 1.25)
    step_y = int(text_h * 3.0)
    fill = (*color, opacity)

    row = 0
    y = -text_h
    while y < layer_size + text_h:
        # Смещаем чётные ряды на полшага, чтобы получилась «шахматная» сетка —
        # так труднее вырезать чистый фрагмент.
        x = -(step_x // 2 if row % 2 else 0) - text_w
        while x < layer_size + text_w:
            draw.text((x, y), text, font=font, fill=fill)
            x += step_x
        y += step_y
        row += 1

    rotated = layer.rotate(angle, resample=Image.BICUBIC, expand=False)
    offset = ((w - layer_size) // 2, (h - layer_size) // 2)
    base.alpha_composite(rotated, dest=(0, 0), source=(-offset[0], -offset[1]))

    if footer:
        base = add_footer(base, text, color, font_path)

    return base.convert("RGB")


def add_footer(
    img: Image.Image, text: str, color: tuple[int, int, int], font_path: str | None
) -> Image.Image:
    """Полупрозрачная плашка внизу с полностью читаемым текстом."""
    w, h = img.size
    font = load_font(max(12, int(h * 0.028)), font_path)
    draw = ImageDraw.Draw(img, "RGBA")
    bbox = draw.textbbox((0, 0), text, font=font)
    text_w, text_h = bbox[2] - bbox[0], bbox[3] - bbox[1]
    # Если текст шире картинки — уменьшаем шрифт.
    while text_w > w * 0.95 and font.size > 10:
        font = load_font(font.size - 2, font_path)
        bbox = draw.textbbox((0, 0), text, font=font)
        text_w, text_h = bbox[2] - bbox[0], bbox[3] - bbox[1]
    pad = int(text_h * 0.6)
    box_h = text_h + pad * 2
    draw.rectangle([(0, h - box_h), (w, h)], fill=(255, 255, 255, 200))
    draw.text(
        ((w - text_w) // 2 - bbox[0], h - box_h + pad - bbox[1]),
        text,
        font=font,
        fill=(*color, 255),
    )
    return img


def downscale(img: Image.Image, max_size: int | None) -> Image.Image:
    if not max_size:
        return img
    if max(img.size) <= max_size:
        return img
    img = img.copy()
    img.thumbnail((max_size, max_size), Image.LANCZOS)
    return img


def output_path(src: Path, out: str | None, out_dir: str | None, page_idx: int, n_pages: int, fmt: str) -> Path:
    ext = ".png" if fmt == "png" else ".jpg"
    suffix = f"_p{page_idx + 1}" if n_pages > 1 else ""
    if out and n_pages == 1:
        return Path(out)
    if out:
        p = Path(out)
        return p.with_name(f"{p.stem}{suffix}{p.suffix or ext}")
    directory = Path(out_dir) if out_dir else src.parent
    return directory / f"{src.stem}_watermarked{suffix}{ext}"


def save(img: Image.Image, dest: Path, fmt: str, quality: int) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    # Сохраняем без exif/icc — метаданные исходного файла не переносятся.
    if fmt == "png":
        img.save(dest, "PNG", optimize=True)
    else:
        img.save(dest, "JPEG", quality=quality, optimize=True, subsampling=0)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Наносит защитные водяные знаки на копию паспорта.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__.split("Примеры:", 1)[-1],
    )
    parser.add_argument("inputs", nargs="+", help="файлы JPG/PNG/TIFF/WebP или PDF")
    parser.add_argument("-p", "--purpose", default="", help='цель копии, напр. "для банка Х"')
    parser.add_argument("-d", "--date", help="дата на знаке (по умолчанию сегодня, ДД.ММ.ГГГГ)")
    parser.add_argument("-t", "--text", help="полный текст знака вместо --purpose/--date")
    parser.add_argument("-o", "--output", help="путь результата (для одного входного файла)")
    parser.add_argument("--out-dir", help="папка для результатов (для нескольких файлов)")
    parser.add_argument("--format", choices=["jpg", "png"], default="jpg", help="формат вывода")
    parser.add_argument("--quality", type=int, default=85, help="качество JPEG (по умолчанию 85)")
    parser.add_argument("--opacity", type=int, default=110, help="прозрачность сетки 0–255 (по умолчанию 110)")
    parser.add_argument("--angle", type=float, default=30.0, help="угол наклона текста в градусах")
    parser.add_argument("--font-scale", type=float, default=0.022, help="размер шрифта как доля диагонали")
    parser.add_argument("--color", type=parse_color, default="B00020", help="цвет текста RRGGBB")
    parser.add_argument("--font", help="путь к TTF-шрифту с кириллицей")
    parser.add_argument("--max-size", type=int, help="уменьшить длинную сторону до N пикселей")
    parser.add_argument("--pdf-dpi", type=int, default=200, help="разрешение рендера PDF")
    parser.add_argument("--no-footer", action="store_true", help="не добавлять плашку внизу")
    args = parser.parse_args(argv)

    if not 0 <= args.opacity <= 255:
        parser.error("--opacity должен быть в диапазоне 0–255")
    if args.output and len(args.inputs) > 1:
        parser.error("-o/--output работает только с одним входным файлом; используйте --out-dir")

    text = build_text(args)
    print(f"Текст знака: {text}")

    written = 0
    for raw in args.inputs:
        src = Path(raw)
        if not src.is_file():
            print(f"Пропуск, файл не найден: {src}", file=sys.stderr)
            continue
        if src.suffix.lower() not in IMAGE_EXTS | {".pdf"}:
            print(f"Пропуск, неподдерживаемый формат: {src}", file=sys.stderr)
            continue

        pages = load_pages(src, args.pdf_dpi)
        for idx, page in enumerate(pages):
            page = downscale(page, args.max_size)
            result = watermark(
                page,
                text,
                opacity=args.opacity,
                angle=args.angle,
                font_scale=args.font_scale,
                color=args.color,
                font_path=args.font,
                footer=not args.no_footer,
            )
            dest = output_path(src, args.output, args.out_dir, idx, len(pages), args.format)
            if dest.resolve() == src.resolve():
                print(f"Отказ: результат совпадает с исходником {src}", file=sys.stderr)
                continue
            save(result, dest, args.format, args.quality)
            print(f"{src} -> {dest} ({result.width}x{result.height})")
            written += 1

    if not written:
        print("Ничего не записано.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
