#!/usr/bin/env python3
"""把服务端与客户端产物打成一个可分发目录。

用法：
    python scripts/package.py                 # 生成 dist/PAVL-<版本>/
    python scripts/package.py --zip           # 同时压成 zip
    python scripts/package.py --out D:/x      # 换输出目录

产物布局：

    PAVL-0.1.0/
      server/pavl.exe              服务端，双击即用
      server/README.txt            首次运行说明
      client/pavl_client.exe       客户端
      client/*.dll, data/          客户端运行时
      README.txt                   总说明
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SERVER_EXE = ROOT / "build" / "pavl.exe"
CLIENT_DIR = ROOT / "client" / "build" / "windows" / "x64" / "runner" / "Release"
VERSION = "0.1.0"

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
2. 程序会自动在局域网里搜索 PAVL 服务端。
   - 搜不到就点「手动连接」，输入服务端显示的那个地址。
3. 第一次连接需要输入 PIN，就是服务端托盘菜单里显示的那 6 位数字。
4. 配对一次即可，之后会自动记住。

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
点开某部片后如果一直黑屏，点右上角齿轮，把日志路径复制出来，
那份 client.log 里记着播放器每一步的时间点与报错原因。
常见原因：显卡驱动或硬件解码初始化失败、服务端中途退出、
防火墙拦住了端口。

数据位置
--------
    %APPDATA%\\PAVL\\client.json    连接信息
    %APPDATA%\\PAVL\\client.log     播放日志（播放过才会生成）
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
"""


def _require(path: Path, what: str) -> None:
    if not path.exists():
        sys.exit(f"缺少{what}：{path}\n请先构建。")


def main() -> int:
    parser = argparse.ArgumentParser(description="打包 PAVL 分发目录")
    parser.add_argument("--out", default=str(ROOT / "dist"), help="输出根目录")
    parser.add_argument("--zip", action="store_true", help="额外生成 zip")
    parser.add_argument("--name", default=f"PAVL-{VERSION}", help="目录名")
    args = parser.parse_args()

    _require(SERVER_EXE, "服务端 exe")
    _require(CLIENT_DIR / "pavl_client.exe", "客户端 exe")

    out_root = Path(args.out)
    target = out_root / args.name
    if target.exists():
        shutil.rmtree(target)

    server_dir = target / "server"
    client_dir = target / "client"
    server_dir.mkdir(parents=True)
    client_dir.mkdir(parents=True)

    shutil.copy2(SERVER_EXE, server_dir / "pavl.exe")
    (server_dir / "README.txt").write_text(SERVER_README, encoding="utf-8")

    for item in CLIENT_DIR.iterdir():
        dest = client_dir / item.name
        if item.is_dir():
            shutil.copytree(item, dest)
        else:
            shutil.copy2(item, dest)
    (client_dir / "README.txt").write_text(CLIENT_README, encoding="utf-8")

    (target / "README.txt").write_text(ROOT_README, encoding="utf-8")

    total = sum(f.stat().st_size for f in target.rglob("*") if f.is_file())
    print(f"输出目录: {target}")
    print(f"总大小  : {total / 1024 / 1024:.1f} MB")

    if args.zip:
        archive = out_root / f"{args.name}.zip"
        if archive.exists():
            archive.unlink()
        with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as zf:
            for path in sorted(target.rglob("*")):
                if path.is_file():
                    zf.write(path, path.relative_to(out_root))
        size = archive.stat().st_size
        print(f"压缩包  : {archive}  ({size / 1024 / 1024:.1f} MB)")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
