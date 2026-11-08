"""PAVL 客户端联调辅助脚本：截图、点击、按键。

只在开发期使用，通过 Win32 API 操作 PAVL 主窗口。
用法：
    python scripts/ui_probe.py rect
    python scripts/ui_probe.py shot --out shot.png
    python scripts/ui_probe.py click 1200 60      # 客户端坐标（不含标题栏）
    python scripts/ui_probe.py key space
    python scripts/ui_probe.py type 135790
"""

from __future__ import annotations

import argparse
import ctypes
import ctypes.wintypes as wt
import sys
import time
from pathlib import Path

import win32con
import win32gui
from PIL import ImageGrab

WINDOW_CLASS = "FLUTTER_RUNNER_WIN32_WINDOW"

# 先声明 DPI 感知，否则 GetWindowRect 返回的是被系统缩放前的逻辑坐标，
# 而 ImageGrab 返回的是物理像素，两者对不上。
try:
    ctypes.windll.shcore.SetProcessDpiAwareness(2)  # PROCESS_PER_MONITOR_DPI_AWARE
except (AttributeError, OSError):
    ctypes.windll.user32.SetProcessDPIAware()

user32 = ctypes.WinDLL("user32", use_last_error=True)

MOUSEEVENTF_LEFTDOWN = 0x0002
MOUSEEVENTF_LEFTUP = 0x0004
KEYEVENTF_KEYUP = 0x0002
INPUT_MOUSE = 0
INPUT_KEYBOARD = 1

VK = {
    "space": 0x20,
    "esc": 0x1B,
    "left": 0x25,
    "up": 0x26,
    "right": 0x27,
    "down": 0x28,
    "enter": 0x0D,
    "tab": 0x09,
    "back": 0x08,
    "f": 0x46,
    "pageup": 0x21,
    "pagedown": 0x22,
}


class MOUSEINPUT(ctypes.Structure):
    _fields_ = [
        ("dx", wt.LONG),
        ("dy", wt.LONG),
        ("mouseData", wt.DWORD),
        ("dwFlags", wt.DWORD),
        ("time", wt.DWORD),
        ("dwExtraInfo", ctypes.c_void_p),
    ]


class KEYBDINPUT(ctypes.Structure):
    _fields_ = [
        ("wVk", wt.WORD),
        ("wScan", wt.WORD),
        ("dwFlags", wt.DWORD),
        ("time", wt.DWORD),
        ("dwExtraInfo", ctypes.c_void_p),
    ]


class INPUT(ctypes.Structure):
    class _U(ctypes.Union):
        _fields_ = [("mi", MOUSEINPUT), ("ki", KEYBDINPUT)]

    _anonymous_ = ("u",)
    _fields_ = [("type", wt.DWORD), ("u", _U)]


def find_window() -> int:
    found: list[int] = []

    def cb(hwnd: int, _param: object) -> bool:  # noqa: ANN401
        if win32gui.GetClassName(hwnd) == WINDOW_CLASS:
            found.append(hwnd)
        return True

    win32gui.EnumWindows(cb, None)
    if not found:
        raise SystemExit("找不到 PAVL 窗口，客户端是否已启动？")
    return found[0]


def client_origin(hwnd: int) -> tuple[int, int]:
    left, top, _right, _bottom = win32gui.GetWindowRect(hwnd)
    client = win32gui.GetClientRect(hwnd)
    # 客户区左上角在屏幕坐标系中的位置
    cx, cy = win32gui.ClientToScreen(hwnd, (0, 0))
    del left, top, client
    return cx, cy


def window_rect(hwnd: int) -> tuple[int, int, int, int]:
    return win32gui.GetWindowRect(hwnd)


def focus(hwnd: int) -> None:
    if win32gui.IsIconic(hwnd):
        win32gui.ShowWindow(hwnd, win32con.SW_RESTORE)
    win32gui.SetForegroundWindow(hwnd)
    time.sleep(0.15)


def _send(inp: INPUT) -> None:
    user32.SendInput(1, ctypes.byref(inp), ctypes.sizeof(INPUT))


def click(x: int, y: int) -> None:
    for flag in (MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP):
        _send(INPUT(type=INPUT_MOUSE, mi=MOUSEINPUT(0, 0, 0, flag, 0, None)))
        time.sleep(0.03)


def key(vk: int, repeat: int = 1) -> None:
    for _ in range(repeat):
        for flags in (0, KEYEVENTF_KEYUP):
            _send(INPUT(type=INPUT_KEYBOARD, ki=KEYBDINPUT(vk, 0, flags, 0, None)))
            time.sleep(0.03)


def type_text(text: str) -> None:
    for ch in text:
        vk = user32.VkKeyScanW(ord(ch)) & 0xFF
        key(vk)
        time.sleep(0.05)


def grab(hwnd: int, out: Path) -> None:
    left, top, right, bottom = window_rect(hwnd)
    img = ImageGrab.grab(bbox=(left, top, right, bottom), all_screens=True)
    out.parent.mkdir(parents=True, exist_ok=True)
    img.save(out)
    print(f"saved {out} {img.size} rect={(left, top, right, bottom)}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("action", choices=["shot", "click", "key", "type", "rect", "focus"])
    ap.add_argument("args", nargs="*")
    ap.add_argument("--out", default="shot.png")
    ap.add_argument(
        "--screen",
        action="store_true",
        help="click 参数按窗口内像素坐标解释（默认按客户区坐标）",
    )
    ns = ap.parse_args()

    hwnd = find_window()
    if ns.action == "rect":
        print("window:", window_rect(hwnd), "client:", client_origin(hwnd))
        return 0
    if ns.action == "focus":
        focus(hwnd)
        print("focused")
        return 0

    focus(hwnd)
    if ns.action == "shot":
        grab(hwnd, Path(ns.out))
    elif ns.action == "click":
        x, y = int(ns.args[0]), int(ns.args[1])
        if ns.screen:
            # 直接给屏幕坐标（截图里看到的像素位置 + 窗口矩形左上角）
            left, top, _r, _b = window_rect(hwnd)
            sx, sy = left + x, top + y
        else:
            ox, oy = client_origin(hwnd)
            sx, sy = ox + x, oy + y
        user32.SetCursorPos(sx, sy)
        time.sleep(0.1)
        click(x, y)
        time.sleep(0.6)
        grab(hwnd, Path(ns.out))
    elif ns.action == "key":
        name = ns.args[0].lower()
        vk = VK.get(name)
        if vk is None and len(name) == 1:
            vk = user32.VkKeyScanW(ord(name)) & 0xFF
        if vk is None:
            raise SystemExit(f"未知键名: {name}")
        key(vk, int(ns.args[1]) if len(ns.args) > 1 else 1)
        time.sleep(0.5)
        grab(hwnd, Path(ns.out))
    elif ns.action == "type":
        type_text(ns.args[0])
        time.sleep(0.5)
        grab(hwnd, Path(ns.out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
