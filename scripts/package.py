#!/usr/bin/env python3
"""把服务端与客户端分别打成可分发的包。

用法：
    python scripts/package.py --server --zip       # 服务端（Windows）
    python scripts/package.py --portable --zip     # Windows 客户端便携版
    python scripts/package.py --macos --zip        # macOS 客户端
    python scripts/package.py --all --zip          # 当前平台上能打的全打

命名规则（发布包与目录同名）：

    软件名_平台名_客户端/服务端_便携版_版本号

    - 「便携版」只出现在便携形态上，安装版省略这一段。
      目前 Windows 的服务端与客户端都是便携形态（解压即用、删目录即卸载），
      所以两者都带 portable；macOS 是一个拖进「应用程序」的 .app，不带。
    - 平台名取 windows / macos / linux。

    PAVL_windows_server_portable_<版本>
    PAVL_windows_client_portable_<版本>
    PAVL_macos_client_<版本>

产物布局（服务端）：

    PAVL_windows_server_portable_<版本>/
      pavl.exe          服务端，双击即用
      README.txt        首次运行说明
      LICENSE.txt       许可证与第三方组件声明

产物布局（Windows 客户端便携版）：

    PAVL_windows_client_portable_<版本>/
      pavl_client.exe   客户端
      *.dll, data/      客户端运行时
      README.txt        使用说明
      LICENSE.txt       许可证与第三方组件声明

产物布局（macOS 客户端）：

    PAVL_macos_client_<版本>/
      PAVL.app          客户端，拖进「应用程序」即可
      README.txt        安装与权限说明
      LICENSE.txt       许可证与第三方组件声明

服务端与客户端分开打包：只架服务器的人不必下一份 40 多 MB 的客户端，
只装客户端的人也不必看见服务端的 exe。
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

# 本机用的是 Python 的嵌入式发行版，它带 python313._pth，不会像常规安装那样
# 把脚本所在目录塞进 sys.path，直接 import 同目录的模块会报 ModuleNotFoundError。
# 这里显式补一次，两种发行版下行为就一致了。
sys.path.insert(0, str(Path(__file__).resolve().parent))

import embed_icon  # noqa: E402  （必须在 sys.path 调整之后）


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
VERSION = "0.2.4"

# 命名规则见模块说明。软件名固定，其它三段由平台与角色拼出来。
APP_NAME = "PAVL"


def server_package_name(version: str = VERSION) -> str:
    # Windows 服务端也是便携形态：一个 exe，没有安装程序，删目录即卸载。
    return f"{APP_NAME}_windows_server_portable_{version}"


def portable_package_name(version: str = VERSION) -> str:
    return f"{APP_NAME}_windows_client_portable_{version}"


def macos_package_name(version: str = VERSION) -> str:
    return f"{APP_NAME}_macos_client_{version}"


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
    停止共享：<目录>  只停掉这一个，其余目录照旧

选完目录立即生效，不需要重启服务端。目录下如果没有任何视频或音频，
浏览列表里会自动隐藏，免得混进 MathType、驱动包这类无关文件夹。
需要看到完整文件树时，把配置里的 hideEmptyDirs 改成 false。

多个共享目录的显示顺序
----------------------
按名称排，规则与客户端列表一致：数字按数值、字母不分大小写、
汉字按拼音。想固定顺序就在目录名前面加序号，比如「01 电影」「02 剧集」。
根目录一律显示，即使里面暂时还没有视频，会显示成「0 项」。

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
    共享目录
    停止共享：电影
    停止共享：剧集
    添加共享目录…
    更换共享目录…
    重新生成 PIN（旧设备需重新配对）
    ─────────────
    版本 v0.2.4 · 检查更新
    ─────────────
    退出

客户端配对时输入的就是这里显示的 6 位 PIN。

点「版本 v… · 检查更新」会去 GitHub 取最新的发布并和当前版本比较。有新版本
时确认一下就会下载、解压并替换自己，然后自动重启；地址、PIN、已配对设备与
播放进度都留在原处，客户端不用重新配对。替换过程中服务会短暂不可用，正在
播放的客户端会断开，重连即可。

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

数据位置
--------
程序会先看自己所在的文件夹能不能写：

- 能写（解压到桌面、D 盘等普通位置）：数据放在程序同级的 PAVL-data，
  整个文件夹拷走就能连配置、设备、进度一起搬家。

      PAVL-data\\config.json    服务器配置
      PAVL-data\\devices.json   已配对设备
      PAVL-data\\progress.json  播放进度
      PAVL-data\\prefs.json     各设备的音轨字幕选择
      PAVL-data\\meta.json      片库元数据
      PAVL-data\\scrape.json    刮削结果（有的话）
      PAVL-data\\posters\\      刮削下载的海报（有的话）
      PAVL-data\\pavl.log       运行日志（托盘模式下）

- 不能写（放进 Program Files 这类只读位置）：改用用户配置目录
  %APPDATA%\\PAVL，文件名同上。

升级或搬家时把整个 PAVL-data 目录一起带走即可。第一次以便携形态启动时，
如果 %APPDATA%\\PAVL 里还有旧数据，会自动复制一份过来，旧文件保留。

卸载
----
没有安装过程，删掉整个文件夹即可。便携形态的数据就在程序目录旁边，
一起删掉就是彻底恢复；如果程序目录不可写、数据落在 %APPDATA%\\PAVL，
那个文件夹要单独删。

客户端
------
本包只有服务端。播放需要另外下载对应平台的客户端包，
在同一个发布页面里。

刮削
----
服务端可以按片名替客户端去找海报、年份、评分与简介，默认关闭。
在客户端的设置 - 播放 - 「片库」里打开即可，服务端不需要额外配置，
也不用登录任何站点。

来源有豆瓣、IMDb、B 站三个，可各自勾选。抓到的记录写在
PAVL-data\\scrape.json，海报下到 PAVL-data\\posters\\，跟着
PAVL-data 一起搬家。自动匹配只在片名高度吻合时才采纳，同名的
不同年份版本会留给人手选。

原本还计划接 1905 电影网，实测整站对非浏览器请求返回 403，没有做。

许可
----
程序本体 MIT，完整条款见同目录的 LICENSE.txt。
程序内含 lpinyin（BSD 2-Clause），用来把汉字转成拼音做排序；字典编进
exe 里，运行时不加载外部文件，但再分发二进制时仍需随附其版权声明。
LICENSE.txt 里还有 Dart 运行时的条款。
"""

