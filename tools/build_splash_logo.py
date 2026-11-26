"""Exports the splash foreground: the note alone on a transparent canvas.

The ring is drawn in Dart (see StartupLogo) as a circle of radius 0.455 of the
canvas, so the note here is centred and scaled to sit inside it.
"""

import colorsys
import math
import os

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = r"D:\projects\PanghuMusic\logo.png"
OUT = os.path.join(ROOT, "logo_fg.png")
CANVAS = 1024
NOTE_DEEP = (32, 62, 150)
NOTE_LIGHT = (86, 128, 244)


def smoothstep(edge0: float, edge1: float, x: float) -> float:
    if edge1 <= edge0:
        return 1.0 if x >= edge1 else 0.0
    t = max(0.0, min(1.0, (x - edge0) / (edge1 - edge0)))
    return t * t * (3 - 2 * t)


def largest_component(mask: Image.Image) -> Image.Image:
    w, h = mask.size
    px = mask.load()
    seen = bytearray(w * h)
    best: list = []
    for sy in range(h):
        for sx in range(w):
            idx = sy * w + sx
            if seen[idx] or px[sx, sy] < 128:
                continue
            stack = [(sx, sy)]
            seen[idx] = 1
            blob = []
            while stack:
                x, y = stack.pop()
                blob.append((x, y))
                for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
                    if 0 <= nx < w and 0 <= ny < h:
                        nidx = ny * w + nx
                        if not seen[nidx] and px[nx, ny] >= 128:
                            seen[nidx] = 1
                            stack.append((nx, ny))
            if len(blob) > len(best):
                best = blob
    out = Image.new("L", (w, h), 0)
    op = out.load()
    for x, y in best:
        op[x, y] = 255
    return out


def main() -> None:
    src = Image.open(SRC).convert("RGB")
    w, h = src.size
    inset = 0.08
    card = src.crop((int(w * inset), int(h * inset), int(w * (1 - inset)), int(h * (1 - inset))))
    cw, ch = card.size
    rgb = card.load()

    band = max(4, int(min(cw, ch) * 0.04))
    samples = []
    for x in range(0, cw, 3):
        for y in (band // 2, ch - 1 - band // 2):
            samples.append(rgb[x, y][:3])
    for y in range(0, ch, 3):
        for x in (band // 2, cw - 1 - band // 2):
            samples.append(rgb[x, y][:3])
    samples.sort(key=lambda c: c[0] + c[1] + c[2])
    bg = samples[len(samples) // 2]

    note = Image.new("L", (cw, ch), 0)
    np_ = note.load()
    for y in range(ch):
        for x in range(cw):
            r, g, b = rgb[x, y][:3]
            dist = math.sqrt((r - bg[0]) ** 2 + (g - bg[1]) ** 2 + (b - bg[2]) ** 2)
            a = 255 * smoothstep(30, 58, dist)
            hue, sat, val = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
            is_ring = 110 <= hue * 360 <= 200 and sat > 0.10
            if sat < 0.10 and val > 0.55:
                a = 0
            np_[x, y] = 0 if is_ring else round(a)

    note = note.point(lambda v: 255 if v >= 128 else 0)
    note = note.filter(ImageFilter.MedianFilter(5))
    note = largest_component(note)
    note = note.filter(ImageFilter.GaussianBlur(0.7))

    note_rgba = card.convert("RGBA")
    note_rgba.putalpha(note)
    px = note_rgba.load()
    for y in range(ch):
        for x in range(cw):
            r, g, b, a = px[x, y]
            if a == 0:
                continue
            _, _, val = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
            t = max(0.0, min(1.0, (val - 0.05) / 0.95)) ** 0.85
            color = tuple(
                round(NOTE_DEEP[i] + (NOTE_LIGHT[i] - NOTE_DEEP[i]) * t) for i in range(3)
            )
            if val > 0.90:
                m = min(0.6, (val - 0.90) * 6.0)
                color = tuple(round(color[i] + (255 - color[i]) * m) for i in range(3))
            px[x, y] = color + (a,)

    bbox = note_rgba.getbbox()
    if not bbox:
        raise SystemExit("no note found")
    cropped = note_rgba.crop(bbox)
    target = int(CANVAS * 0.74)
    cropped.thumbnail((target, target), Image.LANCZOS)
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    canvas.alpha_composite(
        cropped,
        ((CANVAS - cropped.width) // 2, (CANVAS - cropped.height) // 2),
    )
    canvas.save(OUT)
    print("wrote", OUT)


if __name__ == "__main__":
    main()
