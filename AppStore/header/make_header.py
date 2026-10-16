#!/usr/bin/env python3
"""Header artwork, 3840x1646: app icon + name + tagline on the left, three
iPhones (library, reader, Korean dark) fanned on the right.

usage: make_header.py   → header_en.png, header_ko.png, header_clean.png (no text)
"""
import os
from PIL import Image, ImageDraw, ImageFont, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
RAW = os.path.join(ROOT, "AppStore", "screenshots", "raw")
ICON = os.path.join(ROOT, "Assets.xcassets", "iOS.appiconset", "app_icon_light.png")
FONT = "/System/Library/Fonts/AppleSDGothicNeo.ttc"
BOLD, SEMI, REG = 6, 4, 0

W, H = 3840, 1646
# The icon's own green, a little deeper so white text and phones stand out.
TOP, BOTTOM = (104, 163, 139), (58, 107, 88)

TEXT = {
    "en": ("Booklip", "Your books, your way.",
           "EPUB · PDF · TXT · Markdown  —  read, listen, highlight"),
    "ko": ("Booklip", "내 책은 내 기기에서",
           "EPUB · PDF · TXT · Markdown  —  읽고, 듣고, 밑줄 긋기"),
}


def gradient(size=(W, H), glow_box=(1900, -300, 3900, 1700)):
    """Icon-green diagonal gradient with a soft light at `glow_box`
    (behind the phones). Shared with make_search.py."""
    W, H = size
    img = Image.new("RGB", (W, H))
    px = img.load()
    for y in range(H):
        for x in range(W):
            # diagonal: lighter top-left, deeper bottom-right
            t = min(1.0, max(0.0, (y / H) * 0.7 + (x / W) * 0.3))
            px[x, y] = tuple(int(a + (b - a) * t) for a, b in zip(TOP, BOTTOM))
    glow = Image.new("L", (W, H), 0)
    ImageDraw.Draw(glow).ellipse(glow_box, fill=70)
    glow = glow.filter(ImageFilter.GaussianBlur(260))
    img.paste(Image.new("RGB", (W, H), (255, 255, 255)), (0, 0), glow)
    return img


def rounded_mask(size, radius):
    m = Image.new("L", size, 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, size[0] - 1, size[1] - 1), radius, fill=255)
    return m


def phone(shot, width):
    """Screenshot in a black iPhone bezel, with transparent surroundings."""
    bezel = int(width * 0.035)
    sw = width - 2 * bezel
    screen = Image.open(os.path.join(RAW, shot)).convert("RGB")
    sh = int(screen.height * sw / screen.width)
    screen = screen.resize((sw, sh), Image.LANCZOS)
    body = (width, sh + 2 * bezel)
    out = Image.new("RGBA", body, (0, 0, 0, 0))
    r = int(width * 0.155)
    out.paste((22, 22, 24, 255), (0, 0), rounded_mask(body, r))
    out.paste(screen, (bezel, bezel), rounded_mask((sw, sh), r - bezel))
    return out


def shadowed(canvas, img, pos, blur=60, offset=40, alpha=110):
    sh = Image.new("RGBA", img.size, (0, 0, 0, 0))
    sh.putalpha(img.getchannel("A").point(lambda a: a * alpha // 255))
    pad = blur * 3
    layer = Image.new("RGBA", (img.width + pad * 2, img.height + pad * 2), (0, 0, 0, 0))
    layer.paste(sh, (pad, pad))
    layer = layer.filter(ImageFilter.GaussianBlur(blur))
    canvas.alpha_composite(layer, (pos[0] - pad, pos[1] - pad + offset))
    canvas.alpha_composite(img, pos)


def icon(size):
    img = Image.open(ICON).convert("RGBA").resize((size, size), Image.LANCZOS)
    img.putalpha(rounded_mask((size, size), int(size * 0.225)))
    return img


def render(lang):
    canvas = gradient().convert("RGBA")

    # Phones: back two first, the front (reader) last. They bleed off the
    # bottom edge on purpose.
    pw = 700
    phones = [
        ("iphone_library.png",     2040, 300),
        ("iphone_korean_dark.png", 3320, 300),
        ("iphone_reader.png",      2680, 210),
    ]
    for shot, x, y in phones:
        shadowed(canvas, phone(shot, pw), (x - pw // 2, y))

    if lang:
        name, tagline, sub = TEXT[lang]
        d = ImageDraw.Draw(canvas)
        ic = icon(300)
        x0 = 300
        shadowed(canvas, ic, (x0, 420), blur=30, offset=18, alpha=80)
        f_name = ImageFont.truetype(FONT, 190, index=BOLD)
        f_tag = ImageFont.truetype(FONT, 104, index=SEMI)
        f_sub = ImageFont.truetype(FONT, 52, index=REG)
        d.text((x0, 790), name, font=f_name, fill="white")
        d.text((x0 + 6, 1030), tagline, font=f_tag, fill="white")
        d.text((x0 + 8, 1190), sub, font=f_sub, fill=(222, 238, 230))
    return canvas.convert("RGB")


if __name__ == "__main__":
    for lang, name in [("en", "header_en.png"), ("ko", "header_ko.png"), (None, "header_clean.png")]:
        img = render(lang)
        assert img.size == (W, H)
        img.save(os.path.join(HERE, name), optimize=True)
        print(name, img.size)