CLIENT_README = """\
PAVL 客户端（Windows 便携版）
=============================

便携版：不用安装，解压后双击 pavl_client.exe 就能用。
配对信息、日志与临时文件都放在程序同级的 PAVL-data 文件夹里，
整个文件夹拷走就能带着配对状态与现场。

1. 双击 pavl_client.exe。
2. 启动时会自动在局域网里搜索 PAVL 服务端，找到的会直接列出来。
   也可以自己在下面填地址与端口。
3. 第一次连接需要输入 PIN，就是服务端托盘菜单里显示的那 6 位数字。
   填好后点「连接」直接进入目录列表。
4. 配对一次即可，之后打开就自动进上次的服务器。

三个页面
--------
- 浏览：按共享目录逐层展开，知道片子在哪个文件夹时最快。
- 片库：按文件夹收拢，文件夹行上写最多两层目录名和集数，点开展开各集；
  只放了一个视频的文件夹直接当视频显示。按名称排、可以搜关键词、
  往下滚自动加载更多，顶部是最近播放。记不住放在哪时用这个。
- 播放：点任意一部片进入。

刮削
----
服务端可以按片名去豆瓣、IMDb、B 站找海报、年份、评分与简介，抓到之后
片库里的文件夹行会直接显示海报。默认关闭，需要时打开。

设置页的「播放」里，下半段有一段「片库」：
- 显示刮削信息：只是这台设备的显示开关，关掉后不显示海报与评分，
  服务端已经抓到的记录不受影响。
- 服务端刮削：真正的总开关。关掉之后服务端不再联网，已有记录仍保留。
- 自动匹配：新片进库时，只有片名高度吻合才自动采纳，拿不准的留着手选。
- 信息来源：豆瓣、IMDb、B 站三个可各自勾选。
- 下面两个按钮：「刮削整个片库」在后台跑，不影响浏览；
  「清除刮削记录」会删掉服务端保存的全部刮削信息与海报。

检查更新
--------
设置 - 关于 里的「客户端版本」那一行可以点。点了会去 GitHub 取最新发布：

- 已经是最新版本：直接说一句，不动任何文件。
- 有新版本：列出更新包大小，确认后下载。下载是多路并行的，断了可以从
  已下载的部分接着来。
- 下载完成后点「安装并重启」，程序就地替换自己再重启。配对状态、播放
  进度、片库索引都留在原处，不需要重新配对或重新刮削。

也可以点「打开发布页」自己下载，两者结果一样。

播放相关
--------
- 空格键播放/暂停，左右键 ±10 秒，上下键 ±5 音量，F 全屏，Esc 返回。
- 右上角齿轮进入设置页，左侧分两类：播放、关于。
  「播放」里有两个开关：
  - 跨设备同步进度
    - 关：只记本机的播放位置。
    - 开：跟随服务器上最近一次的播放位置（可能来自其他设备）。
  - 音轨与字幕记忆
    - 开：下次打开同一部片自动恢复上次选的轨。
    - 关：不再记录，也不会自动切换，已经记下的仍保留。
  开关下面是「配置存储位置」，说明这些选择跟着谁走。
- 底部可以调倍速 0.5x–2.0x、切换音轨、切换字幕。
  每部片选过的音轨与字幕会被记住，下次打开自动恢复。
- 播放期间会阻止屏幕自动熄灭，暂停或退出时释放。
- 重新打开看过的片会先问一句：从上次的位置继续，还是从头开始。
  已经看到 90% 以上的算看完，不再问，也不进最近播放。

列表顺序
--------
一律由服务端决定：文件夹在前，数字按数值（第2集在第10集之前），
字母不分大小写，汉字按拼音。客户端不再排一遍，多台设备看到的顺序一致。

放不出来怎么办
--------------
点开某部片后如果一直黑屏，界面上会给出原因与日志位置；
也可以点右上角齿轮，在设置的「关于」里复制日志路径。
常见原因：显卡驱动或硬件解码初始化失败、服务端中途退出、
防火墙拦住了端口。

音轨与字幕的记忆
----------------
每部片选过的音轨与字幕会被记住，下次打开自动恢复。找不到原来的轨
（换集、转封装都会改轨道 id）时，会按语言、标题退到最接近的一条。

记录放在哪里由服务端形态决定，设置页的「配置存储位置」会直接写明：

- 便携版服务端：显示「跟随本机客户端目录」，选择放在客户端文件夹里，
  换服务器也不丢。
- 安装版服务端：显示「跟随『服务器名』目录」，选择放在服务端并按设备
  分开记录，同一部片各设备记各的，不跨设备同步。

这个位置不提供手动切换，只做告知。

数据位置
--------
    PAVL-data\\client.json    连接信息、本机的音轨字幕选择
    PAVL-data\\client.log     播放日志（播放过才会生成）

删除该文件夹等于恢复出厂设置，已配对的服务器与记住的选择都会清空。

许可
----
本包内含 libmpv（LGPL-2.1-or-later，GPL 组件已关闭，动态链接使用）、
MiSans 字体（Apache License 2.0）与 Flutter 运行时（BSD-3-Clause）。
完整声明见同目录的 LICENSE.txt，也可以在设置页的「关于 → 许可」里
直接查看；字体许可全文在 data\\flutter_assets\\assets\\fonts\\ 下。

Windows 安全提示
----------------
本程序没有购买代码签名证书，首次运行时 Windows SmartScreen 可能提示
「Windows 已保护你的电脑」。点「更多信息」→「仍要运行」即可。
"""

