#!/usr/bin/env python3
"""Search-result artwork, 3840x2560: icon, name and tagline centred on top,
five iPhones fanned below (the reader in front), bleeding off the bottom.

usage: make_search.py   → search_en.png, search_ko.png, search_clean.png (no text)
"""
import os
from PIL import Image, ImageDraw, ImageFont
from make_header import (HERE, FONT, BOLD, SEMI, REG, TEXT,
                         gradient, phone, shadowed, icon)

W, H = 3840, 2560


def centered(d, y, text, font, fill):
    w = d.textlength(text, font=font)
    d.text(((W - w) / 2, y), text, font=font, fill=fill)


def render(lang):
    canvas = gradient((W, H), glow_box=(700, 700, 3140, 3200)).convert("RGBA")

    # Outer pair first, then the inner pair, the reader last — each row
    # sits in front of the one before it. (shot, centre x, top y)
    if lang:
        pw, xs, ys = 760, (640, 1270, 1920), (1300, 1150, 1010)
    else:  # no text block: bigger phones fill the canvas
        pw, xs, ys = 900, (520, 1220, 1920), (1060, 880, 700)
    phones = [
        ("iphone_library.png",        xs[0],     ys[0]),
        ("iphone_korean_dark.png",    W - xs[0], ys[0]),
        ("iphone_highlight_menu.png", xs[1],     ys[1]),
        ("iphone_tts.png",            W - xs[1], ys[1]),
        ("iphone_reader.png",         xs[2],     ys[2]),
    ]
    for shot, x, y in phones:
        shadowed(canvas, phone(shot, pw), (x - pw // 2, y))

    if lang:
        name, tagline, sub = TEXT[lang]
        d = ImageDraw.Draw(canvas)
        f_name = ImageFont.truetype(FONT, 190, index=BOLD)
        f_tag = ImageFont.truetype(FONT, 96, index=SEMI)
        f_sub = ImageFont.truetype(FONT, 52, index=REG)
        # icon + name on one line, centred together
        size, gap = 240, 60
        name_w = d.textlength(name, font=f_name)
        x0 = int((W - (size + gap + name_w)) / 2)
        top = 170
        shadowed(canvas, icon(size), (x0, top), blur=26, offset=16, alpha=80)
        d.text((x0 + size + gap, top + size / 2), name, font=f_name, fill="white", anchor="lm")
        centered(d, 500, tagline, f_tag, "white")
        centered(d, 650, sub, f_sub, (222, 238, 230))
    return canvas.convert("RGB")


if __name__ == "__main__":
    for lang, name in [("en", "search_en.png"), ("ko", "search_ko.png"), (None, "search_clean.png")]:
        img = render(lang)
        assert img.size == (W, H)
        img.save(os.path.join(HERE, name), optimize=True)
        print(name, img.size)
