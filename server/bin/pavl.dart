/// PAVL 服务端命令行入口。
///
/// 用法：
///   pavl                      托盘模式启动（Windows）
///   pavl --console            控制台模式启动，日志打在终端
///   pavl --port 8765          覆盖端口
///   pavl --root D:\Videos     追加一个媒体根目录（可重复）
///   pavl --name 客厅           覆盖显示名
///   pavl --pin 123456         覆盖配对 PIN
///   pavl --print-config       打印当前配置后退出
///   pavl --reset-pin          重新生成 PIN 后退出
library;

import 'dart:async';
import 'dart:io';

import 'package:pavl_server/auth.dart';
import 'package:pavl_server/config.dart';
import 'package:pavl_server/native_dialogs.dart';
import 'package:pavl_server/pavl_server.dart' as pavl;
import 'package:pavl_server/tray.dart';

Future<void> main(List<String> args) async {
  final options = _parseArgs(args);
  if (options == null) {
    _printUsage();
    exitCode = 2;
    return;
  }

  final store = ConfigStore.defaultStore();
  final config = await store.load();

  if (options.printConfig) {
    stdout.writeln(_describe(config, store.file.path));
    return;
  }

  if (options.resetPin) {
    config.pin = _generatePin();
    await store.save(config);
    stdout.writeln('新的配对 PIN: ${config.pin}');
    stdout.writeln('配置文件: ${store.file.path}');
    return;
  }

  if (options.port != null) config.port = options.port!;
  if (options.name != null) config.serverName = options.name!;
  if (options.pin != null) config.pin = options.pin!;
  for (final path in options.roots) {
    if (config.roots.any((r) => r.path == path)) continue;
    config.roots.add(RootDir(path: path));
  }

  if (config.roots.isEmpty) {
    // 双击启动时没有控制台，只能靠原生的选择框让用户挑一个目录，
    // 否则用户只会看到黑框一闪、什么都不知道。
    if (!options.tray || !TrayIcon.available) {
      stderr.writeln('没有任何媒体根目录。用 --root 指定，或编辑 ${store.file.path}');
      stderr.writeln('示例：pavl --root D:\\\\Videos --root E:\\\\Movies');
      exitCode = 2;
      return;
    }
    final picked = pickFolder(title: '选择要共享的视频文件夹');
    if (picked == null || picked.isEmpty) {
      showMessage(
        '还没有指定要共享的文件夹。\n\n'
        '再双击一次 pavl.exe 并选择一个文件夹即可。\n'
        '也可以带参数启动：pavl.exe --root "D:\\Videos"',
        caption: 'PAVL 还没准备好',
        isError: true,
      );
      exitCode = 2;
      return;
    }
    config.roots.add(RootDir(path: picked));
  }

  // 过滤掉不存在的根，避免扫描时报一堆错。
  final missing = <RootDir>[];
  for (final root in config.roots) {
    if (!Directory(root.path).existsSync()) missing.add(root);
  }
  for (final root in missing) {
    stderr.writeln('跳过不存在的根目录: ${root.path}');
  }
  if (missing.length == config.roots.length) {
    if (options.tray && TrayIcon.available) {
      final picked = pickFolder(title: '原来的文件夹找不到了，请重新选择');
      if (picked != null && picked.isNotEmpty) {
        config.roots
          ..clear()
          ..add(RootDir(path: picked));
        missing.clear();
      } else {
        showMessage(
          '配置里的文件夹都不存在了：\n\n${config.roots.map((r) => r.path).join('\n')}',
          caption: 'PAVL 启动失败',
          isError: true,
        );
        exitCode = 2;
        return;
      }
    } else {
      stderr.writeln('所有根目录都不存在，启动中止。');
      exitCode = 2;
      return;
    }
  }

  await store.save(config);

  // 托盘模式下控制台会被 FreeConsole 解绑，之后往 stdout 写会失败；
  // 日志改投文件，控制台模式下才写终端。
  final wantTray = options.tray && TrayIcon.available;
  final logFile = wantTray
      ? File('${store.file.parent.path}${Platform.pathSeparator}pavl.log')
      : null;
  void logLine(String message) {
    final line = '${DateTime.now().toIso8601String()} $message';
    if (logFile == null) {
      stdout.writeln('[PAVL] $message');
      return;
    }
    try {
      logFile.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
    } catch (_) {
      // 日志写不了也不能影响服务本身。
    }
  }

  final server = await pavl.startServer(
    config: config,
    configStore: store,
    log: logLine,
  );

  final address = await _localAddress();
  final home = 'http://$address:${server.port}';

  // 托盘模式：不显示控制台，把入口收进通知区域。
  TrayIcon? tray;

  if (wantTray) {
    tray = TrayIcon(
      tooltip: '${config.serverName} · ${config.pin}',
      onMenu: () => [
        TrayMenuItem.info('${config.serverName}  ·  ${config.roots.length} 个目录'),
        TrayMenuItem.info('地址  $home'),
        TrayMenuItem.info('PIN   ${config.pin}'),
        TrayMenuItem.separator(),
        TrayMenuItem(TrayCommand.copyPin, '复制 PIN'),
        TrayMenuItem(TrayCommand.openBrowser, '在浏览器中打开'),
        TrayMenuItem(TrayCommand.openDataDir, '打开数据目录'),
        TrayMenuItem(TrayCommand.regeneratePin, '重新生成 PIN（旧设备需重新配对）'),
        TrayMenuItem.separator(),
        TrayMenuItem(TrayCommand.exit, '退出'),
      ],
      onCommand: (id) async {
        await _handleTrayCommand(id, config, store, server, home);
        // PIN 可能被改过，菜单里显示的那行要跟着变。
        tray?.refresh();
      },
      onDoubleClick: () => _openUrl(home),
      onClosed: () => _shutdown?.call(),
    );

    if (!await tray.start()) {
      stderr.writeln('托盘初始化失败，退回控制台模式。');
      tray = null;
    } else {
      detachConsole();
    }
  }

  if (tray == null) {
    stdout.writeln('');
    stdout.writeln('  PAVL 服务端已启动');
    stdout.writeln('  名称: ${config.serverName}');
    stdout.writeln('  地址: $home');
    stdout.writeln('  PIN : ${config.pin}');
    stdout.writeln('  发现: ${server.discoveryRunning ? "UDP ${config.discoveryPort} 已开" : "未启用（端口被占用或被关闭）"}');
    stdout.writeln('  根目录:');
    for (final root in config.roots) {
      stdout.writeln('    - ${root.displayName}  ${root.path}');
    }
    stdout.writeln('  配置: ${store.file.path}');
    stdout.writeln('');
    stdout.writeln('  按 Ctrl+C 停止。');
    stdout.writeln('');
  }

  // Ctrl+C 或托盘「退出」都会走到这里。
  final completer = Completer<void>();
  StreamSubscription<ProcessSignal>? sigint;
  sigint = ProcessSignal.sigint.watch().listen((_) async {
    if (!completer.isCompleted) completer.complete();
  });

  _shutdown = () {
    if (!completer.isCompleted) completer.complete();
  };

  await completer.future;
  await sigint.cancel();
  tray?.dispose();
  await server.stop();
  if (tray == null) stdout.writeln('已停止。');
}

