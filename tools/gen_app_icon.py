#!/usr/bin/env python3
"""ClipVault 应用图标生成器（2026-10-07，替代默认 Flutter 图标）。

设计：X（平台语义）+ 下载箭头落入托盘（视频下载语义），白色字形，
深青渐变底（呼应 app.dart 主题 seedColor 0xFF00696F）。

产出（幂等，重复运行覆盖为相同内容）：
- Android 传统五档 ic_launcher.png（圆角方形烘焙 + 透明外边，<8.0 兜底）
- Android 自适应图标：mipmap-anydpi-v26/ic_launcher.xml（background +
  foreground + monochrome）与各密度前景/背景 PNG（8.0+ 全尺寸显示、
  13+ 主题色单色图标）
- iOS AppIcon.appiconset 全部既有文件按原尺寸重绘（方角不透明，圆角
  由系统裁切；1024 无 alpha，App Store 校验要求）

用法：python3 tools/gen_app_icon.py [--root <仓库根>]
字形经 4x 超采样绘制后 LANCZOS 缩小，保证 48px 档边缘干净。
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from PIL import Image, ImageDraw

# ---- 品牌色（app.dart seedColor 0xFF00696F 的渐变两极）----
GRAD_TOP = (0, 132, 148)  # #008494
GRAD_BOTTOM = (0, 74, 86)  # #004A56
WHITE = (255, 255, 255)

SS = 4  # 超采样倍数


def vertical_gradient(size: int) -> Image.Image:
    img = Image.new("RGB", (size, size))
    d = ImageDraw.Draw(img)
    for y in range(size):
        t = y / max(size - 1, 1)
        d.line(
            [(0, y), (size - 1, y)],
            fill=tuple(round(GRAD_TOP[i] + (GRAD_BOTTOM[i] - GRAD_TOP[i]) * t) for i in range(3)),
        )
    return img


def rounded_mask(size: int, radius: int) -> Image.Image:
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return m


def draw_glyph(d: ImageDraw.ImageDraw, s: float, color=WHITE) -> None:
    """在边长 s 的画布上按比例绘制「X + 下载箭头入托盘」字形。

    X 字形按官方 X 标志实测几何重建（2026-10-07 三轮定向，用户观察：
    「\\ 外形粗线条细，/ 外形细线条粗，整体均衡」）——对公开品牌资源
    SVG path 的像素级测量结论（单位换算到本画布）：
    - bbox 宽高比 1.106（宽扁）+ 顶部右倾剪切 ~0.22（动势来源）；
    - 「/」轴向 49.7°，实心整笔，线宽 = 0.128 × X 全高（相对很细）；
    - 「\\」轴向 52.6°，**通长镂空**为两条平行细线（各 0.775 × 「/」线宽，
      缝 0.62 ×），总带宽 ≈ 2.17 × 「/」线宽（外形粗、线条细）。
    差异化：外端圆头笔画（官方为斜切角端），借鉴而非复制。
    箭头/托盘随 X 变轻同步收窄，保持全局视觉重量平衡。

    五轮定向（2026-10-07 真机实测）：字形 bbox 收敛正方形、四周留白
    一致。六轮定向（2026-10-07 用户对比确认二稿）：X 更扁（轴角
    42°/44°，保留「\」比「/」略陡关系）+ 箭头加长（视觉高度
    0.106→0.138）+ 托盘 = 1.15 × X 臂展（0.663）；bbox 0.66 方形，
    像素实测留白 108/108/108/109 基本一致。
    """
    import math

    cx = 0.50 * s
    y_c = 0.3885 * s  # X 纵向中心
    h_x = 0.195 * s  # X 垂直半跨
    wf = 0.050 * s  # 「/」实心线宽
    wb = 0.039 * s  # 「\」单条细线宽（0.775 × wf 官方比例）
    gap = 0.031 * s  # 「\」两线间缝（0.62 × wf 官方比例）
    shear = 0.24  # 顶部右倾剪切率

    def t_sh(x: float, y: float) -> tuple[float, float]:
        return (x + shear * (y_c - y), y)

    def stroke(p1: tuple[float, float], p2: tuple[float, float], w: float) -> None:
        r = w / 2
        d.line([p1, p2], fill=color, width=round(w))
        for px, py in (p1, p2):
            d.ellipse([px - r, py - r, px + r, py + r], fill=color)

    # 「\」两条平行细线（通长镂空；轴向 44°，法向错开 ±(wb+gap)/2）。
    # 端部包络对齐（四轮定向）：两线圆头外缘的顶/底落在「/」圆头外缘
    # 同一水平包络上。
    ang_b = math.radians(44.0)
    y_top_tip = y_c - h_x - wf / 2  # 「/」顶部包络（含圆头）
    y_bot_tip = y_c + h_x + wf / 2
    for side in (-1, 1):
        off = side * (wb + gap) / 2
        ox, oy = off * -math.sin(ang_b), off * math.cos(ang_b)
        # 沿轴参数 t 反解：端点圆心 y = 包络 ∓ wb/2
        t_top = (y_top_tip + wb / 2 - y_c - oy) / math.sin(ang_b)
        t_bot = (y_bot_tip - wb / 2 - y_c - oy) / math.sin(ang_b)
        stroke(
            t_sh(cx + ox + t_top * math.cos(ang_b), y_c + oy + t_top * math.sin(ang_b)),
            t_sh(cx + ox + t_bot * math.cos(ang_b), y_c + oy + t_bot * math.sin(ang_b)),
            wb,
        )
    # 「/」实心整笔（轴向 42°，最后绘制压上层——细带粗线）
    ang_f = math.radians(42.0)
    dx_f = h_x / math.tan(ang_f)
    stroke(
        t_sh(cx - dx_f, y_c + h_x),
        t_sh(cx + dx_f, y_c - h_x),
        wf,
    )
    # 下载箭头（六轮加长：杆 0.068 + 头 0.078，视觉高 0.138）
    # + 托盘（= 1.15 × X 臂展，基座）
    stem_w = 0.045 * s
    d.rounded_rectangle(
        [cx - stem_w / 2, 0.632 * s, cx + stem_w / 2, 0.700 * s],
        radius=stem_w / 2,
        fill=color,
    )
    head = 0.118 * s
    d.polygon(
        [(cx - head, 0.692 * s), (cx + head, 0.692 * s), (cx, 0.770 * s)],
        fill=color,
    )
    d.rounded_rectangle(
        [0.1685 * s, 0.780 * s, 0.8315 * s, 0.830 * s],
        radius=0.024 * s,
        fill=color,
    )


def glyph_layer(canvas: int, color=WHITE) -> Image.Image:
    """透明画布 + 字形（超采样绘制后缩小）。"""
    big = Image.new("RGBA", (canvas * SS, canvas * SS), (0, 0, 0, 0))
    draw_glyph(ImageDraw.Draw(big), canvas * SS, color)
    return big.resize((canvas, canvas), Image.LANCZOS)


def legacy_icon(size: int) -> Image.Image:
    """Android 传统图标：圆角方形烘焙（半径 21.5%）+ 渐变 + 字形。"""
    grad = vertical_gradient(size).convert("RGBA")
    icon = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    icon.paste(grad, (0, 0), rounded_mask(size, round(size * 0.215)))
    icon.alpha_composite(glyph_layer(size))
    return icon


def ios_icon(size: int) -> Image.Image:
    """iOS 图标：方角全出血不透明（系统裁圆角；1024 需无 alpha）。"""
    icon = vertical_gradient(size).convert("RGBA")
    icon.alpha_composite(glyph_layer(size))
    return icon.convert("RGB")


def adaptive_foreground(size: int) -> Image.Image:
    """自适应前景：透明画布 + 字形缩放到中央。

    比例按**可见窗口**折算（2026-10-07 真机反馈修复）：108dp 画布中
    启动器遮罩只显示中央 ~72dp——62% 画布会让字形占满可见区（几乎无
    留白）；42% 画布 ≈ 可见窗口的 63%，四周留白 ~18%，圆形遮罩下
    方形字形对角线也不出界（45dp×√2=64 < 72）。
    """
    layer = glyph_layer(1024)
    bbox = layer.getbbox()
    glyph = layer.crop(bbox)
    target_h = round(size * 0.42)
    target_w = round(glyph.width * target_h / glyph.height)
    scaled = glyph.resize((target_w, target_h), Image.LANCZOS)
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    canvas.alpha_composite(scaled, ((size - target_w) // 2, (size - target_h) // 2))
    return canvas


def adaptive_background(size: int) -> Image.Image:
    """自适应背景：全出血渐变（形状遮罩由系统处理）。"""
    return vertical_gradient(size)


ADAPTIVE_XML = """<?xml version="1.0" encoding="utf-8"?>
<!-- ClipVault 自适应图标（8.0+）：渐变背景 + X/下载字形前景；
     monochrome 复用前景供 13+ 主题色图标。传统 PNG 由 mipmap 兜底。 -->
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@mipmap/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
    <monochrome android:drawable="@mipmap/ic_launcher_foreground" />
