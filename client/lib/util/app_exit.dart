/// 结束当前进程。
///
/// 更新时要用：新本体已经拉起来了，旧进程必须让位，否则安装目录里的文件
/// 一直被占着。macOS 上窗口关掉默认只是收进 Dock，所以这里先把「关窗即
/// 退出」的拦截解除，再销毁窗口，最后兜底 exit。
library;

import 'dart:async';
import 'dart:io';

import 'package:window_manager/window_manager.dart';

import 'app_log.dart';

/// 直接退出应用程序。
Future<void> exitApp() async {
  logLine('app', '准备退出，交给新版本接管');
  try {
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  } catch (error) {
    logLine('app', '销毁窗口失败：$error');
  }
  // 窗口销毁之后进程通常自己就退了；这一行是兜底。
  await Future<void>.delayed(const Duration(milliseconds: 200));
  exit(0);
}