ROOT_README = """\
PAVL — Play All Videos in Lan
=============================

局域网内跨设备播放服务器上视频的自建方案。

服务端与客户端分开发布，按需下载：

    PAVL_windows_server_portable_<版本>     服务端，跑在放视频的那台机器上
    PAVL_windows_client_portable_<版本>     Windows 客户端，免安装
    PAVL_macos_client_<版本>                macOS 客户端

快速开始
--------
1. 在存放视频的电脑上运行服务端的 pavl.exe，
   第一次按提示选一个媒体目录，或者用命令行指定：

       pavl.exe --root "D:\\Videos"

   以后想加目录、换目录或停掉某一个目录，右键点通知区域里的图标即可，不用重启。

2. 防火墙提示点「允许访问」。
3. 在任意设备上运行客户端。
4. 输入服务端托盘菜单里显示的 PIN。

说明文档在各包内的 README.txt。

技术要点
--------
服务端只做三件事：扫文件系统建索引、用 HTTP Range 发文件、存取进度。
不解码、不转封装、不依赖 ffmpeg，所以是 7.5MB 单文件、内存占用几十 MB。
所有解码在客户端用 libmpv 完成，因此 MKV / HEVC / AV1 / ASS 字幕 / PGS 图形字幕
全部支持，不需要任何转码。

许可
----
程序内含 lpinyin（BSD 2-Clause），用来把汉字转成拼音做排序。
字典编进 exe 里，不加载外部文件，但再分发二进制时仍需随附其版权声明。
LICENSE.txt 是完整声明，含 lpinyin 与 Dart 运行时的条款。
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

三个页面：浏览按共享目录逐层展开；片库按文件夹收拢，
文件夹行显示两层目录名与集数、点开展开；点任意一部进入播放。

片库可以刮削：服务端按片名去豆瓣、IMDb、B 站取海报、年份、评分与简介，
抓到后文件夹行直接显示海报。默认关闭，在设置的「播放 → 片库」里打开，
那里也能选信息来源、手动刮削整个片库或清空记录。

键盘：空格播放/暂停，左右键 ±10 秒，上下键 ±5 音量，F 全屏，Esc 返回。
播放期间会阻止屏幕自动熄灭，暂停或退出时释放。
重新打开看过的片会先问一句：从上次的位置继续，还是从头开始。
已经看到 90% 以上的算看完，不再问，也不进最近播放。

点窗口左上角的红色按钮只是把窗口收进 Dock，程序仍在后台，
点了别的窗口随时能叫回来。要真正退出按 ⌘Q，或者在菜单栏选
PAVL → 退出 PAVL。点 Dock 上的图标也能把窗口叫回来。

数据位置
--------
    ~/Library/Application Support/PAVL/client.json    连接信息
    ~/Library/Application Support/PAVL/client.log     播放日志

删除这个文件夹等于恢复出厂设置。设置页里的「打开日志目录」会直接定位到那里。

许可
----
本包内含 libmpv（LGPL-2.1-or-later，GPL 组件已关闭，动态链接使用）、
MiSans 字体（Apache License 2.0）与 Flutter 运行时（BSD-3-Clause）。
完整声明见同目录的 LICENSE.txt，字体许可全文在 PAVL.app 内的
Contents/Frameworks/App.framework/Resources/flutter_assets/assets/fonts/ 下。

服务端
------
PAVL 服务端只提供 Windows 版本（同一下载页面里的 _server 包），
需要在 Windows 或 Linux 机器上运行，macOS 客户端通过局域网连接它。
"""


