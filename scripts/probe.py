"""设置页 / 播放页的人工验收辅助脚本（仅开发期使用）。

按截图坐标点击窗口：截图是整窗物理像素，客户区原点落在截图的固定偏移处，
所以 `客户区 = 截图 - (偏移X, 偏移Y)`。偏移来自窗口的非客户区（边框与标题栏），
随系统和缩放比例变化，默认 12/52，可用 `PAVL_SHOT_OFFSET_X` /
`PAVL_SHOT_OFFSET_Y` 覆盖。

用法：
  python scripts/probe.py shot out.png
  python scripts/probe.py tap 140 190 [--wait 2.0]
  python scripts/probe.py key esc
"""

from __future__ import annotations

import ctypes
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import ui_probe as u  # noqa: E402  同目录工具，直接复用找窗口与截图

import win32con  # noqa: E402
import win32gui  # noqa: E402

# 截图坐标到客户区坐标的固定偏移（左边框宽、标题栏高）。
#
# 默认值来自一块 150% 缩放的 Windows 屏幕：边框 12px、标题栏 40px + 缩放 12px。
# 换机器或换缩放比例会变，用环境变量覆盖，不必改代码。
SHOT_OFFSET_X = int(os.environ.get("PAVL_SHOT_OFFSET_X", "12"))
SHOT_OFFSET_Y = int(os.environ.get("PAVL_SHOT_OFFSET_Y", "52"))


def foreground(hwnd: int) -> bool:
    """把窗口提到前台，返回是否成功。

    直接 SetForegroundWindow 在别的进程持有前台时会失败；AttachThreadInput
    把输入队列临时挂到前台线程上才稳。
    """
    fg = win32gui.GetForegroundWindow()
    if fg == hwnd:
        return True
    current = ctypes.windll.kernel32.GetCurrentThreadId()
    fg_thread = ctypes.windll.user32.GetWindowThreadProcessId(fg, None)
    attached = ctypes.windll.user32.AttachThreadInput(current, fg_thread, True)
    try:
        win32gui.ShowWindow(hwnd, win32con.SW_RESTORE)
        win32gui.BringWindowToTop(hwnd)
        win32gui.SetForegroundWindow(hwnd)
    except Exception:
        pass
    finally:
        if attached:
            ctypes.windll.user32.AttachThreadInput(current, fg_thread, False)
    time.sleep(0.4)
    return win32gui.GetForegroundWindow() == hwnd


def tap(hwnd: int, shot_x: int, shot_y: int, wait: float) -> None:
    origin_x, origin_y = u.client_origin(hwnd)
    x = origin_x + shot_x - SHOT_OFFSET_X
    y = origin_y + shot_y - SHOT_OFFSET_Y
    ctypes.windll.user32.SetCursorPos(x, y)
    time.sleep(0.25)
    u.click(x, y)
    time.sleep(wait)


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__)
        return 2
    command = argv[1]
    hwnd = u.find_window()
    if command == "shot":
        u.grab(hwnd, Path(argv[2]))
        return 0
    if command == "fg":
        print("foreground ok" if foreground(hwnd) else "foreground failed")
        return 0
    if command == "key":
        foreground(hwnd)
        name = argv[2]
        if name not in u.VK:
            print(f"未知按键: {name}")
            return 2
        u.key(u.VK[name])
        return 0
    if command == "type":
        foreground(hwnd)
        u.type_text(argv[2])
        return 0
    if command == "tap":
        wait = 2.0
        if "--wait" in argv:
            wait = float(argv[argv.index("--wait") + 1])
        foreground(hwnd)
        tap(hwnd, int(argv[2]), int(argv[3]), wait)
        out = argv[argv.index("--out") + 1] if "--out" in argv else None
        if out:
            u.grab(hwnd, Path(out))
        return 0
    print(f"未知命令: {command}")
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
