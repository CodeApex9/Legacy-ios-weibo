#!/usr/bin/env python3
"""生成 A 版（iOS 6 系统原生）拟物化纹理资源，纯标准库、无第三方依赖。

所有材质在 Mac 上逐像素/逐行预渲染成 PNG，设备端只显示位图，
不在 iPhone 5 上做实时 Core Graphics 绘制（512MB 内存考量）。

用法: python3 scripts/make_assets.py <输出目录>
"""
import os
import struct
import sys
import zlib

LINEN = (237, 235, 228)
WHITE = (246, 246, 246)

# 导航条高度（pt）：20pt 状态栏 + 32pt 条，比最早的 64pt 更紧凑。
# 位图与 RootViewController.m 的 kNavHeight 必须一致，否则会被拉伸。
NAV_PT = 52

NAV_STOPS = [
    (0.00, (86, 132, 206)),
    (0.12, (59, 110, 175)),
    (0.86, (43, 90, 158)),
    (1.00, (24, 63, 116)),
]

# ---- V0.3 皮革导航条 ------------------------------------------------------
# 深海军蓝皮革：比原蓝色渐变沉一档，配内嵌虚线缝线。
# 纹理由低频揉纹 + 高频颗粒两层确定性噪声叠成，纯标准库生成，不需要外部贴图。
LEATHER_STOPS = [
    (0.00, (66, 100, 145)),
    (0.16, (50, 81, 120)),
    (0.62, (39, 66, 100)),
    (1.00, (27, 49, 79)),
]
STITCH_COLOR = (152, 181, 214)
STITCH_INSET = 4          # 缝线距边缘 4pt
STITCH_DASH = 3           # 3 实 3 虚


def _hash01(i, j, seed):
    """确定性 0..1 伪随机，保证每次生成的纹理完全一致（避免二进制 diff 噪声）。"""
    n = (i * 73856093) ^ (j * 19349663) ^ ((seed + 1) * 83492791)
    n &= 0xFFFFFFFF
    n = (n ^ (n >> 15)) & 0xFFFFFFFF
    n = (n * 2654435761) & 0xFFFFFFFF
    return (n % 4096) / 4096.0


def _vnoise(x, y, cell, seed):
    """双线性插值的值噪声，cell 越大纹路越粗。"""
    gx, gy = x // cell, y // cell
    fx = (x % cell) / float(cell)
    fy = (y % cell) / float(cell)
    sx = fx * fx * (3.0 - 2.0 * fx)
    sy = fy * fy * (3.0 - 2.0 * fy)
    v00 = _hash01(gx, gy, seed)
    v10 = _hash01(gx + 1, gy, seed)
    v01 = _hash01(gx, gy + 1, seed)
    v11 = _hash01(gx + 1, gy + 1, seed)
    a = v00 + (v10 - v00) * sx
    b = v01 + (v11 - v01) * sx
    return a + (b - a) * sy


def _leather_delta(x, y, scale):
    """皮革质感偏移量（-1..1 附近）：粗揉纹 + 细颗粒。"""
    coarse = _vnoise(x, y, max(2, 6 * scale), 7)
    fine = _vnoise(x, y, max(1, 2 * scale), 21)
    return (coarse - 0.5) * 1.15 + (fine - 0.5) * 0.85


def _chunk(tag, data):
    return (struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))


def _write_png(path, width, height, raw):
    png = b"\x89PNG\r\n\x1a\n"
    png += _chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    png += _chunk(b"IDAT", zlib.compress(raw, 9))
    png += _chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


def write_png_rows(path, width, height, row_color):
    """row_color(y, height) -> (r, g, b)，适合竖直渐变/分区大图。"""
    raw = bytearray()
    for y in range(height):
        r, g, b = row_color(y, height)
        raw.append(0)
        raw.extend(bytes((r, g, b)) * width)
    _write_png(path, width, height, bytes(raw))


def write_png_pixels(path, width, height, pixel):
    """pixel(x, y, w, h) -> (r, g, b)，适合小图标（逐像素）。"""
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        for x in range(width):
            r, g, b = pixel(x, y, width, height)
            raw.append(r)
            raw.append(g)
            raw.append(b)
    _write_png(path, width, height, bytes(raw))


