#!/usr/bin/env python3
"""给 Windows 可执行文件嵌入应用图标（PE 资源）。

用法：
    python scripts/embed_icon.py                  # 处理 build/pavl.exe，缺图标就补
    python scripts/embed_icon.py --check          # 只检查，缺图标时返回码 1
    python scripts/embed_icon.py <exe> --ico <ico> --check

为什么需要这个脚本：服务端是 `dart compile exe` 的产物，Dart 编译器不接受
图标参数，编出来的 exe 里一条 RT_ICON 都没有，资源管理器、任务栏、文件属性
里显示的是系统默认的空白程序图标。客户端走 Flutter 的 Runner.rc，资源里本来
就有 IDI_APP_ICON，所以一直是对的。托盘图标是另一回事：它由
`server/lib/tray_icon.dart` 在运行时把 base64 的 ico 解码成 HICON，与 exe 资源
无关，因此表现为「托盘正常、文件图标空白」。

做法：用 pywin32 的资源更新 API 往 exe 里写 RT_ICON（每档一条）和
RT_GROUP_ICON（一条分组）。这是 Windows 官方支持的原地更新方式，原有资源
（包括 Dart 编译出的 RT_MANIFEST）原样保留，写失败会整批回滚，不会留下半个
exe。可以反复执行：已经带图标的 exe 直接跳过，所以打包脚本每次都能安全调用。
"""

from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

try:
    import win32api
    import win32con
except ImportError:  # pragma: no cover - 只在没装 pywin32 的机器上发生
    win32api = None
    win32con = None


def _force_utf8_stdout() -> None:
    """Windows 控制台默认用 GBK，直接打印中文会变成乱码。

    与 `package.py` / `make_branding.py` 里的同名函数一致：切到 UTF-8，
    errors="replace" 保证不会因为某个符号编码失败而中断。
    """
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass  # 已被重定向到不支持 reconfigure 的对象，保持原样


_force_utf8_stdout()

ROOT = Path(__file__).resolve().parent.parent
SERVER_EXE = ROOT / "build" / "pavl.exe"
APP_ICON = ROOT / "client" / "windows" / "runner" / "resources" / "app_icon.ico"

# 资源语言：0x0409 是微软推荐的落地语言，资源管理器和系统外壳都认它。
_LANG = 0x0409
_GROUP_ID = 1


def _require_pywin32() -> None:
    if win32api is None:
        raise SystemExit(
            "缺少 pywin32，无法写入 PE 资源。安装：\n"
            "    pip install pywin32 -i https://mirrors.aliyun.com/pypi/simple/"
        )


def read_ico_frames(data: bytes) -> list[dict]:
    """按 ICO 目录拆出每一档图像，供 RT_ICON 各写一条。"""
    if len(data) < 6:
        raise SystemExit("ico 文件太短，不是合法的图标文件")
    reserved, kind, count = struct.unpack_from("<HHH", data, 0)
    if reserved != 0 or kind != 1:
        raise SystemExit("不是合法的 ico 文件（头部标识不对）")
    if count == 0:
        raise SystemExit("ico 里没有任何图像档位")
    frames = []
    for index in range(count):
        width, height, colors, _, planes, bpp, size, offset = struct.unpack_from(
            "<BBBBHHII", data, 6 + index * 16
        )
        if offset + size > len(data):
            raise SystemExit(f"ico 第 {index} 档数据越界，文件可能已损坏")
        frames.append(
            {
                # ICO 目录里 0 表示 256，写回分组结构时还要再换算回 0。
                "width": width or 256,
                "height": height or 256,
                "colors": colors,
                "planes": planes or 1,
                "bpp": bpp,
                "size": size,
                "blob": data[offset : offset + size],
            }
        )
    return frames


def _icon_names(exe: Path) -> list:
    """读出 exe 里所有 RT_GROUP_ICON 的名字；没有该类型时返回空列表。"""
    _require_pywin32()
    module = win32api.LoadLibraryEx(
        str(exe), 0, win32con.LOAD_LIBRARY_AS_DATAFILE
    )
    try:
        return list(win32api.EnumResourceNames(module, win32con.RT_GROUP_ICON))
    except Exception:
        # pywin32 在资源类型不存在时抛 pywintypes.error（代码 1813）。
        return []
    finally:
        win32api.FreeLibrary(module)


def has_icon(exe: Path) -> bool:
    """exe 里有没有分组图标资源。任务栏与资源管理器读的就是这个。"""
    return bool(_icon_names(exe))


def embed(exe: Path, ico: Path) -> int:
    """把 ico 的各档写进 exe，返回写入的档数。已带图标时不重复写。"""
    _require_pywin32()
    frames = read_ico_frames(ico.read_bytes())

    handle = win32api.BeginUpdateResource(str(exe), False)
    try:
        for index, frame in enumerate(frames, start=1):
            win32api.UpdateResource(
                handle, win32con.RT_ICON, index, frame["blob"], _LANG
            )

        # RT_GROUP_ICON 是「目录」：逐档描述尺寸与对应 RT_ICON 的编号。
        # 结构与 ico 文件头里的 16 字节目录项一致，只是去掉了数据偏移/长度。
        group = struct.pack("<HHH", 0, 1, len(frames))
        for index, frame in enumerate(frames, start=1):
            group += struct.pack(
                "<BBBBHHIH",
                frame["width"] % 256,  # 256 在目录里写作 0
                frame["height"] % 256,
                frame["colors"],
                0,  # 保留字节
                frame["planes"],
                frame["bpp"],
                frame["size"],
                index,
            )
        win32api.UpdateResource(handle, win32con.RT_GROUP_ICON, _GROUP_ID, group, _LANG)
    except Exception:
        # discard=True：撤销这次的全部写入，不让 exe 停在「只有一半图标」的状态。
        win32api.EndUpdateResource(handle, True)
        raise
    win32api.EndUpdateResource(handle, False)
    return len(frames)


def ensure_icon(exe: Path, ico: Path | None = None) -> bool:
    """确保 exe 带分组图标，返回本次是否真的写过。"""
    if not exe.exists():
        raise SystemExit(f"找不到可执行文件：{exe}")
    ico = ico or APP_ICON
    if not ico.exists():
        raise SystemExit(f"找不到图标文件：{ico}，先运行 scripts/make_branding.py")
    if has_icon(exe):
        return False
    embed(exe, ico)
    if not has_icon(exe):
        raise SystemExit(f"写入后仍未读到图标资源：{exe}")
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description="给 exe 嵌入 PAVL 图标")
    parser.add_argument("exe", nargs="?", default=str(SERVER_EXE))
    parser.add_argument("--ico", default=str(APP_ICON))
    parser.add_argument("--check", action="store_true", help="只检查，不做修改")
    args = parser.parse_args()

    exe = Path(args.exe)
    ico = Path(args.ico)
    if args.check:
        if not exe.exists():
            print(f"缺少可执行文件：{exe}")
            return 1
        ok = has_icon(exe)
        print(f"{exe.name}: {'图标已就位' if ok else '没有图标资源'}")
        return 0 if ok else 1

    wrote = ensure_icon(exe, ico)
    count = len(_icon_names(exe))
    state = f"补写 {count} 档图标" if wrote else "已有图标，跳过"
    print(f"{exe.name}: {state}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
