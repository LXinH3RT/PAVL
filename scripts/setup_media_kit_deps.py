#!/usr/bin/env python3
"""预置 media_kit 在 Windows 平台上需要的两个二进制包。

为什么需要这个脚本
------------------
media_kit_libs_windows_video 的 CMakeLists.txt 用 `file(DOWNLOAD)` 从 GitHub
Release 拉取 libmpv 与 ANGLE 两个压缩包。在没有代理、代理拦截、或网络抖动的
环境下，`file(DOWNLOAD)` 可能**静默地写出一个 0 字节文件**，随后 MD5 校验失败，
报出误导性极强的错误：

    Integrity check failed, please try to re-build project again.

这个报错看起来像「上游包损坏」或「media_kit 不可用」，实际只是下载环节坏了。
本脚本用国内加速镜像把这两个包提前放到 CMake 期望的位置，CMake 检测到文件存在
且 MD5 匹配就会跳过下载，直接解压。

用法
----
    python scripts/setup_media_kit_deps.py            # 预置（已存在且校验通过则跳过）
    python scripts/setup_media_kit_deps.py --force    # 强制重新下载
    python scripts/setup_media_kit_deps.py --check    # 只检查，不下载

预置完成后再执行 `flutter build windows --release`。
"""

from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import sys
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

# ---------------------------------------------------------------------------
# 两个依赖包的元数据。URL 与 MD5 必须与 media_kit_libs_windows_video 的
# CMakeLists.txt 保持一致，否则 CMake 仍会认为文件无效并重新下载。
# 升级 media_kit 版本时要回来同步这张表。
# ---------------------------------------------------------------------------

PACKAGES = [
    {
        "name": "libmpv",
        "filename": "mpv-dev-x86_64-20230924-git-652a1dd.7z",
        "url": (
            "https://github.com/media-kit/libmpv-win32-video-build/"
            "releases/download/2023-09-24/mpv-dev-x86_64-20230924-git-652a1dd.7z"
        ),
        "md5": "a832ef24b3a6ff97cd2560b5b9d04cd8",
        "size": 8_785_710,
    },
    {
        "name": "ANGLE",
        "filename": "ANGLE.7z",
        "url": (
            "https://github.com/alexmercerind/flutter-windows-ANGLE-OpenGL-ES/"
            "releases/download/v1.0.1/ANGLE.7z"
        ),
        "md5": "e866f13e8d552348058afaafe869b1ed",
        "size": 5_035_414,
    },
]

# 按顺序尝试。ghfast.top 实测 4~5 秒下完，gh-proxy.com 可用但慢约 4 倍。
# 注意 ghproxy.cn 会返回 HTTP 200 却只有 6990 字节的错误页，看起来「成功」
# 实则内容错误 —— 所以每个候选都必须过 MD5，不能只看状态码。
MIRROR_PREFIXES = [
    "https://ghfast.top/",
    "https://gh-proxy.com/",
    "",  # 直连兜底
]

CHUNK = 1 << 16


def _force_utf8_stdout() -> None:
    """Windows 控制台默认是 GBK，直接 print 中文会变成乱码或抛 UnicodeEncodeError。

    强制切到 UTF-8 并允许替换无法编码的字符，保证脚本在任何终端都能读到可辨认
    的输出。errors="replace" 是为了不因某个符号编码失败而中断整个下载流程。
    """
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass  # 已被重定向到不支持 reconfigure 的对象，保持原样


_force_utf8_stdout()


def md5_of(path: Path) -> str:
    h = hashlib.md5()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(CHUNK), b""):
            h.update(block)
    return h.hexdigest()


def project_root() -> Path:
    """脚本位于 <root>/scripts/ 下，父目录即项目根。"""
    return Path(__file__).resolve().parent.parent


def cmake_binary_dir(root: Path) -> Path:
    """与 CMake 的 CMAKE_BINARY_DIR 对齐：<client>/build/windows/x64。

    Flutter 在 Windows 上固定使用这个目录，而 Flutter 工程在 client/ 子目录里。
    包放在这里，CMake 的 download_and_verify() 会先做 MD5 检查，通过则不再
    发起网络请求 —— 这一步很关键，因为 CMake 的 file(DOWNLOAD) 在代理环境下
    会静默写出 0 字节文件，然后报出误导性的 Integrity check failed。
    """
    return root / "client" / "build" / "windows" / "x64"


