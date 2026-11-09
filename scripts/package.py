#!/usr/bin/env python3
"""把服务端与客户端产物打成一个可分发目录。

用法：
    python scripts/package.py                 # 生成 dist/PAVL-<版本>/
    python scripts/package.py --zip           # 同时压成 zip
    python scripts/package.py --out D:/x      # 换输出目录
    python scripts/package.py --macos --zip   # 生成 macOS 客户端包

产物布局（Windows）：

    PAVL-<版本>/
      server/pavl.exe              服务端，双击即用
      server/README.txt            首次运行说明
      client/pavl_client.exe       客户端
      client/*.dll, data/          客户端运行时
      README.txt                   总说明

产物布局（macOS）：

    PAVL-<版本>-macos/
      PAVL.app                     客户端，拖进「应用程序」即可
      README.txt                   安装与权限说明

服务端只有 Windows 版本，macOS 包里不带服务端。
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path


def _force_utf8_stdout() -> None:
    """Windows 控制台默认用 GBK，直接打印中文会变成乱码。

    与 `setup_media_kit_deps.py` 里的同名函数一致：切到 UTF-8，
    errors="replace" 保证不会因为某个符号编码失败而中断打包。
    """
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass  # 已被重定向到不支持 reconfigure 的对象，保持原样


_force_utf8_stdout()

ROOT = Path(__file__).resolve().parent.parent
SERVER_EXE = ROOT / "build" / "pavl.exe"
CLIENT_DIR = ROOT / "client" / "build" / "windows" / "x64" / "runner" / "Release"
MACOS_APP = (
    ROOT / "client" / "build" / "macos" / "Build" / "Products" / "Release" / "PAVL.app"
)
VERSION = "0.2.0"

SERVER_README = """\
PAVL 服务端
===========

第一次运行
----------
1. 双击 pavl.exe。程序会缩到通知区域（任务栏右下角的 ^ 里）。
2. 如果出现「Windows 安全中心」的防火墙提示，务必点「允许访问」。
   点「取消」会导致其他设备连不上，只能手动到防火墙设置里放行。
3. 第一次启动需要一个媒体根目录，可以二选一：

   - 双击后按提示选一个文件夹；
   - 或者用命令行指定：

       pavl.exe --root "D:\\Videos"

   之后会把根目录记进配置，再次双击就不需要参数了。

管理共享目录
------------
右键点通知区域里的图标，菜单里有：

    添加共享目录…    再挂一个目录进来，原有目录继续共享
    更换共享目录…    只保留新选的目录，旧目录立刻停止共享

选完目录立即生效，不需要重启服务端。目录下如果没有任何视频或音频，
浏览列表里会自动隐藏，免得混进 MathType、驱动包这类无关文件夹。
需要看到完整文件树时，把配置里的 hideEmptyDirs 改成 false。

查看地址与 PIN
--------------
右键点通知区域里的图标：

    PAVL · 123456
    地址  http://192.168.1.10:8765
    PIN   123456
    ─────────────
    复制 PIN
    在浏览器中打开
    打开数据目录
    添加共享目录…
    更换共享目录…
    重新生成 PIN（旧设备需重新配对）
    ─────────────
    退出

客户端配对时输入的就是这里显示的 6 位 PIN。

命令行选项
----------
    --root <路径>      追加媒体根目录，可重复
    --port <端口>      覆盖 HTTP 端口，默认 8765
    --name <名称>      覆盖局域网显示名
    --pin <PIN>        覆盖配对 PIN
    --reset-pin        重新生成 PIN
    --console          控制台模式，不缩到通知区域（调试用）
    --print-config     打印当前配置
    -h, --help         显示帮助

配置文件位置
------------
    %APPDATA%\\PAVL\\config.json    服务器配置
    %APPDATA%\\PAVL\\devices.json   已配对设备
    %APPDATA%\\PAVL\\progress.json  播放进度
    %APPDATA%\\PAVL\\meta.json      片库元数据
    %APPDATA%\\PAVL\\pavl.log       运行日志（托盘模式下）

卸载
----
没有安装过程，删掉整个文件夹即可。配置在 %APPDATA%\\PAVL，需要一起删。
"""

CLIENT_README = """\
PAVL 客户端
===========

1. 双击 pavl_client.exe。
2. 启动时会自动在局域网里搜索 PAVL 服务端，找到的会直接列出来。
   也可以自己在下面填地址与端口。
3. 第一次连接需要输入 PIN，就是服务端托盘菜单里显示的那 6 位数字。
   填好后点「连接」直接进入目录列表。