/// 全局退出钩子，托盘菜单点「退出」时触发。
void Function()? _shutdown;

Future<void> _handleTrayCommand(
  int id,
  ServerConfig config,
  ConfigStore store,
  pavl.PavlServer server,
  String home,
) async {
  switch (id) {
    case TrayCommand.copyPin:
      // 服务端没有窗口，借 PowerShell 的 Set-Clipboard 写剪贴板；
      // 失败就退回到「打开浏览器」把 PIN 显示在页面上。
      final ok = await _copyToClipboard(config.pin);
      if (!ok) {
        stderr.writeln('复制 PIN 失败，PIN 为 ${config.pin}');
      }
    case TrayCommand.openBrowser:
      await _openUrl(home);
    case TrayCommand.openDataDir:
      await _openUrl(store.file.parent.path);
    case TrayCommand.regeneratePin:
      config.pin = _generatePin();
      await store.save(config);
      await server.reloadAuth();
    case TrayCommand.exit:
      _shutdown?.call();
  }
}

/// 写系统剪贴板。
Future<bool> _copyToClipboard(String text) async {
  if (!Platform.isWindows) return false;
  try {
    final escaped = text.replaceAll("'", "''");
    final result = await Process.run('powershell', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      "Set-Clipboard -Value '$escaped'",
    ]);
    return result.exitCode == 0;
  } on ProcessException {
    return false;
  }
}