def _write_png_rgba(path, width, height, raw):
    """带 alpha 的 PNG（color type 6）。"""
    png = b"\x89PNG\r\n\x1a\n"
    png += _chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
    png += _chunk(b"IDAT", zlib.compress(raw, 9))
    png += _chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


def write_png_pixels_rgba(path, width, height, pixel):
    """pixel(x, y, w, h) -> (r, g, b, a)。"""
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        for x in range(width):
            r, g, b, a = pixel(x, y, width, height)
            raw.append(r)
            raw.append(g)
            raw.append(b)
            raw.append(a)
    _write_png_rgba(path, width, height, bytes(raw))


def lerp(a, b, t):
    return int(a + (b - a) * t + 0.5)


def grad(t):
    """蓝色导航条竖直渐变：顶部高光 -> 中段主色 -> 底部暗边。"""
    if t <= 0.0:
        return NAV_STOPS[0][1]
    for i in range(len(NAV_STOPS) - 1):
        t0, c0 = NAV_STOPS[i]
        t1, c1 = NAV_STOPS[i + 1]
        if t <= t1:
            k = (t - t0) / (t1 - t0)
            return (lerp(c0[0], c1[0], k),
                    lerp(c0[1], c1[1], k),
                    lerp(c0[2], c1[2], k))
    return NAV_STOPS[-1][1]


def nav_row(y, h):
    return grad(y / float(max(h - 1, 1)))


def _clamp(v):
    return 0 if v < 0 else (255 if v > 255 else int(v))