4. 配对一次即可，之后打开就自动进上次的服务器。

播放相关
--------
- 空格键播放/暂停，左右键 ±10 秒，上下键 ±5 音量，F 全屏，Esc 返回。
- 右上角齿轮进入设置，可以切换「跨设备同步进度」：
  - 关：只记本机的播放位置。
  - 开：跟随服务器上最近一次的播放位置（可能来自其他设备）。
- 底部可以调倍速 0.5x–2.0x、切换音轨、切换字幕。
  每部片选过的音轨与字幕会被记住，下次打开自动恢复。

放不出来怎么办
--------------
点开某部片后如果一直黑屏，界面上会给出原因与日志位置；
也可以点右上角齿轮，在「排查」里复制日志路径。
常见原因：显卡驱动或硬件解码初始化失败、服务端中途退出、
防火墙拦住了端口。

数据位置
--------
配对信息、播放日志与临时文件都放在本程序同级的 PAVL-data 文件夹里，
整个文件夹拷走就能带着配对状态与现场。删除该文件夹等于恢复出厂设置。

    PAVL-data\\client.json    连接信息
    PAVL-data\\client.log     播放日志（播放过才会生成）
"""

ROOT_README = """\
PAVL — Play All Videos in Lan
=============================

局域网内跨设备播放服务器上视频的自建方案。

    server/   Windows 服务端，双击常驻通知区域
    client/   Windows 客户端，自带 libmpv 解码

快速开始
--------
1. 在存放视频的电脑上运行 server\\pavl.exe，
   第一次按提示选一个媒体目录，或者用命令行指定：

       pavl.exe --root "D:\\Videos"

   以后想加目录或换目录，右键点通知区域里的图标即可，不用重启。

2. 防火墙提示点「允许访问」。
3. 在任意设备上运行 client\\pavl_client.exe。
4. 输入服务端托盘菜单里显示的 PIN。

说明文档见 server\\README.txt 与 client\\README.txt。

技术要点
--------
服务端只做三件事：扫文件系统建索引、用 HTTP Range 发文件、存取进度。
不解码、不转封装、不依赖 ffmpeg，所以只有 6MB 单文件、内存占用 25MB。
所有解码在客户端用 libmpv 完成，因此 MKV / HEVC / AV1 / ASS 字幕 / PGS 图形字幕
全部支持，不需要任何转码。

许可
----
客户端内含 libmpv，按 LGPLv2.1+ 分发（GPL 组件已关闭）。
客户端内含 MiSans 字体，按 Apache License 2.0 分发，
许可证与声明见 client\\data\\flutter_assets\\assets\\fonts\\ 下的
MiSans-LICENSE.txt 与 NOTICE.txt。
"""

MACOS_README = """\
PAVL macOS 客户端
=================

安装
----
把 PAVL.app 拖进「应用程序」文件夹，然后双击运行。

第一次启动时系统可能弹两个提示，都要允许：

1. 「PAVL 想要查找并连接到本地网络上的设备」
   —— 用于广播发现同一网络里的服务端，以及从服务端拉流。
   点「不允许」会连不上，之后需要到
   「系统设置 → 隐私与安全性 → 本地网络」里重新打开。

2. 「PAVL 是从互联网下载的应用，确定要打开吗」
   —— 点「打开」。这个包没有经过 Apple 公证，
   如果提示「已损坏」或「无法验证开发者」，在
   「系统设置 → 隐私与安全性」页面底部点「仍要打开」，
   或者在终端里执行：

       xattr -dr com.apple.quarantine /Applications/PAVL.app

使用
----
启动后会自动在局域网里搜索服务端，找到的直接列出来；
也可以手动填地址与端口。第一次连接需要输入服务端的 6 位 PIN。

键盘：空格播放/暂停，左右键 ±10 秒，上下键 ±5 音量，F 全屏，Esc 返回。

数据位置
--------
    ~/Library/Application Support/PAVL/client.json    连接信息
    ~/Library/Application Support/PAVL/client.log     播放日志

删除这个文件夹等于恢复出厂设置。设置页里的「打开日志目录」会直接定位到那里。