def _require(path: Path, what: str) -> None:
    if not path.exists():
        sys.exit(f"缺少{what}：{path}\n请先构建。")


def _prepare(out_root: Path, name: str) -> Path:
    """建一个空的目标目录，同名旧目录先删掉。"""
    target = out_root / name
    if target.exists():
        shutil.rmtree(target)
    target.mkdir(parents=True)
    return target


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


def check_license_copies() -> None:
    """确认客户端内嵌的许可证副本与仓库根 LICENSE 完全一致。

    客户端「关于 → 许可」读的是随包分发的 assets/LICENSE.txt，包外的
    LICENSE.txt 与它必须逐字相同，否则用户在不同入口看到的条款会不一样。
    打包前比一次，不一致直接中止，避免把不一致的包发出去。
    """
    root_copy = (ROOT / "LICENSE").read_bytes()
    asset_path = ROOT / "client" / "assets" / "LICENSE.txt"
    if not asset_path.exists():
        raise SystemExit(f"缺少客户端许可副本：{asset_path}，先复制仓库根的 LICENSE")
    if asset_path.read_bytes() != root_copy:
        raise SystemExit(
            f"客户端许可副本与仓库根 LICENSE 不一致：{asset_path}\n"
            "重新复制一份再打包：cp LICENSE client/assets/LICENSE.txt"
        )
    print(f"许可校验: client/assets/LICENSE.txt 与 LICENSE 一致（{len(root_copy)} 字节）")


def _copy_license(target: Path) -> None:
    """把仓库根目录的 LICENSE 一并放进发布包。

    第三方组件的许可要求再分发时随附版权声明：lpinyin 是 BSD 2-Clause、
    Dart 运行时与 Flutter 是 BSD-3-Clause、MiSans 是 Apache 2.0。这些条款
    写在 LICENSE 里，只留在代码仓库是不够的——用户拿到的是解压出来的文件夹，
    所以每个包都要带一份。
    """
    shutil.copy2(ROOT / "LICENSE", target / "LICENSE.txt")


