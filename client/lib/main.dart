/// PAVL 客户端入口。
library;

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'store/app_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

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
