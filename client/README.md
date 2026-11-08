# pavl_client

PAVL 的 Windows 客户端。连接局域网里的 PAVL 服务端，浏览共享的视频目录并播放。播放内核是
media_kit 封装的 libmpv，解码、字幕、音轨切换都在本地完成。

## 构建

```
python ../scripts/setup_media_kit_deps.py   # 预置 libmpv 与 ANGLE
flutter pub get
flutter build windows --release
```

产物在 `build/windows/x64/runner/Release/`。`setup_media_kit_deps.py` 用于避免 CMake 在构建时
联网下载预编译包失败。

## 运行时数据

客户端便携：配置、日志与临时文件都写在 `pavl_client.exe` 同级的 `PAVL-data/` 目录，不写注册表，
也不写用户目录。删掉该目录即可恢复到首次运行状态。

## 目录

```
lib/
├─ api/         HTTP 客户端、DTO、局域网发现
├─ store/       本地配置与便携目录
├─ player/      播放控制封装（media_kit）
├─ ui/          连接、浏览、播放、设置、配对与各类控件
├─ util/        日志与自然排序
└─ app.dart     主题与全局字体
assets/
├─ fonts/       界面字体 MiSans 与许可文件
└─ branding/    应用标识
```

## 许可

界面字体为 MiSans，按 Apache License 2.0 随程序分发，许可证与声明见 `assets/fonts/`。播放内核
libmpv 按 LGPL-2.1-or-later 动态链接使用。完整说明见仓库根目录的 `LICENSE`。
