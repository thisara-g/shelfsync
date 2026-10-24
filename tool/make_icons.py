#!/usr/bin/env python3
"""Draws the ShelfSync app icon and writes the Android launcher and Linux
desktop PNGs. Requires Pillow. Run from the repo root: python3 tool/make_icons.py
"""
import math
from pathlib import Path

from PIL import Image, ImageDraw

S = 1024  # master size; everything is drawn here, then downsampled
BG_TOP = (38, 50, 56)
BG_BOTTOM = (24, 32, 36)
SHELF = (141, 110, 99)
BADGE = (0, 150, 136)
WHITE = (255, 255, 255)
# Book spines left to right: x, top (fractions of S), width, colour.
SPINES = [
    (0.18, 0.34, 0.11, (239, 83, 80)),
    (0.30, 0.28, 0.09, (255, 202, 40)),
    (0.40, 0.38, 0.12, (102, 187, 106)),
    (0.53, 0.30, 0.10, (66, 165, 245)),
]
LEANING = (171, 71, 188)


def sync_arrow(d: ImageDraw.ImageDraw, cx: float, cy: float, r: float, start: float, end: float, width: int) -> None:
    d.arc([cx - r, cy - r, cx + r, cy + r], start=start, end=end, fill=WHITE, width=width)
    a = math.radians(end)
    tip = (cx + r * math.cos(a), cy + r * math.sin(a))
    tangent = a + math.pi / 2
    size = S * 0.045
    back = (tip[0] - size * math.cos(tangent), tip[1] - size * math.sin(tangent))
    normal = (math.cos(a) * size * 0.75, math.sin(a) * size * 0.75)
    d.polygon(
        [
            (tip[0] + size * 0.6 * math.cos(tangent), tip[1] + size * 0.6 * math.sin(tangent)),
            (back[0] + normal[0], back[1] + normal[1]),
            (back[0] - normal[0], back[1] - normal[1]),
        ],
        fill=WHITE,
    )


def master(rounded: bool) -> Image.Image:
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    bg = Image.new("RGBA", (S, S))
    d = ImageDraw.Draw(bg)
    for y in range(S):
        t = y / (S - 1)
        d.line([(0, y), (S, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(BG_TOP, BG_BOTTOM)))
    mask = Image.new("L", (S, S), 0)
    if rounded:
        ImageDraw.Draw(mask).rounded_rectangle([0, 0, S - 1, S - 1], radius=int(S * 0.22), fill=255)
    else:
        ImageDraw.Draw(mask).rectangle([0, 0, S, S], fill=255)
    img.paste(bg, (0, 0), mask)

    d = ImageDraw.Draw(img)
    # Shelf with a row of book spines standing on it.
    base = S * 0.70
    d.rounded_rectangle([S * 0.14, base, S * 0.86, base + 34], radius=12, fill=SHELF)
    for x, top, w, colour in SPINES:
        d.rounded_rectangle([S * x, S * top, S * (x + w), base - 4], radius=14, fill=colour)
        d.line([(S * x + 18, S * top + 60), (S * (x + w) - 18, S * top + 60)], fill=(255, 255, 255, 120), width=10)

    # One book leaning against the row.
    book = Image.new("RGBA", (int(S * 0.11), int(S * 0.36)), (0, 0, 0, 0))
    ImageDraw.Draw(book).rounded_rectangle([0, 0, book.width - 1, book.height - 1], radius=14, fill=LEANING)
    book = book.rotate(-18, expand=True, resample=Image.BICUBIC)
    img.alpha_composite(book, (int(S * 0.62), int(base - book.height)))

    # Sync badge in the top right corner.
    bx, by, br = S * 0.76, S * 0.27, S * 0.15
    d.ellipse([bx - br, by - br, bx + br, by + br], fill=BADGE)
    for start, end in [(200, 325), (20, 145)]:
        sync_arrow(d, bx, by, br * 0.62, start, end, int(S * 0.03))
    return img


def main() -> None:
    root = Path(__file__).resolve().parent.parent
    square = master(rounded=False)  # Android masks launcher icons itself
    rounded = master(rounded=True)

    densities = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
    for name, px in densities.items():
        out = root / f"android/app/src/main/res/mipmap-{name}/ic_launcher.png"
        rounded.resize((px, px), Image.LANCZOS).save(out)

    icons = root / "assets/icons"
    icons.mkdir(parents=True, exist_ok=True)
    rounded.resize((512, 512), Image.LANCZOS).save(icons / "shelfsync.png")
    square.resize((512, 512), Image.LANCZOS).save(icons / "shelfsync_square.png")
    rounded.resize((256, 256), Image.LANCZOS).save(root / "docs/icon.png")
    print("Icons written.")


if __name__ == "__main__":
    main()
