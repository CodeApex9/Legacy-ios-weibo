#!/usr/bin/env python3
"""把当前 App 的真机截图按像素区域换成 iOS6 三套系统皮肤，用于预览。
不改产品代码，只生成 mockups 下的效果图。
保留：文字、头像、图片、按钮形状、布局；替换：导航条底色/缝线、亚麻背景、纸卡。
"""
import os
import sys
from PIL import Image

SRC = {'list': '/tmp/verify_1.png', 'detail': '/tmp/verify_2.png', 'account': '/tmp/verify_3.png'}
OUT = os.path.join(os.path.dirname(__file__), 'skins')
NAV_H = 110  # @2x 像素，52pt + 状态栏余量


def lin(c1, c2, t):
    return tuple(int(a + (b - a) * t) for a, b in zip(c1, c2))


def skin_nav(x, y, kind):
    """按皮肤生成导航条基准色（@2x 坐标）。
   高光/明暗由原图亮度贴图叠加（见 convert），这里只提供材质纹理。"""
    t = y / float(NAV_H)
    if kind == 'reminders':      # 深灰拉丝金属：细密横向拉丝
        base = lin((78, 78, 78), (26, 26, 26), t)
        strip = ((y // 4) % 2) * 7 - 3
        return tuple(max(0, min(255, v + strip)) for v in base)
    if kind == 'notes':          # 棕褐皮革：揉纹颗粒
        base = lin((128, 84, 56), (52, 30, 18), t)
        grain = ((x * 7 + y * 3) % 5) - 2
        return tuple(max(0, min(255, v + grain)) for v in base)
    if kind == 'gamecenter':     # 棕木纹：粗竖向木纹带
        base = lin((162, 100, 54), (84, 44, 20), t)
        grain = ((x // 8 + y // 12) % 7) - 3
        return tuple(max(0, min(255, v + grain * 3)) for v in base)
    return (19, 34, 52)


def skin_bg(x, y, kind):
    """亚麻底 -> 各皮肤背景纹理。"""
    if kind == 'reminders':      # 米白点格纸：22px 一个点，左 44px 红竖线
        v = (245, 243, 236)
        if x % 44 == 0 and y % 44 == 0:
            v = (216, 212, 200)
        if 40 <= x <= 42:
            v = (232, 166, 174)
        return v
    if kind == 'notes':          # 淡黄横线信纸：29px 一条线 + 细噪
        v = (253, 246, 184)
        if y % 58 in (56, 57):
            v = (185, 180, 149)
        g = ((x * 3 + y * 5) % 3) - 1
        return tuple(max(0, min(255, a + g)) for a in v)
    if kind == 'gamecenter':     # 绿毛毡桌布 + 噪点
        v = (44, 128, 84)
        g = ((x * 11 + y * 7) % 5) - 2
        return tuple(max(0, min(255, a + g * 2)) for a in v)
    return (237, 235, 228)


def skin_card(x, y, kind):
    """纸卡 -> 各皮肤卡片色。"""
    if kind == 'reminders':
        return (250, 249, 245)
    if kind == 'notes':
        return (253, 247, 196)
    if kind == 'gamecenter':
        # 绿毛毡上的浅木牌/羊皮纸卡：文字保持深色可读，不用深绿卡压字
        return (240, 226, 196)
    return (247, 247, 247)


def lum(c):
    """感知亮度，用来把原图明暗当光照贴图叠加到新皮肤。"""
    return 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]


def relight(base, c, base_lum, lo=0.55, hi=1.9):
    """以原像素 c 相对基准亮度的比例，重新照亮 base —— 高光/阴影得以保留。"""
    f = max(lo, min(hi, lum(c) / base_lum))
    return tuple(max(0, min(255, int(v * f))) for v in base)


NAV_BASE_LUM = 31.6    # 原导航条主色 (19,34,52) 的亮度
CARD_BASE_LUM = 247.0  # 原纸卡 (247,247,247)


def is_nav(rgb):
    r, g, b = rgb
    return b > r + 12 and r < 90 and g < 100


def is_stitch(rgb):
    """缝线/奶油符号：原图里偏亮的暖色像素。"""
    r, g, b = rgb
    return r > 140 and g > 130 and b < 190 and r > b + 18


def is_linen(rgb):
    r, g, b = rgb
    return 228 <= r <= 244 and 226 <= g <= 242 and 219 <= b <= 235 and abs(r - g) < 6


def is_card(rgb):
    return rgb[0] >= 244 and rgb[1] >= 244 and rgb[2] >= 244


STITCH = {
    'reminders':   (205, 205, 205),   # 金属上的浅缝线
    'notes':       (170, 132, 86),    # 皮革上的棕缝线
    'gamecenter':  (205, 174, 122),   # 木纹上的金缝线
}
CARD_BASE = {
    'reminders':   (250, 249, 245),
    'notes':       (253, 247, 196),
    'gamecenter':  (240, 226, 196),
}


def convert(src, dst, kind):
    im = Image.open(src).convert('RGB')
    px = im.load()
    w, h = im.size
    for y in range(h):
        for x in range(w):
            c = px[x, y]
            if y < NAV_H:
                if is_stitch(c):
                    # 去掉虚线：缝线像素不再描亮，直接用导航条材质色填平
                    px[x, y] = skin_nav(x, y, kind)
                elif is_nav(c):
                    # 关键：用原图像素亮度重新照亮皮肤色，玻璃高光/暗边/圆钮立体感全保留
                    px[x, y] = relight(skin_nav(x, y, kind), c, NAV_BASE_LUM)
                continue
            if is_card(c):
                # 卡片：保留原纸卡顶部高光和边缘阴影的相对明暗
                px[x, y] = relight(CARD_BASE[kind], c, CARD_BASE_LUM, 0.86, 1.06)
            elif is_linen(c):
                px[x, y] = skin_bg(x, y, kind)
    im.save(dst)
    print('saved', dst)


def main():
    os.makedirs(OUT, exist_ok=True)
    for kind in ('reminders', 'notes', 'gamecenter'):
        for scene, path in SRC.items():
            if not os.path.exists(path):
                print('missing', path); continue
            convert(path, os.path.join(OUT, f'{kind}-{scene}.png'), kind)


if __name__ == '__main__':
    main()
