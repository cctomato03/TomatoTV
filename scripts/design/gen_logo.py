#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
TomatoTV LOGO 生成器（卡通「番茄 + 小电视」）。

用法：
    python scripts/design/gen_logo.py [--verify]

产物（design/logo/）：
    logo.svg                      矢量源（与 PNG 同一套几何参数）
    logo_1024.png ... logo_48.png 应用图标各尺寸（不透明，无自带圆角，平台自行裁切）
    layered/foreground_1024.png   鸿蒙分层图标前景（透明，内容落在安全区内）
    layered/background_1024.png   鸿蒙分层图标背景
    banner_tv_1280x720.png 等     智慧屏横版 banner
    splash_216.png                启动图

设计说明：
    外框是圆润的小电视（机身 + 屏幕 + 两个旋钮 + 喇叭 + 两只脚），
    屏幕里是一颗有表情的卡通番茄（红色果身 + 绿色花萼 + 高光 + 腮红），
    整体用暖色米白背景承托，保证在深色/浅色桌面都清晰。
"""

import math
import os
import sys

from PIL import Image, ImageDraw, ImageFilter

S = 4  # 超采样倍数：所有坐标以 1024 为基准，内部按 4096 绘制后再缩小

# ---------------- 配色 ----------------
BG_TOP = (255, 251, 248)
BG_BOTTOM = (251, 233, 229)
OUTLINE = (42, 28, 23)
TV_BODY = (255, 253, 250)
TV_BODY_SHADE = (243, 228, 220)
SCREEN = (255, 245, 239)
TOMATO = (229, 72, 53)
TOMATO_SHADE = (195, 48, 31)
LEAF = (76, 175, 80)
LEAF_DARK = (62, 142, 65)
STEM = (56, 132, 60)
HIGHLIGHT = (255, 255, 255)
CHEEK = (245, 138, 122)
WHITE = (255, 255, 255)
PUPIL = (42, 28, 23)

# ---------------- 几何（1024 基准） ----------------
TV_LEFT, TV_TOP, TV_RIGHT, TV_BOTTOM = 140, 196, 884, 812
TV_RADIUS = 120
BODY_STROKE = 30

SCREEN_LEFT, SCREEN_TOP, SCREEN_RIGHT, SCREEN_BOTTOM = 206, 262, 704, 746
SCREEN_RADIUS = 60
SCREEN_STROKE = 24

KNOB_CENTERS = [(762, 358), (762, 462)]
KNOB_RADIUS = 34
KNOB_STROKE = 22

SPEAKER_X0, SPEAKER_X1 = 726, 826
SPEAKER_YS = [556, 602, 648]
SPEAKER_WIDTH = 15

FOOT_RECTS = [(292, 798, 396, 862), (636, 798, 740, 862)]
FOOT_RADIUS = 22
FOOT_STROKE = 22

TOMATO_CX, TOMATO_CY, TOMATO_R = 455, 502, 166


def sc(v):
    return int(round(v * S))


def box(x0, y0, x1, y1):
    return (sc(x0), sc(y0), sc(x1), sc(y1))


def vertical_gradient(size, top, bottom):
    grad = Image.new('RGB', (1, size), top)
    for y in range(size):
        t = y / max(1, size - 1)
        grad.putpixel((0, y), (
            int(top[0] + (bottom[0] - top[0]) * t),
            int(top[1] + (bottom[1] - top[1]) * t),
            int(top[2] + (bottom[2] - top[2]) * t),
        ))
    return grad.resize((size, size), Image.BILINEAR)


def draw_tv(base, with_face=True, inset=None):
    """在透明图层上绘制 TV + 番茄，返回 RGBA 图层。"""
    w = h = sc(1024)
    layer = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)

    stroke = sc(BODY_STROKE)
    screen_stroke = sc(SCREEN_STROKE)

    # 机身柔和投影（先画，位于最底层）
    shadow_layer = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    shd = ImageDraw.Draw(shadow_layer)
    shd.rounded_rectangle(box(TV_LEFT + 18, TV_TOP + 26, TV_RIGHT - 18, TV_BOTTOM + 26),
                          radius=sc(TV_RADIUS), fill=OUTLINE + (46,))
    shadow_layer = shadow_layer.filter(ImageFilter.GaussianBlur(sc(16)))
    layer = Image.alpha_composite(layer, shadow_layer)
    d = ImageDraw.Draw(layer)

    # 脚（先画，被机身压住上沿）
    for (x0, y0, x1, y1) in FOOT_RECTS:
        d.rounded_rectangle(box(x0, y0, x1, y1), radius=sc(FOOT_RADIUS), fill=TV_BODY,
                            outline=OUTLINE, width=sc(FOOT_STROKE))

    # 机身
    d.rounded_rectangle(box(TV_LEFT, TV_TOP, TV_RIGHT, TV_BOTTOM), radius=sc(TV_RADIUS),
                        fill=TV_BODY, outline=OUTLINE, width=stroke)

    # 机身下方的轻微阴影，增加体积感
    shade = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shade)
    sd.rounded_rectangle(box(TV_LEFT + 46, TV_BOTTOM - 86, TV_RIGHT - 46, TV_BOTTOM - 22),
                         radius=sc(46), fill=TV_BODY_SHADE + (150,))
    layer = Image.alpha_composite(layer, shade)
    d = ImageDraw.Draw(layer)

    # 屏幕
    d.rounded_rectangle(box(SCREEN_LEFT, SCREEN_TOP, SCREEN_RIGHT, SCREEN_BOTTOM),
                        radius=sc(SCREEN_RADIUS), fill=SCREEN, outline=OUTLINE,
                        width=screen_stroke)

    # 旋钮
    for (cx, cy) in KNOB_CENTERS:
        d.ellipse(box(cx - KNOB_RADIUS, cy - KNOB_RADIUS, cx + KNOB_RADIUS, cy + KNOB_RADIUS),
                  fill=WHITE, outline=OUTLINE, width=sc(KNOB_STROKE))

    # 喇叭格栅
    for y in SPEAKER_YS:
        d.rounded_rectangle(box(SPEAKER_X0, y, SPEAKER_X1, y + SPEAKER_WIDTH),
                            radius=sc(SPEAKER_WIDTH / 2), fill=OUTLINE)

    # ---- 番茄 ----
    cx, cy, r = TOMATO_CX, TOMATO_CY, TOMATO_R
    d.ellipse(box(cx - r, cy - r, cx + r, cy + r), fill=TOMATO)

    # 果身下侧阴影
    shadow = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    sdd = ImageDraw.Draw(shadow)
    sdd.ellipse(box(cx - r * 0.94, cy - r * 0.62, cx + r * 0.94, cy + r * 1.04),
                fill=TOMATO_SHADE + (110,))
    layer = Image.alpha_composite(layer, shadow)
    d = ImageDraw.Draw(layer)

    # 高光
    glare = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glare)
    gd.ellipse(box(cx - r * 0.62, cy - r * 0.72, cx - r * 0.06, cy - r * 0.16),
               fill=HIGHLIGHT + (120,))
    glare = glare.filter(ImageFilter.GaussianBlur(sc(6)))
    layer = Image.alpha_composite(layer, glare)
    d = ImageDraw.Draw(layer)

    # 花萼（5 片叶子）
    leaf_len = r * 0.62
    leaf_w = r * 0.30
    top_x, top_y = cx, cy - r * 0.86
    for ang in (-150, -118, -62, -30, -90):
        a = math.radians(ang)
        tip_x = top_x + math.cos(a) * leaf_len
        tip_y = top_y + math.sin(a) * leaf_len
        nx, ny = -math.sin(a) * leaf_w * 0.5, math.cos(a) * leaf_w * 0.5
        mid_x = top_x + math.cos(a) * leaf_len * 0.55
        mid_y = top_y + math.sin(a) * leaf_len * 0.55
        d.polygon([
            (sc(top_x), sc(top_y)),
            (sc(mid_x + nx), sc(mid_y + ny)),
            (sc(tip_x), sc(tip_y)),
            (sc(mid_x - nx), sc(mid_y - ny)),
        ], fill=LEAF if abs(ang) != 90 else LEAF_DARK)

    # 果蒂
    d.rounded_rectangle(box(top_x - r * 0.075, top_y - r * 0.30, top_x + r * 0.075, top_y + r * 0.06),
                        radius=sc(r * 0.075), fill=STEM)

    if with_face:
        # 腮红
        cheek = Image.new('RGBA', (w, h), (0, 0, 0, 0))
        cd = ImageDraw.Draw(cheek)
        for dx in (-r * 0.58, r * 0.58):
            cd.ellipse(box(cx + dx - r * 0.15, cy + r * 0.16 - r * 0.10,
                           cx + dx + r * 0.15, cy + r * 0.16 + r * 0.10),
                       fill=CHEEK + (150,))
        cheek = cheek.filter(ImageFilter.GaussianBlur(sc(4)))
        layer = Image.alpha_composite(layer, cheek)
        d = ImageDraw.Draw(layer)

        # 眼睛
        eye_dx, eye_dy, eye_r = r * 0.32, r * 0.14, r * 0.155
        for sign in (-1, 1):
            ex = cx + sign * eye_dx
            ey = cy - eye_dy
            d.ellipse(box(ex - eye_r, ey - eye_r, ex + eye_r, ey + eye_r), fill=WHITE)
            pr = eye_r * 0.56
            px = ex + sign * eye_r * 0.10
            py = ey + eye_r * 0.06
            d.ellipse(box(px - pr, py - pr, px + pr, py + pr), fill=PUPIL)

        # 微笑
        mouth_w, mouth_h = r * 0.30, r * 0.20
        mouth_y = cy + r * 0.30
        d.arc(box(cx - mouth_w, mouth_y - mouth_h, cx + mouth_w, mouth_y + mouth_h),
              start=15, end=165, fill=OUTLINE, width=sc(9))

    return layer


def compose(bg_image, artwork):
    canvas = bg_image.copy()
    canvas = Image.alpha_composite(canvas.convert('RGBA'), artwork)
    return canvas


def make_icon(size, with_face=True, padding=1.0, transparent=False):
    """生成指定尺寸图标。padding<1 时把画面缩小（用于分层图标安全区）。"""
    canvas_size = sc(1024)
    bg = vertical_gradient(canvas_size, BG_TOP, BG_BOTTOM).convert('RGBA') \
        if not transparent else Image.new('RGBA', (canvas_size, canvas_size), (0, 0, 0, 0))
    art = draw_tv(None, with_face=with_face)
    if padding != 1.0:
        inner = int(canvas_size * padding)
        art = art.resize((inner, inner), Image.LANCZOS)
        offset = (canvas_size - inner) // 2
        shifted = Image.new('RGBA', (canvas_size, canvas_size), (0, 0, 0, 0))
        shifted.paste(art, (offset, offset), art)
        art = shifted
    out = compose(bg, art)
    return out.resize((size, size), Image.LANCZOS)


def make_banner(width, height):
    """智慧屏横版 banner：左侧 logo，右侧留白（平台上叠加应用名/描述）。"""
    unit = height / 1024.0
    big_w = int(round(1024 * unit))
    icon = make_icon(big_w, with_face=True, padding=0.86, transparent=True)
    canvas = vertical_gradient(max(width, height), BG_TOP, BG_BOTTOM).convert('RGBA').resize(
        (width, height), Image.LANCZOS)
    x = max(0, int(width * 0.06))
    y = max(0, (height - big_w) // 2)
    canvas.paste(icon, (x, y), icon)
    return canvas


def svg_source():
    """与 PNG 同一套几何的矢量版本（1024 viewBox）。"""
    leaves = []
    r = TOMATO_R
    leaf_len = r * 0.62
    leaf_w = r * 0.30
    top_x, top_y = TOMATO_CX, TOMATO_CY - r * 0.86
    for ang in (-150, -118, -62, -30, -90):
        a = math.radians(ang)
        tip_x = top_x + math.cos(a) * leaf_len
        tip_y = top_y + math.sin(a) * leaf_len
        nx, ny = -math.sin(a) * leaf_w * 0.5, math.cos(a) * leaf_w * 0.5
        mid_x = top_x + math.cos(a) * leaf_len * 0.55
        mid_y = top_y + math.sin(a) * leaf_len * 0.55
        fill = '#3E8E41' if abs(ang) == 90 else '#4CAF50'
        leaves.append(
            '<polygon points="%.1f,%.1f %.1f,%.1f %.1f,%.1f %.1f,%.1f" fill="%s"/>' % (
                top_x, top_y, mid_x + nx, mid_y + ny, tip_x, tip_y, mid_x - nx, mid_y - ny, fill))
    speaker = ''.join(
        '<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" rx="%.1f" fill="#2A1C17"/>' % (
            SPEAKER_X0, y, SPEAKER_X1 - SPEAKER_X0, SPEAKER_WIDTH, SPEAKER_WIDTH / 2)
        for y in SPEAKER_YS)
    feet = ''.join(
        '<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" rx="%.1f" fill="#FFFDFA" '
        'stroke="#2A1C17" stroke-width="26"/>' % (x0, y0, x1 - x0, y1 - y0, FOOT_RADIUS)
        for (x0, y0, x1, y1) in FOOT_RECTS)
    knobs = ''.join(
        '<circle cx="%.1f" cy="%.1f" r="%.1f" fill="#FFFFFF" stroke="#2A1C17" stroke-width="22"/>' % (
            cx, cy, KNOB_RADIUS) for (cx, cy) in KNOB_CENTERS)

    return """<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#FFFBF8"/>
      <stop offset="1" stop-color="#FBE9E5"/>
    </linearGradient>
    <radialGradient id="glare" cx="0.35" cy="0.28" r="0.35">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.75"/>
      <stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
    </radialGradient>
    <radialGradient id="shade" cx="0.5" cy="0.78" r="0.6">
      <stop offset="0" stop-color="#C3301F" stop-opacity="0.55"/>
      <stop offset="1" stop-color="#C3301F" stop-opacity="0"/>
    </radialGradient>
  </defs>
  <rect width="1024" height="1024" fill="url(#bg)"/>
  %s
  <rect x="%d" y="%d" width="%d" height="%d" rx="%d" fill="#FFFDFA" stroke="#2A1C17" stroke-width="30"/>
  <rect x="%d" y="%d" width="%d" height="%d" rx="%d" fill="#FFF5EF" stroke="#2A1C17" stroke-width="24"/>
  %s
  %s
  <circle cx="%d" cy="%d" r="%d" fill="#E54835"/>
  <circle cx="%d" cy="%d" r="%d" fill="url(#shade)"/>
  <ellipse cx="%d" cy="%d" rx="%d" ry="%d" fill="url(#glare)"/>
  %s
  <rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" rx="%.1f" fill="#388C3C"/>
  <circle cx="%.1f" cy="%.1f" r="%.1f" fill="#FFFFFF"/>
  <circle cx="%.1f" cy="%.1f" r="%.1f" fill="#FFFFFF"/>
  <circle cx="%.1f" cy="%.1f" r="%.1f" fill="#2A1C17"/>
  <circle cx="%.1f" cy="%.1f" r="%.1f" fill="#2A1C17"/>
  <path d="M %.1f %.1f A %.1f %.1f 0 0 0 %.1f %.1f" fill="none" stroke="#2A1C17" stroke-width="9"
        stroke-linecap="round"/>
