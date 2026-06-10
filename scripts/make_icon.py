#!/usr/bin/env python3
"""Generate the ReaderApp app icon (light, dark, tinted) per Apple HIG.

Design: a simple, centered open book with a coral bookmark ribbon — one clear
focal subject, readable at small sizes, content kept in the safe center area.
"""
from PIL import Image, ImageDraw, ImageFilter

SS = 4                      # supersample factor for smooth edges
S = 1024 * SS               # working canvas

def P(x, y):                # scale a 1024-space point to the working canvas
    return (x * SS, y * SS)

def poly(pts):
    return [P(x, y) for (x, y) in pts]

# ---- geometry (in 1024 space) -------------------------------------------------
# Tented open book: spine is the peak, outer edges lower. Sized to fill the
# frame while keeping the subject in the safe center area.
L_TOP = [(512, 350), (148, 438), (148, 712), (512, 638)]   # left page
R_TOP = [(512, 350), (876, 438), (876, 712), (512, 638)]   # right page
def shift(p, dy): return [(x, y + dy) for (x, y) in p]
L_BACK = shift(L_TOP, 18)                                   # page-stack rim
R_BACK = shift(R_TOP, 18)
# coral bookmark ribbon tucked under the right page near the spine
RIBBON = [(548, 372), (608, 372), (608, 802), (578, 762), (548, 802)]

def vertical_gradient(size, top, bottom):
    col = Image.new("RGB", (1, size))
    px = col.load()
    for y in range(size):
        t = y / (size - 1)
        px[0, y] = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
    return col.resize((size, size))

def draw_book(img, pages_light, pages_dark, spine_c, ribbon_c, ribbon_dark, shadow=True):
    d = ImageDraw.Draw(img)
    # soft drop shadow under the book
    if shadow:
        sh = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        sd = ImageDraw.Draw(sh)
        sd.polygon(poly(shift(L_TOP, 26)), fill=(20, 24, 60, 120))
        sd.polygon(poly(shift(R_TOP, 26)), fill=(20, 24, 60, 120))
        sh = sh.filter(ImageFilter.GaussianBlur(18 * SS))
        img.alpha_composite(sh)
    # page-stack rim (back), then top pages
    d.polygon(poly(L_BACK), fill=pages_dark)
    d.polygon(poly(R_BACK), fill=pages_dark)
    d.polygon(poly(L_TOP),  fill=pages_dark)
    d.polygon(poly(R_TOP),  fill=pages_light)
    # spine crease
    d.line([P(512, 350), P(512, 638)], fill=spine_c, width=int(7 * SS))
    # bookmark ribbon (shaded edge + body)
    d.polygon(poly(RIBBON), fill=ribbon_c)
    d.line([P(548, 372), P(548, 790)], fill=ribbon_dark, width=int(6 * SS))

def render(light_bg, pages_light, pages_dark, spine_c, ribbon_c, ribbon_dark,
           background=None, shadow=True):
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    if background is not None:
        img.alpha_composite(background.convert("RGBA"))
    draw_book(img, pages_light, pages_dark, spine_c, ribbon_c, ribbon_dark, shadow=shadow)
    return img.resize((1024, 1024), Image.LANCZOS)

OUT = "Assets.xcassets/AppIcon.appiconset"

# ---- Light: opaque indigo gradient background --------------------------------
bg = vertical_gradient(S, (104, 118, 240), (44, 56, 168))
light = render(
    light_bg=True,
    pages_light=(251, 246, 236, 255), pages_dark=(238, 230, 216, 255),
    spine_c=(214, 203, 182, 255), ribbon_c=(240, 104, 60, 255),
    ribbon_dark=(206, 80, 44, 255), background=bg, shadow=True,
).convert("RGB")
light.save(f"{OUT}/AppIcon.png")

# ---- Dark: transparent background, system provides dark backdrop -------------
dark = render(
    light_bg=False,
    pages_light=(244, 238, 226, 255), pages_dark=(225, 216, 200, 255),
    spine_c=(150, 140, 122, 255), ribbon_c=(240, 104, 60, 255),
    ribbon_dark=(196, 74, 40, 255), background=None, shadow=False,
)
dark.save(f"{OUT}/AppIcon 1.png")

# ---- Tinted: grayscale foreground on transparent, system applies tint --------
tint = render(
    light_bg=False,
    pages_light=(232, 232, 232, 255), pages_dark=(205, 205, 205, 255),
    spine_c=(150, 150, 150, 255), ribbon_c=(170, 170, 170, 255),
    ribbon_dark=(120, 120, 120, 255), background=None, shadow=False,
)
tint.save(f"{OUT}/AppIcon 2.png")

print("wrote AppIcon.png (light), AppIcon 1.png (dark), AppIcon 2.png (tinted)")
