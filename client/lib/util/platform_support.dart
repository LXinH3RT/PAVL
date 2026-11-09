/// 平台差异的集中封装。
///
/// 客户端要同时跑在 Windows 与 macOS 上，两边在「向服务端上报的平台名」、
/// 「用哪个命令打开目录」这类事情上不一样。把这些散落在各处的判断收在一处，
/// 避免每个调用点各自写一遍 `Platform.isXxx`。
library;

import 'dart:io';

/// 平台标签，配对时上报给服务端，设备列表里按它显示图标。
String get platformTag {
  if (Platform.isWindows) return 'windows';
  if (Platform.isMacOS) return 'macos';
  if (Platform.isLinux) return 'linux';
  if (Platform.isAndroid) return 'android';
  if (Platform.isIOS) return 'ios';
  return 'unknown';
}

/// 平台显示名，用于界面文案。
String get platformLabel {
  if (Platform.isWindows) return 'Windows';
  if (Platform.isMacOS) return 'macOS';
  if (Platform.isLinux) return 'Linux';
  if (Platform.isAndroid) return 'Android';
  if (Platform.isIOS) return 'iOS';
  return '未知平台';
}

/// 在系统文件管理器里打开一个目录。
///
/// 各平台打开成功时的退出码约定不同，且存在「命令本身起不来」的情况
/// （Windows 上环境块异常会让 explorer 以 0xC0000142 立即退出）。因此统一
/// 等一会儿进程状态：能正常退出或一直活着都算打开成功，立即以异常码退出
/// 才算失败，调用方据此退回「把路径复制到剪贴板」。
Future<bool> openDirectoryInFileManager(String path) async {
  final String command;
  final List<String> arguments;
  if (Platform.isWindows) {
    // explorer 不接受 `file:` URI，必须给 Windows 原生路径。
    command = 'explorer.exe';
    arguments = <String>[path];
  } else if (Platform.isMacOS) {
    // `open` 打开目录；加 -R 会选中条目而不是进入目录，这里要进入目录。
    command = 'open';
    arguments = <String>[path];
  } else if (Platform.isLinux) {
    command = 'xdg-open';
    arguments = <String>[path];
  } else {
    return false;
  }

  try {
    final process = await Process.start(command, arguments);
    final code = await process.exitCode
        .timeout(const Duration(seconds: 2), onTimeout: () => 0);
    // Windows 的 explorer 成功时退出码是 0 或 1（不同版本不一致）；
    // macOS 的 open 成功时是 0。其它非零一律当作没打开。
    return code == 0 || (Platform.isWindows && code == 1);
  } catch (_) {
    return false;
  }
}
