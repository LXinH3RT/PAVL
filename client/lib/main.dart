/// PAVL 客户端入口。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'store/app_store.dart';
import 'util/app_log.dart';

/// 关窗口时把窗口收起来，而不是退出程序。
///
/// 只在 macOS 上挂：那边的惯例是关窗口不结束进程，Dock 图标还在，点一下就能
/// 把窗口叫回来，只有 ⌘Q 才真正退出。Windows 上关窗口就是退出，保持不变。
///
/// [windowManager.setPreventClose] 让原生侧的 windowShouldClose 先发一条 close
/// 事件再返回 false，所以这里收到回调时窗口还在，直接 hide 即可。
class _MacHideOnClose with WindowListener {
  @override
  void onWindowClose() {
    logLine('app', '关闭窗口，收进 Dock；⌘Q 退出');
    unawaited(windowManager.hide());
  }
}

/// 把 `Directory.systemTemp` 指到便携目录。
///
/// 播放内核（libmpv 的 Dart 封装）在建播放列表、内嵌字幕轨时会往系统临时
/// 目录写文件。有些机器上 TEMP/TMP 没配好，Windows 回退到 `C:\WINDOWS\TEMP`，
/// 普通用户没有写权限，结果就是任何片都打不开、只报一句「拒绝访问」。
/// 覆盖之后临时文件落在 exe 同级的 `PAVL-data/temp/`，与机器环境无关。
final class _PortableIOOverrides extends IOOverrides {
  @override
  Directory getSystemTempDirectory() => appTempDir();
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 必须在任何媒体对象构造之前设好，播放列表第一次创建就会用到。
  IOOverrides.global = _PortableIOOverrides();

  logLine('app', '启动，数据目录 ${appDataDir().path}');

  // libmpv 通过 ffi 加载，必须在创建 Player 之前初始化一次。
  MediaKit.ensureInitialized();

  await windowManager.ensureInitialized();
  const options = WindowOptions(
    size: Size(1280, 820),
    minimumSize: Size(960, 600),
    center: true,
    title: 'PAVL',
    // 播放器要能全屏，标题栏交给自绘，这样播放页可以无缝切到纯画面。
    titleBarStyle: TitleBarStyle.normal,
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.show();
    await windowManager.focus();
  });

  if (Platform.isMacOS) {
    await windowManager.setPreventClose(true);
    windowManager.addListener(_MacHideOnClose());
  }

  final store = await AppStore.load();

  runApp(PavlApp(store: store));
}
