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
import 'dart:isolate';

import 'package:pavl_server/auth.dart';
import 'package:pavl_server/config.dart';
import 'package:pavl_server/native_dialogs.dart';
import 'package:pavl_server/pavl_server.dart' as pavl;
import 'package:pavl_server/tray.dart';
import 'package:pavl_server/update.dart' as upd;

Future<void> main(List<String> args) async {
  // 托盘图标要按物理像素挑帧，所以进程启动时就声明 DPI 感知。
  enableDpiAwareness();

  // 自己更新时新本体是被旧进程拉起来的，只负责铺文件、换启动目录，不起服务。
  if (await upd.applyPendingIfRequested(args)) return;

  final options = _parseArgs(args);
  if (options == null) {
    _printUsage();
    exitCode = 2;
    return;
  }

  final store = ConfigStore.defaultStore();
  final config = await store.load();

  // 上次更新可能留下改名后的旧文件和解压产物，启动时清一次。
  // 下载中的 zip 不动，那是断点续传的依据。
  upd.cleanStaleFiles(File(Platform.resolvedExecutable).parent.path);
  upd.cleanStaleUpdateDirs(store.file.parent.path);

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
        TrayMenuItem.separator(),
        ..._rootMenuItems(config),
        TrayMenuItem(TrayCommand.addRoot, '添加共享目录…'),
        TrayMenuItem(TrayCommand.changeRoots, '更换共享目录…'),
        TrayMenuItem.separator(),
        TrayMenuItem(TrayCommand.regeneratePin, '重新生成 PIN（旧设备需重新配对）'),
        TrayMenuItem(TrayCommand.checkUpdate, '版本 v${pavl.pavlVersion} · 检查更新'),
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
    stdout.writeln(
        '  形态: ${storageMode == StorageMode.portable ? "便携版（数据跟着程序走）" : "安装版（数据在用户配置目录）"}');
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
    case TrayCommand.addRoot:
      await _pickAndAddRoot(config, store, server);
    case TrayCommand.changeRoots:
      await _pickAndReplaceRoots(config, store, server);
    case TrayCommand.regeneratePin:
      config.pin = _generatePin();
      await store.save(config);
      await server.reloadAuth();
    case TrayCommand.checkUpdate:
      await _checkUpdate(config, store);
    case TrayCommand.exit:
      _shutdown?.call();
    default:
      final index = TrayCommand.rootIndexFrom(id);
      if (index != null) await _removeRootAt(index, config, store, server);
  }
}

/// 每个已共享目录一行「停止共享」。
///
/// 托盘菜单是纯文本协议，做不了勾选式子菜单，所以平铺出来：目录少的时候
/// 这样反而一眼能看清一共有几个。
List<TrayMenuItem> _rootMenuItems(ServerConfig config) {
  if (config.roots.isEmpty) return const [];
  return [
    TrayMenuItem.info('共享目录'),
    for (var i = 0; i < config.roots.length; i++)
      TrayMenuItem(
        TrayCommand.removeRootBase + i,
        '停止共享：${config.roots[i].displayName}',
      ),
    TrayMenuItem.separator(),
  ];
}

/// 移除列表里第 [index] 个共享目录。
Future<void> _removeRootAt(
  int index,
  ServerConfig config,
  ConfigStore store,
  pavl.PavlServer server,
) async {
  if (index < 0 || index >= config.roots.length) return;
  final root = config.roots.removeAt(index);
  await store.save(config);
  await _afterRootsChanged(server);
  // 提示里只报「还剩几个在共享」。原来写「还可以共享 N 个目录」，
  // 中文读起来像在说配额上限，其实共享目录个数不限，只是每停一个就少一个。
  final remaining = config.roots.length;
  await _showMessageAsync(
    remaining == 0
        ? '已停止共享：\n${root.path}\n\n已经没有共享目录了，客户端会看到空列表。'
        : '已停止共享：\n${root.path}\n\n当前仍在共享 $remaining 个目录：'
            '${config.roots.map((r) => r.displayName).join('、')}',
  );
}

/// 弹文件夹选择框。放到独立 isolate 里跑，免得服务器在用户挑目录时整个卡住。
Future<String?> _pickFolderAsync(String title) async {
  try {
    return await Isolate.run(() => pickFolder(title: title));
  } on Object {
    // 起 isolate 失败就退回当前 isolate，至少功能还能用。
    return pickFolder(title: title);
  }
}

/// 弹提示框。同样不能占用主 isolate：MessageBoxW 会一直阻塞到用户点掉，
/// 期间 HTTP 服务会因为事件循环被卡住而没有任何响应。
Future<void> _showMessageAsync(
  String text, {
  String caption = 'PAVL',
  bool isError = false,
}) async {
  try {
    await Isolate.run(
      () => showMessage(text, caption: caption, isError: isError),
    );
  } on Object {
    // 提示框弹不出来不影响主流程。
  }
}

