#!/usr/bin/env python3
"""Draws the ShelfSync app icon and writes the Android launcher and Linux
desktop PNGs. Requires Pillow. Run from the repo root: python3 tool/make_icons.py
"""
import math
from pathlib import Path

from PIL import Image, ImageDraw

S = 1024  # master size; everything is drawn here, then downsampled
TEAL_TOP = (0, 150, 136)
TEAL_BOTTOM = (0, 105, 92)
PAGE = (250, 250, 247)
LINE = (178, 214, 209)
ARROW = (255, 213, 79)


def master(rounded: bool) -> Image.Image:
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    bg = Image.new("RGBA", (S, S))
    d = ImageDraw.Draw(bg)
    for y in range(S):
        t = y / (S - 1)
        d.line([(0, y), (S, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(TEAL_TOP, TEAL_BOTTOM)))
    mask = Image.new("L", (S, S), 0)
    if rounded:
        ImageDraw.Draw(mask).rounded_rectangle([0, 0, S - 1, S - 1], radius=int(S * 0.22), fill=255)
    else:
        ImageDraw.Draw(mask).rectangle([0, 0, S, S], fill=255)
    img.paste(bg, (0, 0), mask)

    d = ImageDraw.Draw(img)
    # Open book: two slightly tilted pages meeting at a spine.
    cx, top, bottom = S / 2, S * 0.30, S * 0.70
    w = S * 0.30
    left = [(cx, top + 30), (cx - w, top), (cx - w, bottom - 30), (cx, bottom)]
    right = [(cx, top + 30), (cx + w, top), (cx + w, bottom - 30), (cx, bottom)]
    d.polygon(left, fill=PAGE)
    d.polygon(right, fill=PAGE)
    # Text lines on each page.
    for i in range(5):
        y = top + 70 + i * 52
        d.line([(cx - w + 50, y), (cx - 45, y + 22)], fill=LINE, width=16)
        d.line([(cx + 45, y + 22), (cx + w - 50, y)], fill=LINE, width=16)
    d.line([(cx, top + 30), (cx, bottom)], fill=TEAL_BOTTOM, width=10)

    # Sync arrows: two arcs around the book.
    r = S * 0.40
    box = [cx - r, S / 2 - r, cx + r, S / 2 + r]
    width = int(S * 0.045)
    for start, end in [(200, 325), (20, 145)]:
        d.arc(box, start=start, end=end, fill=ARROW, width=width)
        a = math.radians(end)
        tip = (cx + r * math.cos(a), S / 2 + r * math.sin(a))
        tangent = a + math.pi / 2
        size = S * 0.07
        back = (tip[0] - size * math.cos(tangent), tip[1] - size * math.sin(tangent))
        normal = (math.cos(a) * size * 0.75, math.sin(a) * size * 0.75)
        d.polygon(
            [
                (tip[0] + size * 0.6 * math.cos(tangent), tip[1] + size * 0.6 * math.sin(tangent)),
                (back[0] + normal[0], back[1] + normal[1]),
                (back[0] - normal[0], back[1] - normal[1]),
            ],
            fill=ARROW,
        )
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
    print("Icons written.")


if __name__ == "__main__":
    main()
