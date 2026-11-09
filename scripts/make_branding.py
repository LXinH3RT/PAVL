#!/usr/bin/env python3
"""从品牌主图生成各平台需要的图标与界面资源。

主图是 `docs/images/logo.png`：蓝色圆角方块 + 白色播放三角 + PAVL 字标，
1899×1899、带透明圆角、颜色 #0070C0。它只有一个尺寸，而程序需要的是
一组按用途剪裁的资源，且小尺寸下整幅字标会糊成一团，所以由本脚本派生：

    client/assets/branding/logo_mark.png        界面用品牌标记（仅三角，512）
    client/windows/runner/resources/app_icon.ico Windows 应用与窗口图标（7 档）
    client/macos/Runner/Assets.xcassets/AppIcon.appiconset/*.png
                                                macOS 应用图标（16~1024，10 档）
    server/lib/tray_icon.dart                   托盘图标（内嵌 base64 的 ico）

图标分档策略：48px 及以上用完整字标，32px 及以下只用三角标记——同样尺寸
里再塞 4 个字母会失去可辨识度，这是图标设计的通行做法。托盘图标跟随系统
DPI，取 16/20/24/32/40/48/64 七档，一律用三角标记。

用法：
    python scripts/make_branding.py            # 重新生成全部资源
    python scripts/make_branding.py --check    # 只校验现有资源是否为最新
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import io
import struct
import sys
from pathlib import Path

from PIL import Image, ImageDraw


def _force_utf8_stdout() -> None:
    """Windows 控制台默认用 GBK，直接打印中文会变成乱码。

    与 `setup_media_kit_deps.py` 里的同名函数一致：切到 UTF-8，
    errors="replace" 保证不会因为某个符号编码失败而中断生成。
    """
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass  # 已被重定向到不支持 reconfigure 的对象，保持原样


_force_utf8_stdout()

ROOT = Path(__file__).resolve().parent.parent
MASTER = ROOT / "docs" / "images" / "logo.png"
MARK_PNG = ROOT / "client" / "assets" / "branding" / "logo_mark.png"
APP_ICON = ROOT / "client" / "windows" / "runner" / "resources" / "app_icon.ico"
TRAY_DART = ROOT / "server" / "lib" / "tray_icon.dart"

# 主图实测参数：圆角半径 320/1899，三角包围盒 x 546..1503、y 237..1326。
BLUE = (0, 112, 192, 255)
WHITE = (255, 255, 255, 255)
RADIUS_RATIO = 320 / 1899
TRIANGLE_RATIO = (957 / 1089)  # 宽 / 高

APP_SIZES = (16, 24, 32, 48, 64, 128, 256)
TRAY_SIZES = (16, 20, 24, 32, 40, 48, 64)
MARK_ONLY_MAX = 32  # 该尺寸及以下只用三角标记

# macOS 应用图标：Assets.xcassets 里按点阵尺寸各存一份，文件名沿用
# flutter create 生成的 app_icon_<px>.png，Contents.json 不必改。
MACOS_APPICON_DIR = (
    ROOT / "client" / "macos" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
)
MACOS_SIZES = (16, 32, 64, 128, 256, 512, 1024)

# macOS 上纯标记的阈值比 Windows 更高：内容按 824/1024 收缩后，64px 里的
# 字标只剩不到 10px 高，挤在一起反而比单一个三角更糊。128 起再带字标。
MACOS_MARK_ONLY_MAX = 64

# Apple 的图标规范要求内容占 1024 画布的 824×824，四周留透明边距；直接铺满
# 会和 Dock 里其它应用视觉大小不一致（显得偏大）。
MACOS_CONTENT_RATIO = 824 / 1024

SS = 8  # 超采样倍数，先画大图再 LANCZOS 缩小，边缘才不会锯齿


def _draw_mark(size: int) -> Image.Image:
    """画只含三角标记的圆角方块。三角按主图比例放大后居中。"""
    hi = size * SS
    canvas = Image.new("RGBA", (hi, hi), (0, 0, 0, 0))
    draw = ImageDraw.Draw(canvas)
    radius = round(hi * RADIUS_RATIO)
    draw.rounded_rectangle((0, 0, hi - 1, hi - 1), radius=radius, fill=BLUE)

    # 三角包围盒按主图比例放大；主图里三角中心比画布中心偏右 3.9%，
    # 这里沿用同样的偏移量，否则视觉重心落在左边（三角的视觉重心在底边起
    # 三分之一处，按包围盒居中会显得左重）。
    h = hi * 0.60
    w = h * TRIANGLE_RATIO
    cx = hi * 0.538
    cy = hi * 0.50
    left = cx - w / 2
    top = cy - h / 2
    draw.polygon(
        [(left, top), (left, top + h), (left + w, cy)],
        fill=WHITE,
    )
    return canvas.resize((size, size), Image.LANCZOS)


def _full_logo(size: int) -> Image.Image:
    return _load_master().resize((size, size), Image.LANCZOS)


def _mark_png_bytes(size: int) -> bytes:
    buf = io.BytesIO()
    _draw_mark(size).save(buf, format="PNG", optimize=True)
    return buf.getvalue()


def _macos_icon(size: int) -> Image.Image:
    """macOS 应用图标：内容按 824/1024 收缩后居中，四周留透明边距。

    macOS 不像 Windows 那样要求图标铺满画布——Dock 与 Finder 不做裁切，
    内容顶满会显得比系统应用明显偏大。圆角沿用主图自带的样式（这里不打
    蒙版，也不用 Apple 的连续曲率遮罩：自签名分发不经 App Store 审核，
    与主图保持同一形状更一致）。

    小尺寸沿用 ico 的策略，只用三角标记——16/32 像素下字标会糊成一团。
    """
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    inner = max(1, round(size * MACOS_CONTENT_RATIO))
    base = _draw_mark(inner) if size <= MACOS_MARK_ONLY_MAX else _full_logo(inner)
    offset = (size - inner) // 2
    canvas.paste(base, (offset, offset), base)
    return canvas


def _macos_png_bytes(size: int) -> bytes:
    buf = io.BytesIO()
    _macos_icon(size).save(buf, format="PNG", optimize=True)
    return buf.getvalue()


_master_cache: Image.Image | None = None


def _load_master() -> Image.Image:
    global _master_cache
    if _master_cache is None:
        im = Image.open(MASTER)
        if im.mode != "RGBA":
            im = im.convert("RGBA")
        if im.size[0] != im.size[1]:
            raise SystemExit(f"主图必须是正方形，当前 {im.size}")
        _master_cache = im
    return _master_cache


PNG_MIN_SIZE = 48  # 该尺寸及以上用 PNG 内嵌，显著减小 ico 体积


def _png_entry(image: Image.Image) -> bytes:
    buf = io.BytesIO()
    image.save(buf, format="PNG", optimize=True)
    return buf.getvalue()


def _dib_entry(image: Image.Image) -> bytes:
    """把一帧转成 ico 内的 DIB：BITMAPINFOHEADER + BGRA 位图 + AND 掩码。

    不使用 PIL 的 ICO 写入器，因为它会忽略传入的多帧、一律从最后一帧重采样，
    导致「小尺寸只用三角标记」的策略失效。小尺寸用 DIB 而非 PNG：PNG 条目在
    32px 以下遇到部分 shell 扩展会画不出来，DIB 是所有版本都认的形态。
    """
    size = image.width
    header = struct.pack(
        "<IiiHHIIiiII",
        40,          # biSize
        size,        # biWidth
        size * 2,    # biHeight：XOR 位图与 AND 掩码各占一半
        1,           # biPlanes
        32,          # biBitCount
        0,           # biCompression = BI_RGB
        0,           # biSizeImage
        0, 0,        # 省略分辨率
        0,           # biClrUsed
        0,           # biClrImportant
    )
    pixels = image.convert("RGBA").tobytes()
    rows = []
    for y in range(size - 1, -1, -1):  # DIB 自底向上
        row = bytearray()
        for x in range(size):
            i = (y * size + x) * 4
            r, g, b, a = pixels[i : i + 4]
            row += bytes((b, g, r, a))  # BGRA
        rows.append(bytes(row))
    xor = b"".join(rows)
    mask_stride = ((size + 31) // 32) * 4
    mask = b"\x00" * (mask_stride * size)  # 有 alpha 通道，掩码全 0
    return header + xor + mask


def build_ico(sizes: tuple[int, ...], mark_only_max: int) -> bytes:
    """按尺寸选择整幅字标或纯标记，打包成 ico。"""
    payloads: list[tuple[int, bytes]] = []
    for size in sizes:
        image = _draw_mark(size) if size <= mark_only_max else _full_logo(size)
        blob = _png_entry(image) if size >= PNG_MIN_SIZE else _dib_entry(image)
        payloads.append((size, blob))

    out = bytearray(struct.pack("<HHH", 0, 1, len(payloads)))
    offset = 6 + 16 * len(payloads)
    for size, data in payloads:
        out += struct.pack(
            "<BBBBHHII",
            0 if size >= 256 else size,  # 0 表示 256
            0 if size >= 256 else size,
            0,            # 调色板颜色数
            0,            # 保留
            1,            # 色彩平面
            32,           # 位深
            len(data),
            offset,
        )
        offset += len(data)
    for _size, data in payloads:
        out += data
    return bytes(out)


def ico_entry_count(data: bytes) -> int:
    return struct.unpack("<HHH", data[:6])[2]


def main() -> int:
    ap = argparse.ArgumentParser(description="生成 PAVL 品牌图标资源")
    ap.add_argument("--check", action="store_true", help="只校验，不写文件")
    ns = ap.parse_args()

    if not MASTER.exists():
        print(f"缺少主图：{MASTER}")
        return 1

    app_ico = build_ico(APP_SIZES, MARK_ONLY_MAX)
    tray_ico = build_ico(TRAY_SIZES, 64)  # 托盘全部用标记
    mark_png = _mark_png_bytes(512)

    tray_dart = (
        "// 由 scripts/make_branding.py 生成，请勿手工修改。\n"
        "//\n"
        "// 托盘图标以 base64 内嵌：服务端是单文件 exe，图标必须随程序走，\n"
        "// 不能依赖旁边放一个 .ico。运行时解码后落到数据目录，再用\n"
        "// LoadImageW(..., LR_LOADFROMFILE) 加载。\n"
        "library;\n"
        "\n"
        "/// 托盘图标的 ico 字节（16/20/24/32/40/48/64 七档，三角标记）。\n"
        "const String trayIconIcoBase64 =\n"
    )
    encoded = base64.b64encode(tray_ico).decode("ascii")
    for i in range(0, len(encoded), 96):
        tray_dart += f"    '{encoded[i : i + 96]}'\n"
    tray_dart += "    ;\n"

    outputs = [
        (MARK_PNG, mark_png),
        (APP_ICON, app_ico),
        (TRAY_DART, tray_dart.encode("utf-8")),
    ]
    # macOS 的 AppIcon.appiconset 每个点阵尺寸各一个文件；文件名沿用
    # flutter create 生成的 app_icon_<px>.png，Contents.json 无需改动。
    for px in MACOS_SIZES:
        outputs.append((MACOS_APPICON_DIR / f"app_icon_{px}.png", _macos_png_bytes(px)))

    stale = []
    for path, data in outputs:
        current = path.read_bytes() if path.exists() else None
        if current != data:
            stale.append(path)
        if ns.check:
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    for path, data in outputs:
        print(f"{path.relative_to(ROOT)}  {len(data)} 字节  "
              f"sha256={hashlib.sha256(data).hexdigest()[:12]}")
    print(f"app_icon.ico 条目数 {ico_entry_count(app_ico)}，"
          f"托盘 ico 条目数 {ico_entry_count(tray_ico)}")

    if ns.check:
        if stale:
            for path in stale:
                print(f"已过期：{path.relative_to(ROOT)}")
            return 1
        print("全部资源均为最新")
    return 0


if __name__ == "__main__":
    sys.exit(main())