def nav_px(x, y, w, h, scale=1):
    """V0.3 皮革导航条：深海军蓝皮革 + 顶部高光 + 底部暗边 + 内嵌虚线缝线。"""
    t = y / float(max(h - 1, 1))
    base = _seg_grad(LEATHER_STOPS, t)
    d = _leather_delta(x, y, scale) * 12.0
    r, g, b = base[0] + d, base[1] + d, base[2] + d * 1.05

    if y == 0:                       # 顶部 1pt 高光
        r, g, b = r + 34, g + 32, b + 26
    if y == h - 1:                   # 底部暗边
        r, g, b = r - 20, g - 20, b - 18
    elif y == h - 2:
        r, g, b = r - 9, g - 9, b - 8

    inset = STITCH_INSET * scale
    dash = STITCH_DASH * scale
    on_h = (y == inset or y == h - 1 - inset) and inset <= x <= w - 1 - inset
    on_v = (x == inset or x == w - 1 - inset) and inset <= y <= h - 1 - inset
    if on_h and ((x - inset) // dash) % 2 == 0:
        r, g, b = STITCH_COLOR
    elif on_v and ((y - inset) // dash) % 2 == 0:
        r, g, b = STITCH_COLOR

    return (_clamp(r), _clamp(g), _clamp(b))


def launch_row(y, h, scale):
    """启动图：顶部 NAV_PT 与导航条皮革同色（避免启动瞬间蓝→皮革的跳变）。"""
    if y < NAV_PT * scale:
        return _seg_grad(LEATHER_STOPS, y / float(max(NAV_PT * scale - 1, 1)))
    return LINEN


def in_round_rect(x, y, w, h, r):
    if r <= 0:
        return True
    if x < r and y < r:
        return (x - r) ** 2 + (y - r) ** 2 <= r * r
    if x >= w - r and y < r:
        return (x - (w - 1 - r)) ** 2 + (y - r) ** 2 <= r * r
    if x < r and y >= h - r:
        return (x - r) ** 2 + (y - (h - 1 - r)) ** 2 <= r * r
    if x >= w - r and y >= h - r:
        return (x - (w - 1 - r)) ** 2 + (y - (h - 1 - r)) ** 2 <= r * r
    return True


def avatar_px(x, y, w, h):
    """默认头像占位：蓝色圆角方块 + 白色人形剪影。"""
    r = int(w * 0.18)
    if not in_round_rect(x, y, w, h, r):
        return LINEN
    hx, hy, hr = w / 2.0, h * 0.38, w * 0.17
    if (x - hx) ** 2 + (y - hy) ** 2 <= hr * hr:
        return WHITE
    sx, sy = w / 2.0, h * 1.02
    rx, ry = w * 0.32, h * 0.40
    if ((x - sx) / rx) ** 2 + ((y - sy) / ry) ** 2 <= 1.0:
        return WHITE
    return grad(y / float(max(h - 1, 1)))


def photo_px(x, y, w, h):
    """配图占位：灰色相框 + 简笔山与太阳，图片未下载完成时显示。"""
    border = max(2, int(w * 0.025))
    if x < border or y < border or x >= w - border or y >= h - border:
        return (198, 201, 205)
    sx, sy, sr = w * 0.68, h * 0.30, w * 0.10
    if (x - sx) ** 2 + (y - sy) ** 2 <= sr * sr:
        return (250, 249, 240)
    ridge = min(h * 0.78 - 0.62 * abs(x - w * 0.34),
                h * 0.86 - 0.50 * abs(x - w * 0.72))
    if y >= ridge:
        return (176, 183, 190)
    return (222, 224, 227)


def icon_px(x, y, w, h):
    """App 图标：蓝色渐变 + 白色同心圆（iOS 会自动切圆角）。"""
    c = grad(y / float(max(h - 1, 1)))
    dx, dy = x - w / 2.0, y - h / 2.0
    d = (dx * dx + dy * dy) ** 0.5
    if w * 0.27 <= d <= w * 0.37 or d <= w * 0.10:
        return (250, 250, 250)
    return c


# ---- 方案 A 三个 tab 的分段底图 -------------------------------------------
# 深蓝凹槽（未选中）+ 亮蓝凸起（选中），颜色取自导航蓝渐变体系。
# UISegmentedControl 会把这几种图按 state 自动切换，端段圆角由系统裁剪。
SEG_NORMAL = [
    (0.00, (14, 34, 64)),    # 槽顶：压深一档，压在皮革上才不"浮"
    (0.30, (22, 48, 84)),
    (0.72, (31, 63, 106)),
    (1.00, (41, 80, 130)),   # 槽底略亮（内反光）
]
SEG_SELECTED = [
    (0.00, (126, 180, 238)),  # 凸起顶：亮蓝高光
    (0.06, (105, 162, 226)),
    (0.50, (72, 132, 205)),
    (0.94, (52, 108, 182)),
    (1.00, (46, 98, 170)),    # 底边暗
]


def _seg_grad(stops, t):
    if t <= 0.0:
        return stops[0][1]
    for i in range(len(stops) - 1):
        t0, c0 = stops[i]
        t1, c1 = stops[i + 1]
        if t <= t1:
            k = (t - t0) / (t1 - t0)
            return (lerp(c0[0], c1[0], k),
                    lerp(c0[1], c1[1], k),
                    lerp(c0[2], c1[2], k))
    return stops[-1][1]


def seg_normal_px(x, y, w, h):
    """未选中段：深蓝凹槽底。顶部 3px 内阴影 + 底部 1px 内反光，凹得更深。"""
    c = _seg_grad(SEG_NORMAL, y / float(max(h - 1, 1)))
    if y < 3:                      # 槽口内阴影，越靠上越暗
        k = (3 - y) * 5
        c = (max(0, c[0] - k), max(0, c[1] - k), max(0, c[2] - k))
    if y == h - 1:                 # 槽底内反光
        c = (min(255, c[0] + 7), min(255, c[1] + 7), min(255, c[2] + 6))
    return c


def seg_selected_px(x, y, w, h):
    """选中段：深蓝槽底上嵌一块独立的亮蓝圆角块（四周留槽缝）。

    关键：块要自己带圆角、并且四边留出 margin，这样选中中间段时看起来
    就是"槽里浮起一颗圆角按钮"，而不是贴边的直角色块。
    """
    mx = max(3, int(w * 0.05))     # 左右留缝
    my = max(2, int(h * 0.09))     # 上下留缝
    r = max(4, int(h * 0.16))      # 圆角半径

    bx0, bx1 = mx, w - 1 - mx
    by0, by1 = my, h - 1 - my

    inside = (bx0 <= x <= bx1 and by0 <= y <= by1 and
              in_round_rect(x - bx0, y - by0, bx1 - bx0 + 1, by1 - by0 + 1, r))

    if not inside:
        # 块外：就是深蓝槽（和未选中段同色，缝隙自然衔接）
        return _seg_grad(SEG_NORMAL, y / float(max(h - 1, 1)))

    # 块内：亮蓝渐变 + 顶部高光 + 底部暗边 + 左右细描边
    t = (y - by0) / float(max(by1 - by0, 1))
    c = _seg_grad(SEG_SELECTED, t)
    if y <= by0 + 1:
        c = (min(255, c[0] + 26), min(255, c[1] + 24), min(255, c[2] + 18))
    if y >= by1 - 1:
        c = (max(0, c[0] - 14), max(0, c[1] - 14), max(0, c[2] - 14))
    if x <= bx0 + 1 or x >= bx1 - 1:
        c = (max(0, c[0] - 12), max(0, c[1] - 12), max(0, c[2] - 12))
    return c


def seg_divider_px(x, y, w, h):
    """段间分隔线：全透明（RGBA a=0）。

    槽本身是一整块深蓝，不需要可见分隔线；若这里画实色，会盖住
    选中块右侧的留缝，让圆角变成"贴边直角"。
    """
    return (0, 0, 0, 0)


def seg_block_px(x, y, w, h):
    """独立浮起的亮蓝圆角块（RGBA，块外透明）。

    作为覆盖在深蓝槽上的一层皮肤使用：四角圆角、边缘高光/暗边。
    尺寸即单个分段大小，透明区让下面的深蓝槽露出来形成留缝。
    """
    mx = max(3, int(w * 0.05))     # 左右留缝
    my = max(2, int(h * 0.08))     # 上下留缝
    r = max(6, int(h * 0.24))      # 圆角（越大越接近截图里的圆润感）

    bx0, bx1 = mx, w - 1 - mx
    by0, by1 = my, h - 1 - my
    if not (bx0 <= x <= bx1 and by0 <= y <= by1 and
            in_round_rect(x - bx0, y - by0, bx1 - bx0 + 1, by1 - by0 + 1, r)):
        return (0, 0, 0, 0)        # 块外：全透明

    t = (y - by0) / float(max(by1 - by0, 1))
    c = _seg_grad(SEG_SELECTED, t)
    if t < 0.30:                   # 上半段玻璃反光带
        k = (0.30 - t) / 0.30 * 10.0
        c = (min(255, int(c[0] + k)), min(255, int(c[1] + k)),
             min(255, int(c[2] + k * 0.9)))
    if y <= by0 + 1:               # 顶部高光（比 V0.1 更亮）
        c = (min(255, c[0] + 36), min(255, c[1] + 33), min(255, c[2] + 24))
    if y >= by1 - 1:               # 底边暗
        c = (max(0, c[0] - 20), max(0, c[1] - 20), max(0, c[2] - 18))
    if x <= bx0 + 1 or x >= bx1 - 1:
        c = (max(0, c[0] - 12), max(0, c[1] - 12), max(0, c[2] - 12))
    return (c[0], c[1], c[2], 255)


def panel_card_px(x, y, w, h, scale=1):
    """账号面板资料卡底图（RGBA，九宫格拉伸用）。

    纸白渐变 + 1px 暖灰描边 + 内嵌虚线缝线，圆角外透明。
    九宫格 cap 取 16pt：圆角 8 + 缝线 6 + 1px 缓冲。
    """
    r = 8 * scale
    if not in_round_rect(x, y, w, h, r):
        return (0, 0, 0, 0)

    t = y / float(max(h - 1, 1))
    c = _seg_grad([(0.0, (254, 253, 250)), (1.0, (247, 244, 234))], t)

    if x == 0 or y == 0 or x == w - 1 or y == h - 1:
        c = (198, 190, 168)                       # 描边
    elif y == scale:
        c = (255, 255, 255)                       # 顶部 1pt 高光
    return (int(c[0]), int(c[1]), int(c[2]), 255)


def stitch_px(x, y, w, h, axis, scale=1):
    """缝线平铺贴图（RGBA）：3pt 实 3pt 虚。

    不能烘进九宫格底图——中间拉伸会把虚线段拉长；做成 1pt 高的可平铺贴图，
    用 +colorWithPatternImage: 铺到 1pt 高的视图上，任意长度都是等距虚线。
    """
    dash = 3 * scale
    pos = x if axis == "h" else y
    if (pos // dash) % 2 == 0:
        return (188, 176, 148, 255)
    return (0, 0, 0, 0)


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "Resources"
    os.makedirs(out, exist_ok=True)

    for name, w, h, sc in [("NavBar.png", 320, NAV_PT, 1),
                           ("NavBar@2x.png", 640, NAV_PT * 2, 2)]:
        write_png_pixels(os.path.join(out, name), w, h,
                         lambda x, y, ww, hh, s=sc: nav_px(x, y, ww, hh, s))

    for name, w, h in [("Avatar.png", 44, 44), ("Avatar@2x.png", 88, 88)]:
        write_png_pixels(os.path.join(out, name), w, h, avatar_px)

    for name, w, h in [("Photo.png", 80, 80), ("Photo@2x.png", 160, 160)]:
        write_png_pixels(os.path.join(out, name), w, h, photo_px)

    # 方案 A 三个 tab 的分段底图。实际段宽约 (320-136)/3≈61pt、高 28pt，
    # 按 62x28 生成，基本 1:1 不拉伸，圆角/留缝比例才不会失真。
    seg_assets = [
        ("SegNormal.png", 62, 28, seg_normal_px),
        ("SegNormal@2x.png", 124, 56, seg_normal_px),
        ("SegSelected.png", 62, 28, seg_selected_px),
        ("SegSelected@2x.png", 124, 56, seg_selected_px),
    ]
    for name, w, h, fn in seg_assets:
        write_png_pixels(os.path.join(out, name), w, h, fn)

    # 分隔线：1x1 全透明（RGBA），避免盖住选中块两侧留缝
    for name in ("SegDivider.png", "SegDivider@2x.png"):
        write_png_pixels_rgba(os.path.join(out, name), 1, 1, seg_divider_px)

    # 独立浮起的选中块（RGBA），叠加在深蓝槽上；位置由代码按选中段计算。
    for name, w, h in [("SegBlock.png", 62, 28), ("SegBlock@2x.png", 124, 56)]:
        write_png_pixels_rgba(os.path.join(out, name), w, h, seg_block_px)

    # 缝线平铺贴图：横向 6x1（@2x 12x2）、纵向 1x6（@2x 2x12）
    for name, w, h, ax in [("StitchH.png", 6, 1, "h"), ("StitchH@2x.png", 12, 2, "h"),
                           ("StitchV.png", 1, 6, "v"), ("StitchV@2x.png", 2, 12, "v")]:
        sc = 2 if "@2x" in name else 1
        write_png_pixels_rgba(os.path.join(out, name), w, h,
                              lambda x, y, ww, hh, a=ax, s2=sc: stitch_px(x, y, ww, hh, a, s2))

    # 账号面板资料卡（九宫格）：纸白 + 描边，圆角外透明
    for name, w, h, sc in [("PanelCard.png", 48, 48, 1),
                           ("PanelCard@2x.png", 96, 96, 2)]:
        write_png_pixels_rgba(os.path.join(out, name), w, h,
                              lambda x, y, ww, hh, s=sc: panel_card_px(x, y, ww, hh, s))

    # App 图标：若 Resources 里已放入自定义图标（如从 IPA 提取的微博图标），
    # 保留不覆盖；否则才生成默认的蓝色同心圆图标。
    for name, w, h in [("Icon.png", 57, 57), ("Icon@2x.png", 114, 114)]:
        dst = os.path.join(out, name)
        if not os.path.exists(dst):
            write_png_pixels(dst, w, h, icon_px)

    for name, w, h, scale in [
        ("Default.png", 320, 480, 1),
        ("Default@2x.png", 640, 960, 2),
        ("Default-568h@2x.png", 640, 1136, 2),
    ]:
        write_png_rows(os.path.join(out, name), w, h,
                       lambda yy, hh, s=scale: launch_row(yy, hh, s))

    print("已生成纹理与图标:", ", ".join(sorted(os.listdir(out))))


if __name__ == "__main__":
    main()
