/// PAVL 客户端入口。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'store/app_store.dart';
import 'util/app_log.dart';

/// 把 `Directory.systemTemp` 指到便携目录。
///
/// 播放内核（libmpv 的 Dart 封装）在建播放列表、内嵌字幕轨时会往系统临时
/// 目录写文件。有些机器上 TEMP/TMP 没配好，Windows 回退到 `C:\WINDOWS\TEMP`，
/// 普通用户没有写权限，结果就是任何片都打不开、只报一句「拒绝访问」。
/// 覆盖之后临时文件落在 exe 同级的 `PAVL-data/temp/`，与机器环境无关。
class _PortableIOOverrides extends IOOverrides {
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

  final store = await AppStore.load();

  runApp(PavlApp(store: store));
}