服务端
------
PAVL 服务端只提供 Windows 版本，需要在 Windows 或 Linux 机器上运行，
macOS 客户端通过局域网连接它。
"""


def _require(path: Path, what: str) -> None:
    if not path.exists():
        sys.exit(f"缺少{what}：{path}\n请先构建。")


def _zip_dir(out_root: Path, target: Path) -> Path:
    """把目录压成 zip，返回压缩包路径。"""
    archive = out_root / f"{target.name}.zip"
    if archive.exists():
        archive.unlink()
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as zf:
        for path in sorted(target.rglob("*")):
            if path.is_file():
                zf.write(path, path.relative_to(out_root))
    print(f"压缩包  : {archive}  ({archive.stat().st_size / 1024 / 1024:.1f} MB)")
    return archive


def _zip_app_bundle(out_root: Path, folder: Path, name: str) -> Path:
    """把装着 .app 的目录压成 zip。

    macOS 应用包里带符号链接与可执行权限，用 Python 的 zipfile 打包会丢掉
    这两样，解压出来的程序直接起不来。macOS 上必须用 ditto（苹果自带，
    专为整包拷贝设计）；其它系统上只能退化成普通 zip，仅用于查看包内容。
    """
    archive = out_root / f"{name}.zip"
    if archive.exists():
        archive.unlink()
    if sys.platform == "darwin" and shutil.which("ditto"):
        subprocess.run(
            [
                "ditto",
                "-c",
                "-k",
                "--sequesterRsrc",
                "--keepParent",
                str(folder),
                str(archive),
            ],
            check=True,
        )
    else:
        print("提示: 非 macOS 环境，改用普通 zip；产物仅供查看，不能直接运行。")
        with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as zf:
            for path in sorted(folder.rglob("*")):
                if path.is_symlink() or path.is_file():
                    zf.write(path, Path(folder.name) / path.relative_to(folder))
    print(f"压缩包  : {archive}  ({archive.stat().st_size / 1024 / 1024:.1f} MB)")
    return archive


def _report(target: Path) -> None:
    total = sum(f.stat().st_size for f in target.rglob("*") if f.is_file())
    print(f"输出目录: {target}")
    print(f"总大小  : {total / 1024 / 1024:.1f} MB")


def package_windows(out_root: Path, name: str) -> Path:
    _require(SERVER_EXE, "服务端 exe")
    _require(CLIENT_DIR / "pavl_client.exe", "客户端 exe")

    target = out_root / name
    if target.exists():
        shutil.rmtree(target)

    server_dir = target / "server"
    client_dir = target / "client"
    server_dir.mkdir(parents=True)
    client_dir.mkdir(parents=True)

    shutil.copy2(SERVER_EXE, server_dir / "pavl.exe")
    (server_dir / "README.txt").write_text(SERVER_README, encoding="utf-8")

    # 排除本机运行时产生的数据：PAVL-data 里有配对令牌与日志，绝不能进发布包。
    skip = {"PAVL-data"}
    for item in CLIENT_DIR.iterdir():
        if item.name in skip or item.name.endswith(".log"):
            continue
        dest = client_dir / item.name
        if item.is_dir():
            shutil.copytree(item, dest)
        else:
            shutil.copy2(item, dest)
    (client_dir / "README.txt").write_text(CLIENT_README, encoding="utf-8")

    (target / "README.txt").write_text(ROOT_README, encoding="utf-8")
    return target


def package_macos(out_root: Path, name: str) -> Path:
    _require(MACOS_APP, "macOS 应用包（在 macOS 上执行 flutter build macos --release）")

    target = out_root / name
    if target.exists():
        shutil.rmtree(target)
    target.mkdir(parents=True)

    # symlinks=True 必须带：Flutter.framework 内部是用符号链接组织的版本目录，
    # 解引用会把包撑大好几倍，还会破坏框架结构。
    shutil.copytree(MACOS_APP, target / MACOS_APP.name, symlinks=True)
    (target / "README.txt").write_text(MACOS_README, encoding="utf-8")
    return target


def main() -> int:
    parser = argparse.ArgumentParser(description="打包 PAVL 分发目录")
    parser.add_argument("--out", default=str(ROOT / "dist"), help="输出根目录")
    parser.add_argument("--zip", action="store_true", help="额外生成 zip")
    parser.add_argument(
        "--macos", action="store_true", help="打 macOS 客户端包（不带服务端）"
    )
    parser.add_argument("--name", default=None, help="目录名")
    args = parser.parse_args()

    out_root = Path(args.out)
    out_root.mkdir(parents=True, exist_ok=True)

    if args.macos:
        name = args.name or f"PAVL-{VERSION}-macos"
        target = package_macos(out_root, name)
        _report(target)
        if args.zip:
            _zip_app_bundle(out_root, target, name)
        return 0

    target = package_windows(out_root, args.name or f"PAVL-{VERSION}")
    _report(target)
    if args.zip:
        _zip_dir(out_root, target)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
