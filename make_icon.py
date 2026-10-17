# -*- coding: utf-8 -*-
"""
make_icon.py — 生成 CamFix 的程序图标
设计: 蓝色渐变圆角底 + 白色相机机身 + 蓝色镜头 + 右下角绿色对勾(修复完成)
输出: app.ico (多尺寸) + icon-preview.png (预览用)
"""
from PIL import Image, ImageDraw

S = 1024                      # 超采样画布，最后缩到 256 再导出 ico
img = Image.new('RGBA', (S, S), (0, 0, 0, 0))

# ---------- 背景: 蓝色渐变 + 圆角 ----------
bg = Image.new('RGBA', (S, S), (0, 0, 0, 0))
bd = ImageDraw.Draw(bg)
top = (72, 152, 250)          # #4898FA
bot = (26, 76, 190)           # #1A4CBE
for y in range(S):
    t = y / (S - 1)
    r = int(top[0] + (bot[0] - top[0]) * t)
    g = int(top[1] + (bot[1] - top[1]) * t)
    b = int(top[2] + (bot[2] - top[2]) * t)
    bd.line([(0, y), (S, y)], fill=(r, g, b, 255))
mask = Image.new('L', (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, S - 1, S - 1], radius=int(S * 0.23), fill=255)
img.paste(bg, (0, 0), mask)

d = ImageDraw.Draw(img)
W = (255, 255, 255, 255)

# ---------- 相机: 顶部取景器凸起 ----------
d.rounded_rectangle([int(S * 0.315), int(S * 0.215), int(S * 0.475), int(S * 0.335)],
                    radius=int(S * 0.030), fill=W)

# ---------- 相机: 机身 ----------
body = [int(S * 0.155), int(S * 0.290), int(S * 0.845), int(S * 0.770)]
d.rounded_rectangle(body, radius=int(S * 0.075), fill=W)

# ---------- 镜头 ----------
cx, cy = int(S * 0.500), int(S * 0.530)
r_out = int(S * 0.160)
d.ellipse([cx - r_out, cy - r_out, cx + r_out, cy + r_out], fill=(18, 58, 140, 255))   # 深蓝外圈
r_mid = int(S * 0.118)
d.ellipse([cx - r_mid, cy - r_mid, cx + r_mid, cy + r_mid], fill=(56, 189, 248, 255))  # 亮青镜片
r_in = int(S * 0.062)
d.ellipse([cx - r_in, cy - r_in, cx + r_in, cy + r_in], fill=(12, 40, 100, 255))      # 瞳
# 镜片高光
hx, hy = cx - int(S * 0.052), cy - int(S * 0.055)
hr = int(S * 0.030)
d.ellipse([hx - hr, hy - hr, hx + hr, hy + hr], fill=(255, 255, 255, 225))

# ---------- 右下角: 绿色对勾徽章(表示"修复") ----------
bx, by = int(S * 0.755), int(S * 0.755)
br = int(S * 0.150)
d.ellipse([bx - br - int(S * 0.028), by - br - int(S * 0.028),
           bx + br + int(S * 0.028), by + br + int(S * 0.028)], fill=W)          # 白边
d.ellipse([bx - br, by - br, bx + br, by + br], fill=(34, 197, 94, 255))          # 绿底
# 对勾
lw = int(S * 0.040)
d.line([(bx - int(S * 0.072), by + int(S * 0.005)),
        (bx - int(S * 0.020), by + int(S * 0.055)),
        (bx + int(S * 0.080), by - int(S * 0.062))],
       fill=W, width=lw, joint='curve')

# ---------- 导出 ----------
icon256 = img.resize((256, 256), Image.LANCZOS)
icon256.save('app.ico', format='ICO',
             sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
icon256.save('icon-preview.png')
img.resize((512, 512), Image.LANCZOS).save('icon-preview-512.png')
# 另存几张不同尺寸的小图，便于肉眼检查小尺寸可辨识度
sheet = Image.new('RGBA', (16 + 32 + 48 + 64 + 16 * 4, 64), (245, 245, 245, 255))
x = 8
for sz in (16, 32, 48, 64):
    small = icon256.resize((sz, sz), Image.LANCZOS)
    sheet.paste(small, (x, (64 - sz) // 2), small)
    x += sz + 16
sheet.save('icon-sizes.png')
print('OK: app.ico / icon-preview.png / icon-preview-512.png / icon-sizes.png')
