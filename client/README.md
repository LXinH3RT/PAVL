# pavl_client

PAVL 的桌面客户端，支持 Windows 与 macOS。连接局域网里的 PAVL 服务端，浏览共享的视频目录并
播放。播放内核是 media_kit 封装的 libmpv，解码、字幕、音轨切换都在本地完成。

界面有三个页面：连接页、浏览页、片库页，播放页在进入影片后叠加。浏览页按目录逐层进；片库页把
全库视频拉平成一张表，按标题排、可按关键词搜索、滚动到底自动加载下一页，顶部带最近播放。两页
都保留是因为用途不同：知道片子在哪个文件夹时走浏览页最快，记不住位置时走片库页。

**列表顺序一律由服务端决定**，客户端只做「文件夹在前」的分组，不再比较名称。排序规则集中在
`server/lib/sort_key.dart`：数字按数值、字母不分大小写、汉字按拼音（`lpinyin`），且数字排字母
前、字母排汉字前。客户端若也排一遍，两套规则一旦有出入，同一批名称在不同层级就会排出不同顺序。

## 构建

**Windows**

```
python ../scripts/setup_media_kit_deps.py   # 预置 libmpv 与 ANGLE
flutter pub get
flutter build windows --release
```

产物在 `build/windows/x64/runner/Release/`。`setup_media_kit_deps.py` 用于避免 CMake 在构建时
联网下载预编译包失败。

**macOS**

```
flutter pub get
flutter build macos --release
```

产物在 `build/macos/Build/Products/Release/PAVL.app`。libmpv 的 xcframework 由
`media_kit_libs_macos_video` 在 `pod install` 阶段下载，无需额外脚本。产物是 universal 二进制，
Intel 与 Apple Silicon 共用同一个包。

`macos/Podfile` 的 `post_install` 会把所有 pod 的部署目标强制改成 12.0。新版 Xcode 只支持 12.0
及以上的部署目标（实测 27.2 报 `the range of supported deployment target versions is 12.0 to
27.2.x`），而依赖的 podspec 仍写着 10.9。这一段不要删，删掉后每次 `pod install` 都会被打回旧值
并直接编译失败。

首次运行系统会询问「本地网络」权限，必须允许。误点拒绝后系统不再弹窗，客户端此时既发现不到
服务器也拉不到流，且没有任何报错。手动广播一轮仍无应答时，界面会提示去
「系统设置 → 隐私与安全性 → 本地网络」检查。

## 运行时数据

**Windows**：客户端便携，配置、日志与临时文件都写在 `pavl_client.exe` 同级的 `PAVL-data/`
目录，不写注册表，也不写用户目录。删掉该目录即可恢复到首次运行状态。

**macOS**：写在 `~/Library/Application Support/PAVL/`。`.app` 是被代码签名封存的目录，往里写会破坏
签名，而且装到 `/Applications` 后普通用户没有写权限，所以这里不用便携目录。设置页的「打开日志
目录」可以直接定位过去。

需要并行跑多个测试实例时，用环境变量 `PAVL_DATA_DIR` 指定独立目录，避免互相覆盖配对状态。

## 目录

```
lib/
├─ api/         HTTP 客户端、DTO、局域网发现
├─ store/       本地配置与数据目录
├─ player/      播放控制封装（media_kit）
├─ ui/          连接、浏览、片库、播放、设置、配对与各类控件
├─ util/        日志、平台差异（platform_support.dart）
└─ app.dart     主题与全局字体
assets/
├─ fonts/       界面字体 MiSans 与许可文件
└─ branding/    应用标识
windows/        Windows 平台工程
macos/          macOS 平台工程
integration_test/  真机端到端测试（见下）
```

## 端到端测试

`integration_test/` 下有四套用例，都在真实应用进程里跑，会真正拉起 libmpv 与网络，需要先启动一个
可连通的 PAVL 服务端。

```
flutter test integration_test/macos_smoke_test.dart -d macos \
  --dart-define=PAVL_TEST_HOST=<服务端地址> --dart-define=PAVL_TEST_PORT=<端口> \
  --dart-define=PAVL_TEST_PIN=<PIN>
```

| 文件 | 覆盖 |
|-|-|
| `macos_smoke_test.dart` | 平台标识与数据目录、日志可写、UDP 发现、PIN 配对、列目录、拉流并解出首帧 |
| `macos_ui_test.dart` | 主界面主题与字体、浏览页列目录、播放页起播并渲染控制栏 |
| `macos_flow_test.dart` | 外挂字幕下载、播放推进与结束回写进度、媒体信息回写、最近列表、播放期间持有屏幕唤醒锁 |
| `macos_library_test.dart` | 片库跨目录拉平并按标题排序（界面首屏顺序与接口返回逐条比对）、关键词搜索收窄、清空关键词回到全量 |

`macos_flow_test.dart`、`macos_ui_test.dart` 与 `macos_library_test.dart` 在 Windows 上同样能跑，
把 `-d macos` 换成 `-d windows` 即可。`macos_smoke_test.dart` 的「平台标识与数据目录」断言的是
macOS 专属的 `~/Library/Application Support/PAVL` 约定，在其它平台上自动跳过。

测试用例里挑视频一律按「收集全部候选 → 取体积最大的那个」，不是取第一个命中。测试目录里常掺着
几百字节的占位文件，它们同样带 `.mkv` 后缀、同样被判成视频，但 libmpv 解不出帧，会让解码用例
假阴性。

一个文件跑一次。多个文件同时传给 `flutter test` 时，第二个会报
`Unable to start the app on the device`——桌面端的集成测试不支持在同一次运行里复用设备。

## 打包

服务端与客户端分开发布，客户端在两个平台上各打一个包：

```
python scripts/package.py --portable --zip   # Windows 便携版
python scripts/package.py --macos --zip      # macOS（必须在 macOS 上跑）
```

产物命名规则见仓库根目录的 README。`.app` 的压缩必须用 `ditto`，普通 zip 会丢掉符号链接与
可执行权限，解压后起不来。

## 许可

界面字体为 MiSans，按 Apache License 2.0 随程序分发，许可证与声明见 `assets/fonts/`。播放内核
libmpv 按 LGPL-2.1-or-later 动态链接使用。完整说明见仓库根目录的 `LICENSE`。

打包时会把这个文件复制成发布包里的 `LICENSE.txt`：MiSans（Apache 2.0）、Flutter 运行时
（BSD-3-Clause）与 lpinyin（BSD 2-Clause，仅服务端）都要求再分发时随附版权声明，用户拿到的
是解压后的文件夹，只在仓库里放一份不够。
