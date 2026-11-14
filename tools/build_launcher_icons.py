"""Builds the shipped launcher icon set for 沐音 from the matted logo art.

Outputs, per icon variant:
  drawable-<dpi>/ic_launcher[_code]_foreground.png   adaptive foreground (108dp canvas)
  drawable-<dpi>/ic_launcher[_code]_background.png   adaptive background (108dp canvas)
  mipmap-<dpi>/ic_launcher[_code].png                legacy launcher icon (48..192dp)
  drawable-<dpi>/ic_launcher_monochrome.png          themed-icon silhouette (classic art)
  assets/app_icons/<code>.png                        256px preview for the settings sheet
"""

from __future__ import annotations

import colorsys
import math
import os

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = r"D:\projects\MuyinMusic\logo.png"
RES = os.path.join(ROOT, "android", "app", "src", "main", "res")
PREVIEWS = os.path.join(ROOT, "assets", "app_icons")
WORK = 1024

DENSITIES = {"mdpi": 1.0, "hdpi": 1.5, "xhdpi": 2.0, "xxhdpi": 3.0, "xxxhdpi": 4.0}
LEGACY_DP = 48
ADAPTIVE_DP = 108

# note dark -> light, ring dark -> light, bg top, bg bottom
VARIANTS = {
    "classic": (((28, 58, 150), (86, 128, 244)), ((74, 188, 158), (176, 240, 222)), (255, 255, 255), (236, 242, 253)),
    "midnight": (((70, 104, 168), (166, 206, 255)), ((96, 212, 188), (192, 250, 236)), (18, 25, 44), (10, 14, 26)),
    "sky": (((32, 92, 184), (108, 176, 255)), ((72, 184, 214), (186, 240, 252)), (246, 251, 255), (214, 235, 255)),
    "lavender": (((88, 56, 178), (176, 138, 255)), ((128, 104, 224), (216, 198, 255)), (250, 245, 255), (236, 224, 255)),
    "mint": (((18, 128, 108), (86, 208, 178)), ((68, 186, 156), (176, 240, 222)), (244, 253, 249), (218, 246, 236)),
    "peach": (((176, 80, 52), (255, 148, 110)), ((218, 122, 92), (255, 208, 190)), (255, 248, 244), (255, 230, 218)),
}


def smoothstep(edge0: float, edge1: float, x: float) -> float:
    if edge1 <= edge0:
        return 1.0 if x >= edge1 else 0.0
    t = max(0.0, min(1.0, (x - edge0) / (edge1 - edge0)))
    return t * t * (3 - 2 * t)


def load_art() -> Image.Image:
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

    alpha = Image.new("L", (cw, ch), 0)
    ap = alpha.load()
    for y in range(ch):
        for x in range(cw):
            r, g, b = rgb[x, y][:3]
            dist = math.sqrt((r - bg[0]) ** 2 + (g - bg[1]) ** 2 + (b - bg[2]) ** 2)
            a = 255 * smoothstep(30, 58, dist)
            _, sat, val = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
            if sat < 0.10 and val > 0.55:
                a = 0
            ap[x, y] = round(a)
    alpha = alpha.point(lambda v: 255 if v >= 96 else 0)
    alpha = alpha.filter(ImageFilter.MedianFilter(5)).filter(ImageFilter.MaxFilter(3))
    alpha = alpha.filter(ImageFilter.GaussianBlur(0.7))
    out = card.convert("RGBA")
    out.putalpha(alpha)
    return out


def split_masks(art: Image.Image):
    """Splits the matte into the warm wooden note and the green sound ring."""
    w, h = art.size
    px = art.load()
    note = Image.new("L", (w, h), 0)
    ring = Image.new("L", (w, h), 0)
    np_, rp = note.load(), ring.load()
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a == 0:
                continue
            hue, sat, _ = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
            hue *= 360
            if 110 <= hue <= 200 and sat > 0.10:
                rp[x, y] = a
            else:
                np_[x, y] = a
    return note, ring


def with_vector_ring(art: Image.Image, note_mask: Image.Image, ring_mask: Image.Image, ring_color) -> Image.Image:
    """Redraws the sound ring as a crisp circle so it reads at 48dp."""
    out = Image.new("RGBA", art.size, (0, 0, 0, 0))
    bbox = ring_mask.getbbox()
    if bbox:
        left, top, right, bottom = bbox
        radius = (right - left) / 2 - 1
        cx, cy = (left + right) / 2, top + radius
        stroke = max(3, int(art.width * 0.019))
        ring_d = ImageDraw.Draw(out)
        ring_d.ellipse([cx - radius, cy - radius, cx + radius, cy + radius], outline=ring_color + (255,), width=stroke)
        bead = art.width * 0.030
        ring_d.ellipse([cx - bead, cy + radius - bead, cx + bead, cy + radius + bead], fill=ring_color + (255,))
    note_layer = art.copy()
    note_layer.putalpha(note_mask)
    out.alpha_composite(note_layer)
    return out