def package_server(out_root: Path, name: str) -> Path:
    """服务端包：只有一个 exe 和说明，不带客户端。"""
    _require(SERVER_EXE, "服务端 exe")

    # 服务端是 dart compile exe 的产物，编译器不接受图标参数；不补这一步，
    # 资源管理器与任务栏会显示系统默认的空白程序图标。已经带图标的 exe
    # 会直接跳过，所以每次打包都可以放心调用。
    if embed_icon.ensure_icon(SERVER_EXE):
        print("图标补写: build/pavl.exe 已嵌入应用图标（此前没有）")

    target = _prepare(out_root, name)
    shutil.copy2(SERVER_EXE, target / "pavl.exe")
    (target / "README.txt").write_text(SERVER_README, encoding="utf-8")
    _copy_license(target)
    return target


def package_portable(out_root: Path, name: str) -> Path:
    """Windows 客户端便携版：exe + 运行时目录，免安装。"""
    _require(CLIENT_DIR / "pavl_client.exe", "客户端 exe")

    target = _prepare(out_root, name)

    # 排除本机运行时产生的数据：PAVL-data 里有配对令牌与日志，绝不能进发布包。
    # nohup.out 是早期用 nohup 起客户端时留在 Release 目录里的输出文件，
    # 不是构建产物，同样不该进包。
    skip = {"PAVL-data", "nohup.out"}
    for item in CLIENT_DIR.iterdir():
        if item.name in skip or item.name.endswith(".log"):
            continue
        dest = target / item.name
        if item.is_dir():
            shutil.copytree(item, dest)
        else:
            shutil.copy2(item, dest)
    (target / "README.txt").write_text(CLIENT_README, encoding="utf-8")
    _copy_license(target)
    return target


def package_macos(out_root: Path, name: str) -> Path:
    """macOS 客户端：只有一个 .app 与说明，不带服务端。"""
    _require(MACOS_APP, "macOS 应用包（在 macOS 上执行 flutter build macos --release）")

    target = _prepare(out_root, name)

    # symlinks=True 必须带：Flutter.framework 内部是用符号链接组织的版本目录，
    # 解引用会把包撑大好几倍，还会破坏框架结构。
    shutil.copytree(MACOS_APP, target / MACOS_APP.name, symlinks=True)
    (target / "README.txt").write_text(MACOS_README, encoding="utf-8")
    _copy_license(target)
    return target


def main() -> int:
    parser = argparse.ArgumentParser(description="打包 PAVL 分发目录")
    parser.add_argument("--out", default=str(ROOT / "dist"), help="输出根目录")
    parser.add_argument("--zip", action="store_true", help="额外生成 zip")
    parser.add_argument("--server", action="store_true", help="只打服务端包")
    parser.add_argument("--portable", action="store_true", help="只打 Windows 客户端便携版")
    parser.add_argument("--macos", action="store_true", help="只打 macOS 客户端包")
    parser.add_argument(
        "--all",
        action="store_true",
        help="打当前平台上能打的全套（Windows 出服务端 + 便携版，macOS 出客户端）",
    )
    parser.add_argument("--name", default=None, help="强制指定目录名（只对单个包生效）")
    args = parser.parse_args()

    wanted_server = args.server or args.all
    wanted_portable = args.portable or args.all
    wanted_macos = args.macos or args.all
    if not (wanted_server or wanted_portable or wanted_macos):
        parser.error("至少要指定 --server / --portable / --macos / --all 之一")

    if args.name and sum([wanted_server, wanted_portable, wanted_macos]) > 1:
        parser.error("--name 只能和单个包一起用")

    check_license_copies()

    out_root = Path(args.out)
    out_root.mkdir(parents=True, exist_ok=True)

    built: list[tuple[Path, bool]] = []
    if wanted_server:
        name = args.name or server_package_name()
        built.append((package_server(out_root, name), False))
    if wanted_portable:
        name = args.name or portable_package_name()
        built.append((package_portable(out_root, name), False))
    if wanted_macos:
        name = args.name or macos_package_name()
        built.append((package_macos(out_root, name), True))

    for target, need_ditto in built:
        print()
        _report(target)
        if args.zip:
            if need_ditto:
                _zip_app_bundle(out_root, target, target.name)
            else:
                _zip_dir(out_root, target)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
