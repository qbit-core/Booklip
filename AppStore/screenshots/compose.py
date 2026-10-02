#!/usr/bin/env python3
"""Compose App Store marketing screenshots from raw simulator captures."""
import os, sys
from PIL import Image, ImageDraw, ImageFont, ImageFilter

S = os.path.dirname(os.path.abspath(__file__))
SHOTS = os.path.join(S, "raw")
# usage: compose.py [device ...]   (iphone, ipad, mac; default: all)
OUT = S
ONLY = sys.argv[1:]
FONT = "/System/Library/Fonts/AppleSDGothicNeo.ttc"
BOLD, SEMI, REG = 6, 4, 0

# (shot, headline_ko, sub_ko, headline_en, sub_en, bg, fg, subfg)
SLIDES = [
    ("library",
     "내 책은 내 기기에서", "EPUB · PDF · TXT · Markdown, 실제 표지 그대로",
     "Your books, your way", "EPUB · PDF · TXT · Markdown with real covers",
     "#1C2433", "#FFFFFF", "#B7C2D6"),
    ("reader",
     "원본 그대로 읽는다", "내장 서체와 삽화까지 제작자가 의도한 모습으로",
     "Read it as it was made", "Embedded fonts and illustrations, exactly as designed",
     "#F3ECD8", "#2B2118", "#6E5B48"),
    ("appearance",
     "내 눈에 맞게", "여섯 가지 테마, 글꼴·크기·줄 간격까지 자유롭게",
     "Make it yours", "Six themes, plus font, size and line spacing",
     "#2E3D2F", "#FFFFFF", "#BFD3BE"),
    ("tts",
     "읽지 말고 들으세요", "한국어·영어 음성, 속도 조절과 취침 타이머",
     "Listen instead", "Korean and English voices, speed control, sleep timer",
     "#F7E9EC", "#3A1F27", "#7C5560"),
    ("highlight_menu",
     "밑줄 긋듯 하이라이트", "네 가지 색으로 표시하고 목록에서 바로 이동",
     "Highlight what matters", "Four colors, and jump back from the list any time",
     "#FFF4D6", "#3A2E12", "#7A6534"),
    ("bookmarks",
     "읽던 자리를 놓치지 않게", "북마크와 목차, 읽던 위치는 자동으로 저장",
     "Never lose your place", "Bookmarks, contents, and automatic resume",
     "#12203A", "#FFFFFF", "#AFC2E8"),
    ("korean_dark",
     "한글도 완벽하게", "EUC-KR·CP949 텍스트 자동 인식, 눈 편한 다크 모드",
     "Korean, done right", "Legacy encodings detected, easy-on-the-eyes dark mode",
     "#1A1A1E", "#FFFFFF", "#A9A9B4"),
    ("cloud",
     "클라우드에서 바로 가져오기", "Dropbox · Google Drive · OneDrive, 읽기 전용 권한만",
     "Straight from the cloud", "Dropbox · Google Drive · OneDrive, read-only access",
     "#E8F0FB", "#14243D", "#4F6584"),
    ("stats",
     "읽은 만큼 쌓이는 기록", "총 독서 시간과 연속으로 읽은 날",
     "Track your reading", "Total time read and your day streak",
     "#EAF7EF", "#12301E", "#3F6B51"),
]

DEVICES = {
    # canvas size, screenshot width, top of screenshot, headline size, sub size,
    # bezel, corner radius, headline top
    "iphone": dict(canvas=(1242, 2688), shot_w=1064, shot_top=470, h1=88, h2=42,
                   bezel=22, radius=110, text_top=150, prefix="iphone"),
    "ipad":   dict(canvas=(2064, 2752), shot_w=1740, shot_top=500, h1=118, h2=56,
                   bezel=30, radius=80, text_top=160, prefix="ipad"),
    # Mac windows are captured with their own rounded corners (alpha), so no
    # bezel is drawn. Landscape windows sit under a centred headline; portrait
    # reader windows sit on the right with the text beside them.
    "mac":    dict(canvas=(2880, 1800), prefix="mac", h1=104, h2=50, text_top=84,
                   shot_w=2240, shot_top=330,
                   tall_h=1580, tall_right=200, tall_h1=124, tall_h2=54,
                   shots={"highlight_menu": "highlights"}),
}


def rounded_mask(size, radius):
    m = Image.new("L", size, 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, size[0] - 1, size[1] - 1], radius=radius, fill=255)
    return m


def fit_text(draw, text, font_path, index, size, max_w):
    while size > 20:
        f = ImageFont.truetype(font_path, size, index=index)
        if draw.textlength(text, font=f) <= max_w:
            return f
        size -= 2
    return ImageFont.truetype(font_path, size, index=index)


def wrap(draw, text, font, max_w):
    lines, cur = [], ""
    for word in text.split(" "):
        trial = (cur + " " + word).strip()
        if cur and draw.textlength(trial, font=font) > max_w:
            lines.append(cur); cur = word
        else:
            cur = trial
    lines.append(cur)
    if len(lines) == 2:                 # balance two lines instead of leaving a stub
        words = text.split(" ")
        best = min(range(1, len(words)), key=lambda i: abs(
            draw.textlength(" ".join(words[:i]), font=font) - draw.textlength(" ".join(words[i:]), font=font)))
        if draw.textlength(" ".join(words[:best]), font=font) <= max_w:
            lines = [" ".join(words[:best]), " ".join(words[best:])]
    return lines


