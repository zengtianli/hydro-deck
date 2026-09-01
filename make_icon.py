#!/usr/bin/env python3
"""生成 app 图标：一滴水落进对话气泡 —— 这个 app 就是「对着水利知识库说话」。
亮底深字与 app 内主题一致；不用外部素材、不联网，重跑逐像素一致。"""
from PIL import Image, ImageDraw
import pathlib

S = 1024
BG     = (247, 247, 249)    # 浅底（iOS Form 背景同族）
BUBBLE = (10, 122, 255)     # systemBlue 对话气泡
DROP   = (255, 255, 255)    # 气泡内的水滴（反白）
DROP_HI = (191, 219, 254)   # 水滴高光

img = Image.new("RGB", (S, S), BG)
d = ImageDraw.Draw(img)

# 对话气泡：圆角矩形 + 左下小尾巴
M = 170
bx0, by0, bx1, by1 = M, M + 30, S - M, S - M - 40
d.rounded_rectangle([bx0, by0, bx1, by1], radius=170, fill=BUBBLE)
d.polygon([(bx0 + 90, by1 - 12), (bx0 + 250, by1 - 12), (bx0 + 110, by1 + 120)], fill=BUBBLE)

# 水滴：上尖下圆（圆 + 三角），居中偏上
cx = (bx0 + bx1) // 2
cy = (by0 + by1) // 2 + 40
R = 150
d.ellipse([cx - R, cy - R, cx + R, cy + R], fill=DROP)
d.polygon([(cx, cy - R * 2.1), (cx - R * 0.86, cy - R * 0.5), (cx + R * 0.86, cy - R * 0.5)], fill=DROP)
# 高光：左上小椭圆
d.ellipse([cx - R * 0.55, cy - R * 0.45, cx - R * 0.15, cy + R * 0.1], fill=DROP_HI)

out = pathlib.Path("Resources/icon-1024.png")
img.save(out)
print(f"✅ {out} {img.size[0]}x{img.size[1]}")