def mix(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))


def recolour(art: Image.Image, note, ring, bg_color) -> Image.Image:
    w, h = art.size
    px = art.load()
    out = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    op = out.load()
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a == 0:
                continue
            hue, sat, val = colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)
            hue *= 360
            is_ring = 110 <= hue <= 200 and sat > 0.10
            lo, hi = ring if is_ring else note
            t = max(0.0, min(1.0, (val - 0.05) / 0.95)) ** 0.85
            color = mix(lo, hi, t)
            if val > 0.90:
                color = mix(color, (255, 255, 255), min(0.65, (val - 0.90) * 6.5))
            op[x, y] = color + (a,)
    return out


def gradient_bg(size: int, top, bottom) -> Image.Image:
    img = Image.new("RGB", (1, size))
    px = img.load()
    for y in range(size):
        t = y / max(1, size - 1)
        px[0, y] = tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
    return img.resize((size, size), Image.BILINEAR).convert("RGBA")


def scaled_art(art: Image.Image, size: int, ratio: float) -> Image.Image:
    bbox = art.getbbox()
    art = art.crop(bbox)
    art.thumbnail((int(size * ratio), int(size * ratio)), Image.LANCZOS)
    return art


def rounded(img: Image.Image, ratio: float = 0.225) -> Image.Image:
    out = img.copy()
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, img.width - 1, img.height - 1], radius=int(img.width * ratio), fill=255)
    out.putalpha(mask)
    return out


def tile(art: Image.Image, top, bottom, size: int, rounded_ratio: float = 0.225) -> Image.Image:
    canvas = gradient_bg(size, top, bottom)
    a = scaled_art(art, size, 0.74)
    canvas.alpha_composite(a, ((size - a.width) // 2, (size - a.height) // 2))
    return rounded(canvas, rounded_ratio) if rounded_ratio else canvas


def silhouette(art: Image.Image, size: int, ratio: float) -> Image.Image:
    a = scaled_art(art, size, ratio)
    layer = Image.new("RGBA", (size, size), (255, 255, 255, 0))
    solid = Image.new("RGBA", a.size, (255, 255, 255, 255))
    solid.putalpha(a.getchannel("A"))
    layer.alpha_composite(solid, ((size - a.width) // 2, (size - a.height) // 2))
    return layer


def ensure(path: str) -> None:
    os.makedirs(path, exist_ok=True)


def main() -> None:
    art = load_art()
    ensure(PREVIEWS)
    mono_done = False

    for code, (note, ring, top, bottom) in VARIANTS.items():
        note_mask, ring_mask = split_masks(art)
        art_c = recolour(art, note, ring, top)
        suffix = "" if code == "classic" else f"_{code}"

        for dpi, factor in DENSITIES.items():
            drawable = os.path.join(RES, f"drawable-{dpi}")
            mipmap = os.path.join(RES, f"mipmap-{dpi}")
            ensure(drawable)
            ensure(mipmap)

            adaptive = int(round(ADAPTIVE_DP * factor))
            fg = Image.new("RGBA", (adaptive, adaptive), (0, 0, 0, 0))
            a = scaled_art(art_c, adaptive, 0.60)
            fg.alpha_composite(a, ((adaptive - a.width) // 2, (adaptive - a.height) // 2))
            fg.save(os.path.join(drawable, f"ic_launcher{suffix}_foreground.png"))

            gradient_bg(adaptive, top, bottom).save(
                os.path.join(drawable, f"ic_launcher{suffix}_background.png")
            )

            legacy = int(round(LEGACY_DP * factor))
            tile(art_c, top, bottom, legacy).save(os.path.join(mipmap, f"ic_launcher{suffix}.png"))

            if not mono_done:
                silhouette(art_c, adaptive, 0.60).save(os.path.join(drawable, "ic_launcher_monochrome.png"))

        tile(art_c, top, bottom, 1024).resize((256, 256), Image.LANCZOS).save(
            os.path.join(PREVIEWS, f"{code}.png")
        )
        mono_done = True
        print("built", code)


if __name__ == "__main__":
    main()