def compose_mac(lang, slide, n):
    d = DEVICES["mac"]
    shot, h_ko, s_ko, h_en, s_en, bg, fg, subfg = slide
    shot = d["shots"].get(shot, shot)
    head, sub = (h_ko, s_ko) if lang == "ko" else (h_en, s_en)
    W, H = d["canvas"]
    canvas = Image.new("RGB", (W, H), bg)
    draw = ImageDraw.Draw(canvas)
    src = Image.open(os.path.join(SHOTS, f"mac_{shot}.png")).convert("RGBA")

    if src.width > src.height:          # landscape window: headline on top
        sw = d["shot_w"]; sh = int(src.height * sw / src.width)
        x, y = (W - sw) // 2, d["shot_top"]
        f1 = fit_text(draw, head, FONT, BOLD, d["h1"], W - 200)
        f2 = fit_text(draw, sub, FONT, REG, d["h2"], W - 200)
        ty = d["text_top"]
        draw.text(((W - draw.textlength(head, font=f1)) / 2, ty), head, font=f1, fill=fg)
        ty += int(d["h1"] * 1.3)
        draw.text(((W - draw.textlength(sub, font=f2)) / 2, ty), sub, font=f2, fill=subfg)
    else:                               # portrait window: text on the left
        sh = d["tall_h"]; sw = int(src.width * sh / src.height)
        x, y = W - d["tall_right"] - sw, (H - sh) // 2
        left, max_w = 190, x - 190 - 130
        f1 = fit_text(draw, head, FONT, BOLD, d["tall_h1"], max_w)
        f2 = ImageFont.truetype(FONT, d["tall_h2"], index=REG)
        lines = wrap(draw, sub, f2, max_w)
        gap, lh = 56, int(d["tall_h2"] * 1.45)
        block = f1.size + gap + lh * len(lines)
        ty = (H - block) // 2
        draw.text((left, ty), head, font=f1, fill=fg)
        ty += f1.size + gap
        for line in lines:
            draw.text((left, ty), line, font=f2, fill=subfg); ty += lh

    src = src.resize((sw, sh), Image.LANCZOS)
    alpha = src.getchannel("A")
    shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    sh_layer = Image.new("RGBA", src.size, (0, 0, 0, 0))
    sh_layer.paste((0, 0, 0, 120), (0, 0), alpha)
    shadow.paste(sh_layer, (x, y + 28), sh_layer)
    shadow = shadow.filter(ImageFilter.GaussianBlur(44))
    canvas = Image.alpha_composite(canvas.convert("RGBA"), shadow)
    canvas.alpha_composite(src, (x, y))

    out_dir = os.path.join(OUT, lang, "mac")
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, f"{n:02d}_{shot}.png")
    canvas.convert("RGB").save(path, optimize=True)
    return path


def compose(device, lang, slide, n):
    if device == "mac":
        return compose_mac(lang, slide, n)
    d = DEVICES[device]
    shot, h_ko, s_ko, h_en, s_en, bg, fg, subfg = slide
    head, sub = (h_ko, s_ko) if lang == "ko" else (h_en, s_en)
    W, H = d["canvas"]
    canvas = Image.new("RGB", (W, H), bg)
    draw = ImageDraw.Draw(canvas)

    # Headline + subtitle, centered
    f1 = fit_text(draw, head, FONT, BOLD, d["h1"], W - 160)
    f2 = fit_text(draw, sub, FONT, REG, d["h2"], W - 160)
    y = d["text_top"]
    w1 = draw.textlength(head, font=f1)
    draw.text(((W - w1) / 2, y), head, font=f1, fill=fg)
    y += int(d["h1"] * 1.35)
    w2 = draw.textlength(sub, font=f2)
    draw.text(((W - w2) / 2, y), sub, font=f2, fill=subfg)

    # Screenshot with bezel, rounded corners and soft shadow
    src = Image.open(os.path.join(SHOTS, f"{d['prefix']}_{shot}.png")).convert("RGB")
    sw = d["shot_w"]
    sh = int(src.height * sw / src.width)
    src = src.resize((sw, sh), Image.LANCZOS)
    b = d["bezel"]
    r = d["radius"]
    frame = Image.new("RGB", (sw + 2 * b, sh + 2 * b), "#0B0B0D")
    frame.paste(src, (b, b), rounded_mask(src.size, r - b))
    frame_mask = rounded_mask(frame.size, r)
    x = (W - frame.width) // 2
    y = d["shot_top"]

    shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    sh_layer = Image.new("RGBA", frame.size, (0, 0, 0, 0))
    sh_layer.paste((0, 0, 0, 110), (0, 0), frame_mask)
    shadow.paste(sh_layer, (x, y + 30), sh_layer)
    shadow = shadow.filter(ImageFilter.GaussianBlur(40))
    canvas = Image.alpha_composite(canvas.convert("RGBA"), shadow).convert("RGB")
    canvas.paste(frame, (x, y), frame_mask)

    out_dir = os.path.join(OUT, lang, device)
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, f"{n:02d}_{shot}.png")
    canvas.save(path, optimize=True)
    return path


for device in DEVICES:
    if ONLY and device not in ONLY:
        continue
    for lang in ("ko", "en"):
        for i, slide in enumerate(SLIDES, 1):
            print(compose(device, lang, slide, i))
