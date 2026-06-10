#!/usr/bin/env python3
"""Generate the ReaderApp app icon (light, dark, tinted) per Apple HIG.

Design: a white open book on a sage-green gradient — one clear focal subject,
readable at small sizes, content kept in the safe center area. Inspired by the
provided reference icon.
"""
from PIL import Image, ImageDraw, ImageFilter

SS = 4
S = 1024 * SS

def sp(x, y):
    return (x * SS, y * SS)

def quad(p0, c, p1, n=48):
    out = []
    for i in range(n + 1):
        t = i / n; mt = 1 - t
        out.append((mt*mt*p0[0] + 2*mt*t*c[0] + t*t*p1[0],
                    mt*mt*p0[1] + 2*mt*t*c[1] + t*t*p1[1]))
    return out

def vertical_gradient(size, top, bottom):
    col = Image.new("RGB", (1, size))
    px = col.load()
    for y in range(size):
        t = y / (size - 1)
        px[0, y] = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
    return col.resize((size, size))

# ---- page silhouette (taller, near-vertical outer edge) ----------------------
def left_page():
    spine_top, outer_top = (501, 358), (250, 322)
    outer_bottom, spine_bottom = (238, 692), (501, 708)
    pts  = quad(spine_top, (372, 314), outer_top)        # top edge (gentle convex)
    pts += quad(outer_top, (232, 508), outer_bottom)     # outer edge (near vertical)
    pts += quad(outer_bottom, (366, 714), spine_bottom)  # bottom edge (slight dip)
    pts += [spine_top]
    return pts

def mirror(pts):
    return [(1024 - x, y) for (x, y) in pts]

def book_layer(color, line_color):
    """White book with rounded corners (blur+threshold) + faint page lines."""
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    L, R = left_page(), mirror(left_page())
    d.polygon([sp(x, y) for (x, y) in L], fill=(255, 255, 255, 255))
    d.polygon([sp(x, y) for (x, y) in R], fill=(255, 255, 255, 255))
    d.rectangle([sp(501, 560), sp(523, 706)], fill=(255, 255, 255, 255))  # binding bridge
    # round the corners
    r = 7 * SS
    a = layer.split()[3].filter(ImageFilter.GaussianBlur(r)).point(lambda v: 255 if v >= 128 else 0)
    solid = Image.new("RGBA", (S, S), color)
    book = Image.composite(solid, Image.new("RGBA", (S, S), (0, 0, 0, 0)), a)
    # page-stack lines near each outer-bottom (hint of stacked pages)
    dd = ImageDraw.Draw(book)
    for yb in (622, 658):
        dd.line([sp(262, yb), sp(440, yb)], fill=line_color, width=5 * SS)
        dd.line([sp(762, yb), sp(584, yb)], fill=line_color, width=5 * SS)
    return book

def render(page_color, line_color, background=None):
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    if background is not None:
        img.alpha_composite(background.convert("RGBA"))
    img.alpha_composite(book_layer(page_color, line_color))
    return img.resize((1024, 1024), Image.LANCZOS)

OUT = "Assets.xcassets/AppIcon.appiconset"
WHITE = (255, 255, 255, 255)

bg = vertical_gradient(S, (132, 172, 150), (92, 136, 116))
render(WHITE, (104, 146, 126, 255), background=bg).convert("RGB").save(f"{OUT}/AppIcon.png")
render(WHITE, (206, 206, 206, 255), background=None).save(f"{OUT}/AppIcon 1.png")
render((236, 236, 236, 255), (170, 170, 170, 255), background=None).save(f"{OUT}/AppIcon 2.png")
print("wrote AppIcon.png (light), AppIcon 1.png (dark), AppIcon 2.png (tinted)")