def human(n: int) -> str:
    return f"{n / 1048576:.1f} MiB"


def download(url: str, dest: Path, label: str) -> bool:
    """下载到临时文件，成功返回 True。异常一律吞掉，由调用方决定换源。

    进度只在每跨过 10% 时打印一行，而不是每个数据块都覆写同一行 —— 脚本的
    输出经常被重定向到日志或 CI 面板，回车覆写在那种环境下会堆成几千行垃圾。
    非交互式 stdout 甚至完全不打进度，只留结果。
    """
    interactive = sys.stdout.isatty()
    req = urllib.request.Request(
        url,
        headers={
            # 部分镜像对没有 UA 的请求返回 HTML 错误页
            "User-Agent": "pavl-setup/1.0",
            "Accept": "*/*",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            total = int(resp.headers.get("Content-Length") or 0)
            written = 0
            last_pct = -1
            with tempfile.NamedTemporaryFile(
                dir=dest.parent, prefix=".pavl-dl-", delete=False
            ) as tmp:
                tmp_path = Path(tmp.name)
                while True:
                    block = resp.read(CHUNK)
                    if not block:
                        break
                    tmp.write(block)
                    written += len(block)
                    if total and interactive:
                        pct = written * 100 // total
                        if pct // 10 != last_pct // 10:
                            last_pct = pct
                            print(f"    {label} {pct}%  {human(written)} / {human(total)}")
            shutil.move(str(tmp_path), str(dest))
            return True
    except (urllib.error.URLError, urllib.error.HTTPError, OSError) as exc:
        print(f"    × {exc}")
        return False


def ensure_package(pkg: dict, target_dir: Path, force: bool, check_only: bool) -> bool:
    dest = target_dir / pkg["filename"]
    print(f"[{pkg['name']}] {pkg['filename']}")

    if dest.exists() and not force:
        actual = md5_of(dest)
        if actual == pkg["md5"]:
            print(f"    已存在且校验通过，跳过（{human(dest.stat().st_size)}）")
            return True
        print(f"    已存在但 MD5 不符（{actual}），删除后重下")
        dest.unlink()

    if check_only:
        print("    缺失")
        return False

    target_dir.mkdir(parents=True, exist_ok=True)

    for prefix in MIRROR_PREFIXES:
        url = prefix + pkg["url"]
        source = "直连" if not prefix else prefix.rstrip("/")
        print(f"    尝试 {source}")
        if not download(url, dest, pkg["name"]):
            continue

        size = dest.stat().st_size
        actual = md5_of(dest)
        # 两道校验：MD5 是权威判据，大小是便宜的早期排除。
        # 有些镜像返回的 HTML 错误页恰好带着 200 状态码，只能靠内容识别。
        if actual == pkg["md5"]:
            print(f"    ✓ 完成（{human(size)}，MD5 匹配）")
            return True

        print(f"    × 内容不符：{human(size)}，MD5 {actual}")
        if size != pkg["size"]:
            print(f"      预期 {human(pkg['size'])}，实际 {human(size)}")
        dest.unlink()

    print(f"    ! {pkg['name']} 全部来源失败")
    return False


def main() -> int:
    parser = argparse.ArgumentParser(
        description="预置 media_kit 的 Windows 预编译依赖（libmpv / ANGLE）"
    )
    parser.add_argument(
        "--force", action="store_true", help="即使已存在且校验通过也重新下载"
    )
    parser.add_argument(
        "--check", action="store_true", help="只检查是否就绪，不下载"
    )
    args = parser.parse_args()

    root = project_root()
    target = cmake_binary_dir(root)

    print(f"项目根目录 : {root}")
    print(f"目标目录   : {target}")
    print()

    ok = True
    for pkg in PACKAGES:
        if not ensure_package(pkg, target, args.force, args.check):
            ok = False
        print()

    if not ok:
        if args.check:
            print("依赖未就绪，运行不带 --check 的本脚本可自动下载。")
        else:
            print("预置失败：所有镜像与直连均未取到校验通过的文件。")
            print("可手动下载后放入上面的目标目录（文件名与 MD5 必须一致）：")
            for pkg in PACKAGES:
                print(f"  {pkg['filename']}  md5={pkg['md5']}")
        return 1

    print("依赖已就绪，可以执行： flutter build windows --release")
    return 0


if __name__ == "__main__":
    sys.exit(main())