/// 弹一是/否确认框。同样放到独立 isolate，避免卡住 HTTP 服务。
Future<bool> _askConfirmAsync(
  String text, {
  String caption = 'PAVL',
  bool isWarning = false,
}) async {
  try {
    return await Isolate.run(
      () => askConfirm(text, caption: caption, isWarning: isWarning),
    );
  } on Object {
    return false;
  }
}

/// 检查更新：查 GitHub，有新版本就问一句，再下载并交给新本体接管。
///
/// 全程只有两个阻塞提示（结果 + 确认），网络请求在主 isolate 上跑。
Future<void> _checkUpdate(ServerConfig config, ConfigStore store) async {
  final dataDir = store.file.parent.path;
  upd.ReleaseInfo release;
  try {
    release = await upd.fetchLatestRelease();
  } on upd.UpdateException catch (error) {
    await _showMessageAsync(
      '检查更新失败：\n${error.message}',
      caption: 'PAVL 检查更新',
      isError: true,
    );
    return;
  }

  if (!upd.isNewerVersion(release.version)) {
    await _showMessageAsync(
      '已经是最新版本。\n\n当前 v${pavl.pavlVersion}，最新 ${release.version}。',
      caption: 'PAVL 检查更新',
    );
    return;
  }

  final asset = release.serverAsset;
  if (asset == null) {
    await _showMessageAsync(
      '最新版本是 ${release.version}，但这个版本没有服务端的包。\n\n'
      '去发布页看看：${upd.releasesPageUrl}',
      caption: 'PAVL 检查更新',
      isError: true,
    );
    return;
  }

  final go = await _askConfirmAsync(
    '发现新版本 ${release.version}（当前 v${pavl.pavlVersion}）。\n\n'
    '更新包：${asset.name}（${asset.sizeText}）\n'
    '更新会重启服务端，已配对的设备不用重新配对。\n\n'
    '现在下载并更新吗？',
    caption: 'PAVL 检查更新',
  );
  if (!go) return;

  File zip;
  try {
    zip = await upd.downloadAsset(asset, dataDir: dataDir);
  } on upd.UpdateException catch (error) {
    await _showMessageAsync(
      '下载失败：\n${error.message}',
      caption: 'PAVL 更新失败',
      isError: true,
    );
    return;
  }

  try {
    await upd.beginApply(
      zip: zip,
      version: release.version,
      dataDir: dataDir,
      installRoot: File(Platform.resolvedExecutable).parent.path,
    );
  } on upd.UpdateException catch (error) {
    await _showMessageAsync(
      '准备更新失败：\n${error.message}',
      caption: 'PAVL 更新失败',
      isError: true,
    );
    return;
  }

  // 新本体已经在等这个位置了，退出让位。
  _shutdown?.call();
}

/// 追加一个共享目录。
Future<void> _pickAndAddRoot(
  ServerConfig config,
  ConfigStore store,
  pavl.PavlServer server,
) async {
  final picked = await _pickFolderAsync('选择要共享的视频文件夹');
  if (picked == null || picked.isEmpty) return;

  if (config.roots.any((r) => _samePath(r.path, picked))) {
    await _showMessageAsync('这个文件夹已经在共享列表里了。');
    return;
  }
  config.roots.add(RootDir(path: picked));
  await store.save(config);
  await _afterRootsChanged(server);
  await _showMessageAsync('已开始共享：\n$picked');
}

/// 把共享目录换成新选的一个（原有的全部移除）。
Future<void> _pickAndReplaceRoots(
  ServerConfig config,
  ConfigStore store,
  pavl.PavlServer server,
) async {
  final picked = await _pickFolderAsync('选择要共享的视频文件夹');
  if (picked == null || picked.isEmpty) return;

  if (config.roots.length == 1 && _samePath(config.roots.first.path, picked)) {
    await _showMessageAsync('共享目录没有变化。');
    return;
  }
  config.roots
    ..clear()
    ..add(RootDir(path: picked));
  await store.save(config);
  await _afterRootsChanged(server);
  await _showMessageAsync(
    '共享目录已改为：\n$picked\n\n'
    '原来的目录不再对外提供，已配对的设备需要重新浏览。',
  );
}

/// 目录列表变了：清缓存并后台重扫，不用重启服务端。
Future<void> _afterRootsChanged(pavl.PavlServer server) async {
  server.library.invalidate();
  try {
    await server.library.refreshAll();
  } on Object catch (error) {
    stderr.writeln('重新扫描媒体库失败: $error');
  }
}

bool _samePath(String a, String b) {
  String norm(String value) {
    var out = value.replaceAll('\\', '/');
    while (out.endsWith('/')) {
      out = out.substring(0, out.length - 1);
    }
    return out.toLowerCase();
  }

  return norm(a) == norm(b);
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
  buffer.writeln(
      '存储形态: ${storageMode.wireName}'
      '${storageMode == StorageMode.portable ? "（数据跟着程序目录走）" : "（数据在用户配置目录）"}');
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
