"""在 PAVL 窗口截图里按颜色找控件，输出中心点，供 ui_probe 点击。

主要用途是避免靠肉眼估坐标：截一张图，找出强调色按钮/蓝色高亮区域，
直接用它们的像素中心去点击。

用法：
    python scripts/ui_locate.py --out shot.png --color accent
    python scripts/ui_locate.py --match
"""

from __future__ import annotations

import argparse
import ctypes
import sys
from pathlib import Path

import win32con
import win32gui
from PIL import Image, ImageGrab

WINDOW_CLASS = "FLUTTER_RUNNER_WIN32_WINDOW"

try:
    ctypes.windll.shcore.SetProcessDpiAwareness(2)
except (AttributeError, OSError):
    ctypes.windll.user32.SetProcessDPIAware()

PALETTE = {
    # PAVL 主题色
    "accent": (0x4C, 0x8D, 0xFF),
    "success": (0x4C, 0xAF, 0x7D),
    "danger": (0xE0, 0x5B, 0x5B),
    "folder": (0xF5, 0xC5, 0x42),
}


def find_window() -> int:
    found: list[int] = []

    def cb(hwnd: int, _p: object) -> bool:
        if win32gui.GetClassName(hwnd) == WINDOW_CLASS:
            found.append(hwnd)
        return True

    win32gui.EnumWindows(cb, None)
    if not found:
        raise SystemExit("找不到 PAVL 窗口")
    return found[0]


def grab_window(hwnd: int) -> Image.Image:
    left, top, right, bottom = win32gui.GetWindowRect(hwnd)
    return ImageGrab.grab(bbox=(left, top, right, bottom), all_screens=True)


def clusters(img: Image.Image, rgb: tuple[int, int, int], tol: int = 18):
    """把颜色相近的像素聚成矩形块。"""
    w, h = img.size
    px = img.load()
    target = rgb
    hits: set[tuple[int, int]] = set()
    for y in range(h):
        for x in range(w):
            r, g, b = px[x, y][:3]
            if (
                abs(r - target[0]) <= tol
                and abs(g - target[1]) <= tol
                and abs(b - target[2]) <= tol
            ):
                hits.add((x, y))

    boxes: list[tuple[int, int, int, int, int]] = []
    seen: set[tuple[int, int]] = set()
    for start in hits:
        if start in seen:
            continue
        stack = [start]
        seen.add(start)
        minx = maxx = start[0]
        miny = maxy = start[1]
        count = 0
        while stack:
            cx, cy = stack.pop()
            count += 1
            minx = min(minx, cx)
            maxx = max(maxx, cx)
            miny = min(miny, cy)
            maxy = max(maxy, cy)
            for nx, ny in ((cx + 1, cy), (cx - 1, cy), (cx, cy + 1), (cx, cy - 1)):
                if (nx, ny) in hits and (nx, ny) not in seen:
                    seen.add((nx, ny))
                    stack.append((nx, ny))
        boxes.append((minx, miny, maxx, maxy, count))
    boxes.sort(key=lambda b: b[4], reverse=True)
    return boxes


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--color", default="accent")
    ap.add_argument("--tol", type=int, default=18)
    ap.add_argument("--min-pixels", type=int, default=120)
    ap.add_argument("--out", default="")
    ap.add_argument("--match", action="store_true")
    ns = ap.parse_args()

    hwnd = find_window()
    if ns.match:
        win32gui.SetForegroundWindow(hwnd)

    img = grab_window(hwnd)
    if ns.out:
        Path(ns.out).parent.mkdir(parents=True, exist_ok=True)
        img.save(ns.out)
        print(f"shot {img.size} -> {ns.out}")

    rgb = PALETTE.get(ns.color)
    if rgb is None:
        parts = ns.color.split(",")
        rgb = tuple(int(p) for p in parts)  # type: ignore[assignment]

    boxes = [b for b in clusters(img, rgb, ns.tol) if b[4] >= ns.min_pixels]
    print(f"color={rgb} clusters={len(boxes)} image={img.size}")
    for minx, miny, maxx, maxy, count in boxes[:20]:
        cx, cy = (minx + maxx) // 2, (miny + maxy) // 2
        print(
            f"  box x={minx}-{maxx} y={miny}-{maxy} "
            f"pixels={count} center=({cx},{cy})"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