</adaptive-icon>
"""

LEGACY_DENSITIES = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
ADAPTIVE_DENSITIES = {"mdpi": 108, "hdpi": 162, "xhdpi": 216, "xxhdpi": 324, "xxxhdpi": 432}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=str(Path(__file__).resolve().parent.parent), help="仓库根目录")
    args = parser.parse_args()
    root = Path(args.root)

    written: list[str] = []

    # Android 传统五档（尺寸与现存文件核对，防模板漂移）
    for dpi, size in LEGACY_DENSITIES.items():
        path = root / "android/app/src/main/res" / f"mipmap-{dpi}" / "ic_launcher.png"
        if not path.exists():
            print(f"缺少 {path}", file=sys.stderr)
            return 1
        legacy_icon(size).save(path)
        written.append(f"{path.relative_to(root)} ({size}x{size})")

    # Android 自适应（8.0+）
    for dpi, size in ADAPTIVE_DENSITIES.items():
        res = root / "android/app/src/main/res" / f"mipmap-{dpi}"
        adaptive_background(size).save(res / "ic_launcher_background.png")
        adaptive_foreground(size).save(res / "ic_launcher_foreground.png")
        written.append(f"{res.relative_to(root)}/ic_launcher_background.png ({size})")
        written.append(f"{res.relative_to(root)}/ic_launcher_foreground.png ({size})")
    anydpi = root / "android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml"
    anydpi.parent.mkdir(parents=True, exist_ok=True)
    anydpi.write_text(ADAPTIVE_XML, encoding="utf-8")
    written.append(str(anydpi.relative_to(root)))

    # iOS：按现存文件实际尺寸逐个重绘（不解析 Contents.json，杜绝漂移）
    appicon = root / "ios/Runner/Assets.xcassets/AppIcon.appiconset"
    for path in sorted(appicon.glob("*.png")):
        size = Image.open(path).size
        assert size[0] == size[1], f"非方形 iOS 图标: {path} {size}"
        ios_icon(size[0]).save(path)
        written.append(f"{path.relative_to(root)} ({size[0]}x{size[1]})")

    print(f"共生成 {len(written)} 个文件：")
    for line in written:
        print(" ", line)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