</svg>
""" % (
        feet,
        TV_LEFT, TV_TOP, TV_RIGHT - TV_LEFT, TV_BOTTOM - TV_TOP, TV_RADIUS,
        SCREEN_LEFT, SCREEN_TOP, SCREEN_RIGHT - SCREEN_LEFT, SCREEN_BOTTOM - SCREEN_TOP, SCREEN_RADIUS,
        knobs, speaker,
        TOMATO_CX, TOMATO_CY, TOMATO_R,
        int(TOMATO_CX), int(TOMATO_CY + TOMATO_R * 0.25), int(TOMATO_R * 0.9),
        int(TOMATO_CX - TOMATO_R * 0.34), int(TOMATO_CY - TOMATO_R * 0.44),
        int(TOMATO_R * 0.30), int(TOMATO_R * 0.26),
        ''.join(leaves),
        top_x - r * 0.075, top_y - r * 0.30, r * 0.15, r * 0.36, r * 0.075,
        TOMATO_CX - r * 0.32, TOMATO_CY - r * 0.14, r * 0.155,
        TOMATO_CX + r * 0.32, TOMATO_CY - r * 0.14, r * 0.155,
        TOMATO_CX - r * 0.32, TOMATO_CY - r * 0.10, r * 0.087,
        TOMATO_CX + r * 0.32, TOMATO_CY - r * 0.10, r * 0.087,
        TOMATO_CX - r * 0.30, TOMATO_CY + r * 0.40,
        r * 0.30, r * 0.20,
        TOMATO_CX + r * 0.30, TOMATO_CY + r * 0.40,
    )


def verify(path):
    """粗略自检：把图标降采样成字符画，确认"电视外框 + 番茄"的轮廓成立。"""
    img = Image.open(path).convert('RGB')
    w = 46
    h = 23
    small = img.resize((w, h), Image.LANCZOS)
    rows = []
    for y in range(h):
        row = ''
        for x in range(w):
            r, g, b = small.getpixel((x, y))
            lum = (r * 299 + g * 587 + b * 114) // 1000
            if r > 150 and g < 120 and b < 110 and r - g > 60:
                row += 'R'
            elif g > 110 and g - r > 20:
                row += 'G'
            elif lum < 110:
                row += '#'
            elif lum > 238:
                row += '.'
            else:
                row += ':'
        rows.append(row)
    print('\n'.join(rows))
    center = img.getpixel((img.width // 2, int(img.height * 0.42)))
    corner = img.getpixel((4, 4))
    print(f'center={center} corner={corner}')
    assert center[0] > 150 and center[0] > center[1], '番茄颜色异常：中心应为红色'
    assert corner[0] > 230, '背景颜色异常：角上应为浅色'


def main():
    out_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(
        os.path.abspath(__file__)))), 'design', 'logo')
    os.makedirs(out_dir, exist_ok=True)
    layered_dir = os.path.join(out_dir, 'layered')
    os.makedirs(layered_dir, exist_ok=True)

    # 1) 应用图标各尺寸（不透明，不带圆角，平台自行裁切）
    for size in (1024, 512, 256, 216, 192, 144, 96, 72, 48):
        icon = make_icon(size, with_face=True).convert('RGB')
        icon.save(os.path.join(out_dir, f'logo_{size}.png'))
        print(f'logo_{size}.png')

    # 2) 无表情版本（备选）
    make_icon(1024, with_face=False).convert('RGB').save(os.path.join(out_dir, 'logo_1024_plain.png'))

    # 3) 鸿蒙分层图标：前景（透明 + 安全区留白）+ 背景
    fg = make_icon(1024, with_face=True, padding=0.66, transparent=True)
    fg.save(os.path.join(layered_dir, 'foreground_1024.png'))
    bg = vertical_gradient(sc(1024), BG_TOP, BG_BOTTOM).convert('RGB').resize((1024, 1024), Image.LANCZOS)
    bg.save(os.path.join(layered_dir, 'background_1024.png'))
    fg.resize((216, 216), Image.LANCZOS).save(os.path.join(layered_dir, 'foreground_216.png'))

    # 4) 智慧屏横版 banner
    for (w, h) in ((1280, 720), (640, 360), (320, 180)):
        make_banner(w, h).convert('RGB').save(os.path.join(out_dir, f'banner_tv_{w}x{h}.png'))

    # 5) 启动图与商店展示用大方图
    make_icon(1024, with_face=True, padding=0.66).convert('RGB').save(
        os.path.join(out_dir, 'splash_1024.png'))
    make_icon(216, with_face=True, padding=0.66).convert('RGB').save(
        os.path.join(out_dir, 'splash_216.png'))

    # 6) 矢量源
    with open(os.path.join(out_dir, 'logo.svg'), 'w', encoding='utf-8') as handle:
        handle.write(svg_source())
    print('logo.svg')

    if '--verify' in sys.argv:
        verify(os.path.join(out_dir, 'logo_216.png'))


if __name__ == '__main__':
    main()
