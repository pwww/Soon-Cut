#!/usr/bin/env python3
"""Soon-Cut 商店截圖修圖：
   1. 模糊輸出清單裡那張真人訪談縮圖（肖像權 + 定位）
   2. 用新字框蓋掉 PivotTable（微軟商標）
   原圖不覆寫，輸出到 out/，確認後再換上去。
"""
import sys, os
from PIL import Image, ImageDraw, ImageFont, ImageFilter

SRC = "AppStore/screenshots"
OUT = sys.argv[1]
os.makedirs(OUT, exist_ok=True)

SFNS = "/System/Library/Fonts/SFNS.ttf"

def font(size, weight):
    f = ImageFont.truetype(SFNS, size)
    f.set_variation_by_name(weight)
    return f

# ── 真人縮圖位置（en-4 / en-5 / zh-Hant-4 / zh-Hant-5 都一樣）────────────
FACE_BOX = (1920, 1648, 2027, 1709)

def blur_faces(im):
    x0, y0, x1, y1 = FACE_BOX
    region = im.crop(FACE_BOX)
    w, h = region.size
    # 先降到 1/9 再放大 → 細節徹底毀掉，不是「看起來模糊但還原得回來」
    small = region.resize((max(1, w // 9), max(1, h // 9)), Image.BILINEAR)
    region = small.resize((w, h), Image.BILINEAR).filter(ImageFilter.GaussianBlur(4))
    im.paste(region, (x0, y0))
    return im

# ── PivotTable 兩處（en-2 / zh-Hant-2）─────────────────────────────────
# ink_box = 原本字的墨跡範圍；新字對齊同一個左上角（置中的那個對齊中心）
PATCHES = [
    dict(name="ribbon",
         clear=(236, 754, 366, 794), bg=(252, 252, 252),
         text="Summary", size=25, weight="Semibold", fill=(62, 70, 88),
         ink_left=243, ink_top=765, center_x=299),
    dict(name="header",
         clear=(1524, 902, 1752, 940), bg=(249, 249, 251),
         text="Summary Fields", size=28, weight="Bold", fill=(43, 50, 66),
         ink_left=1532, ink_top=911, center_x=None),
]

def cover_pivottable(im):
    d = ImageDraw.Draw(im)
    for p in PATCHES:
        d.rectangle(p["clear"], fill=p["bg"])
        f = font(p["size"], p["weight"])
        # 先畫在 (0,0) 量出墨跡偏移，再位移到跟原字一致
        bb = d.textbbox((0, 0), p["text"], font=f)
        x = p["ink_left"] - bb[0]
        if p["center_x"] is not None:
            x = p["center_x"] - (bb[0] + bb[2]) / 2
        y = p["ink_top"] - bb[1]
        d.text((x, y), p["text"], font=f, fill=p["fill"])
    return im

jobs = {
    "en-2": [cover_pivottable],
    "en-4": [blur_faces],
    "en-5": [blur_faces],
    "zh-Hant-2": [cover_pivottable],
    "zh-Hant-4": [blur_faces],
    "zh-Hant-5": [blur_faces],
}

for name, steps in jobs.items():
    im = Image.open(f"{SRC}/{name}.png").convert("RGB")
    assert im.size == (2880, 1800), f"{name} 尺寸不是 2880x1800：{im.size}"
    for s in steps:
        im = s(im)
    im.save(f"{OUT}/{name}.png")
    print(f"{name}: {' + '.join(s.__name__ for s in steps)}  ->  {OUT}/{name}.png")