/// 用系统默认程序打开 URL 或目录。
///
/// 必须 detached：`cmd /c start` 会一直等到浏览器退出才返回，
/// 托盘菜单就会卡住。
Future<void> _openUrl(String target) async {
  if (!Platform.isWindows) return;
  try {
    await Process.start(
      'cmd',
      ['/c', 'start', '', target],
      mode: ProcessStartMode.detached,
    );
  } on ProcessException {
    // 打不开就算了，用户还能自己复制地址。
  }
}

class _Options {
  int? port;
  String? name;
  String? pin;
  final List<String> roots = [];
  bool printConfig = false;
  bool resetPin = false;

  /// 是否用托盘模式。默认开，`--console` 关掉。
  bool tray = true;
}

_Options? _parseArgs(List<String> args) {
  final options = _Options();
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    switch (arg) {
      case '-h':
      case '--help':
        return null;
      case '--print-config':
        options.printConfig = true;
      case '--reset-pin':
        options.resetPin = true;
      case '--console':
        options.tray = false;
      case '--port':
        if (i + 1 >= args.length) return null;
        options.port = int.tryParse(args[++i]);
        if (options.port == null) return null;
      case '--name':
        if (i + 1 >= args.length) return null;
        options.name = args[++i];
      case '--pin':
        if (i + 1 >= args.length) return null;
        options.pin = args[++i];
      case '--root':
        if (i + 1 >= args.length) return null;
        options.roots.add(args[++i]);
      default:
        stderr.writeln('未知参数: $arg');
        return null;
    }
  }
  return options;
}

void _printUsage() {
  stdout.writeln('PAVL 服务端 v${pavl.pavlVersion}');
  stdout.writeln('');
  stdout.writeln('用法: pavl [选项]');
  stdout.writeln('');
  stdout.writeln('  --root <路径>      追加媒体根目录，可重复');
  stdout.writeln('  --port <端口>      覆盖 HTTP 端口，默认 8765');
  stdout.writeln('  --name <名称>      覆盖局域网显示名');
  stdout.writeln('  --pin <PIN>        覆盖配对 PIN');
  stdout.writeln('  --reset-pin        重新生成 PIN');
  stdout.writeln('  --console          控制台模式，不缩到通知区域');
  stdout.writeln('  --print-config     打印当前配置');
  stdout.writeln('  -h, --help         显示本帮助');
}

String _describe(ServerConfig config, String configPath) {
  final buffer = StringBuffer();
  buffer.writeln('配置文件: $configPath');
  buffer.writeln('名称: ${config.serverName}');
  buffer.writeln('端口: ${config.port}');
  buffer.writeln('PIN : ${config.pin.isEmpty ? "(未设置)" : config.pin}');
  buffer.writeln('绑定: ${config.bindAddress}');
  buffer.writeln('发现: ${config.enableDiscovery ? "开" : "关"} @ ${config.discoveryPort}');
  buffer.writeln('根目录:');
  if (config.roots.isEmpty) {
    buffer.writeln('  (无)');
  } else {
    for (final root in config.roots) {
      buffer.writeln('  ${root.displayName}\t${root.path}');
    }
  }
  return buffer.toString();
}

String _generatePin() => AuthStore.generatePin();

/// 取一个能展示给用户的局域网地址。
///
/// 只做展示用；真正监听的是 0.0.0.0，客户端能连上任意一个网卡地址。
Future<String> _localAddress() async {
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    final candidates = <String>[];
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        candidates.add(address.address);
      }
    }
    // 优先 192.168 / 10. / 172.16-31 这些常见内网段。
    int score(String ip) {
      if (ip.startsWith('192.168.')) return 0;
      if (ip.startsWith('10.')) return 1;
      if (ip.startsWith('172.')) return 2;
      return 3;
    }

    candidates.sort((a, b) => score(a).compareTo(score(b)));
    if (candidates.isNotEmpty) return candidates.first;
  } on Exception {
    // 拿不到就退回 localhost。
  }
  return '127.0.0.1';
}
