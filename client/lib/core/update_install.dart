/// 把下载好的更新包铺到安装目录，并把自己的进程换成新版本。
///
/// 难点只有一条：**Windows 上运行中的 exe 不能被覆盖**。所以更换本体必须由
/// 一个「不在被替换位置上」的进程来做。这里的做法是：
///
/// 1. 旧进程把 zip 解到 `PAVL-data/update/staged-<版本>/`；
/// 2. 把待办写进 `pending.json`，然后拉起 staged 里的新本体，传
///    `--apply-update=<标记文件>`；
/// 3. 新本体启动后先不初始化界面，等旧进程退出（轮询能否改名），再把文件
///    逐个铺进安装目录，最后从安装目录正常启动、自己退出。
///
/// 这样做不需要批处理脚本、不会闪控制台，也不依赖用户点确认。macOS 的
/// `.app` 是一个整体，用系统自带的 `ditto` 连符号链接一起搬，避免手写复制把
/// framework 里的软链变成本体文件。
library;

import 'dart:convert';
import 'dart:io';

import '../util/app_log.dart';
import 'update_service.dart';

/// 命令行约定：新本体被拉起时带这个前缀做自我替换。
const String applyUpdateFlag = "--apply-update=";

/// 环境变量约定：与命令行等价，值同样指向标记文件。
///
/// macOS 的 Flutter 模板不会把 argv 传给 Dart 入口（`FlutterViewController()`
/// 默认不设置 `dartEntrypointArguments`），所以那边只能走环境变量。两个通道
/// 都认，调用方按平台顺手挑一个。
const String applyUpdateEnvKey = "PAVL_APPLY_UPDATE";

/// 待办标记：谁铺到哪、铺完启动什么。
class PendingUpdate {
  const PendingUpdate({
    required this.stagedRoot,
    required this.installRoot,
    required this.launchPath,
  });

  /// 解压出来的那份新版本所在目录（Windows 是含 exe 的那个文件夹，
  /// macOS 是 .app 的父目录）。
  final String stagedRoot;

  /// 要铺进去的安装目录。
  final String installRoot;

  /// 铺完之后启动哪个可执行文件。
  final String launchPath;

  Map<String, Object?> toJson() => {
    "stagedRoot": stagedRoot,
    "installRoot": installRoot,
    "launchPath": launchPath,
  };

  static PendingUpdate? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final staged = raw["stagedRoot"];
    final install = raw["installRoot"];
    final launch = raw["launchPath"];
    if (staged is! String || install is! String || launch is! String) {
      return null;
    }
    return PendingUpdate(
      stagedRoot: staged,
      installRoot: install,
      launchPath: launch,
    );
  }

  static File get markerFile =>
      File(joinPath(updateDownloadsDir().path, "pending.json"));

  Future<void> write() async {
    await markerFile.parent.create(recursive: true);
    await markerFile.writeAsString(jsonEncode(toJson()), flush: true);
  }

  static Future<PendingUpdate?> read() async {
    final file = markerFile;
    if (!await file.exists()) return null;
    try {
      return fromJson(jsonDecode(await file.readAsString()));
    } catch (error) {
      logLine("update", "读更新标记失败：$error");
      return null;
    }
  }

  static Future<void> clear() async {
    try {
      if (await markerFile.exists()) await markerFile.delete();
    } catch (error) {
      logLine("update", "清理更新标记失败：$error");
    }
  }
}

/// 解压 zip。用系统自带工具，避免在客户端里塞一个 zip 解码器。
///
/// Windows 的 `tar.exe`（bsdtar）从 Win10 1803 起随系统提供；macOS 用
/// `ditto`，它是唯一能完整保留 .app 内符号链接与权限的现成工具。
Future<void> extractZip(File zip, Directory target) async {
  await target.create(recursive: true);
  final ProcessResult result;
  if (Platform.isWindows) {
    result = await Process.run("tar", ["-xf", zip.path, "-C", target.path]);
  } else if (Platform.isMacOS) {
    result = await Process.run("ditto", ["-x", "-k", zip.path, target.path]);
  } else {
    result = await Process.run("unzip", [
      "-q",
      "-o",
      zip.path,
      "-d",
      target.path,
    ]);
  }
  if (result.exitCode != 0) {
    throw UpdateException(
      "解压失败：${result.stderr.toString().trim()}",
      code: "install",
    );
  }
}

/// 广度优先找第一个满足条件的路径，最多看两层。找不到返回 null。
String? _findPath(
  Directory root,
  bool Function(FileSystemEntity) test, {
  int maxDepth = 2,
}) {
  final queue = <(Directory, int)>[(root, 0)];
  var guard = 0;
  while (queue.isNotEmpty && guard < 2000) {
    guard++;
    final (dir, depth) = queue.removeAt(0);
    final List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false);
    } catch (_) {
      continue;
    }
    for (final entry in entries) {
      if (test(entry)) return entry.path;
      if (entry is Directory && depth < maxDepth) {
        queue.add((entry, depth + 1));
      }
    }
  }
  return null;
}

bool _isExe(FileSystemEntity entity) {
  if (entity is! File) return false;
  final lower = entity.path.toLowerCase();
  return lower.endsWith("pavl_client.exe") || lower.endsWith("pavl.exe");
}

bool _isApp(FileSystemEntity entity) =>
    entity is Directory && entity.path.toLowerCase().endsWith(".app");

/// `.app` 里真正的可执行文件：`Contents/MacOS/<AppName>`。
String _macExecutableIn(String appPath) {
  final name = appPath
      .split(Platform.pathSeparator)
      .where((segment) => segment.isNotEmpty)
      .last;
  final bare = name.toLowerCase().endsWith(".app")
      ? name.substring(0, name.length - 4)
      : name;
  return joinPath(joinPath(joinPath(appPath, "Contents"), "MacOS"), bare);
}

/// 在解压结果里找到真正要用的那一层。
///
/// 包里套着一层 `PAVL_windows_client_portable_0.2.4/`，所以要往下找。
String findPayloadRoot(Directory staged) {
  if (Platform.isMacOS) {
    final app = _findPath(staged, _isApp);
    if (app == null) throw UpdateException("更新包里没有找到 .app。", code: "install");
    return Directory(app).parent.path;
  }
  final exe = _findPath(staged, _isExe);
  if (exe == null) {
    throw UpdateException("更新包里没有找到主程序。", code: "install");
  }
  return File(exe).parent.path;
}

/// 从可执行文件路径反推它所属的 `.app`（含 `.app` 这一段）。
///
/// `.../PAVL.app/Contents/MacOS/PAVL` → `.../PAVL.app`。找不到就返回 null。
String? _appOfLaunchPath(String launchPath) {
  final parts = launchPath.split(Platform.pathSeparator);
  for (var i = parts.length - 1; i >= 0; i--) {
    if (parts[i].toLowerCase().endsWith(".app")) {
      return parts.take(i + 1).join(Platform.pathSeparator);
    }
  }
  return null;
}

/// 当前正在运行的这个 `.app` 本身（不是它的父目录）。
///
/// 换包时必须精确认它：安装目录常常就是 `/Applications`，里面装着几十个
/// 程序，靠「扫第一个 .app」去认会认到别人的应用。
String? currentAppPath() => _appOfLaunchPath(Platform.resolvedExecutable);

/// 当前本体所在的安装目录。
///
/// Windows 是 exe 所在的那个文件夹；macOS 要往上找到 `.app` 的**父目录**
/// ——`resolvedExecutable` 落在 `PAVL.app/Contents/MacOS/PAVL`，直接取 parent
/// 会拿到 `Contents/MacOS`，换 `.app` 时就换错了层级。
String installRootOf() {
  final exe = File(Platform.resolvedExecutable);
  if (!Platform.isMacOS) return exe.parent.path;
  var dir = exe.parent;
  while (true) {
    if (dir.path.toLowerCase().endsWith(".app")) return dir.parent.path;
    final parent = dir.parent;
    if (parent.path == dir.path) return exe.parent.path;
    dir = parent;
  }
}

/// 安装目录里那个该被启动的可执行文件。
String launcherIn(String installRoot) {
  if (Platform.isMacOS) {
    // 只认「当前正在跑的那个 .app」，不扫安装目录：`/Applications` 里第一个
    // 命中的可能是 AdGuard 或者 Edge。
    final app = currentAppPath();
    if (app != null && Directory(app).parent.path == installRoot) {
      return _macExecutableIn(app);
    }
    // 认不出来的情况（例如已经在 staged 目录里）就当安装目录本身是 .app。
    return _macExecutableIn(installRoot);
  }
  final exe = _findPath(Directory(installRoot), _isExe, maxDepth: 0);
  if (exe != null) return exe;
  return Platform.resolvedExecutable;
}

/// 解开、定位、写标记，然后拉起 staged 里的新本体。
///
/// 调用方拿到之后要立刻退出进程——新本体正在等着接管。
Future<void> beginApply({required File zip, required String version}) async {
  final updateDir = updateDownloadsDir();
  final staged = Directory(joinPath(updateDir.path, "staged-$version"));
  if (await staged.exists()) await staged.delete(recursive: true);
  await extractZip(zip, staged);

  final payload = findPayloadRoot(staged);
  final install = installRootOf();
  final launchPath = launcherIn(install);

  final pending = PendingUpdate(
    stagedRoot: payload,
    installRoot: install,
    launchPath: launchPath,
  );
  // 先落标记：就地替换中途断电，下次启动还能靠它或者手动解压救回来。
  await pending.write();

  logLine("update", "开始就地替换：$payload → $install");
  try {
    await _replace(pending);
  } catch (error) {
    // 就地替换救不回来时，退回「交给新本体接管」这条路。
    logLine("update", "就地替换失败，改为交给新本体接管：$error");
    await _spawnTakeover(payload);
    return;
  }
  await PendingUpdate.clear();

  // 启动的必须是**安装目录里**的那份：stage 在 update 缓存里，下次清理
  // 缓存就把自己删了。
  logLine("update", "新版本已就位，启动 $launchPath");
  await Process.start(
    launchPath,
    const <String>[],
    mode: ProcessStartMode.detached,
    workingDirectory: install,
  );
}

/// 兜底：拉起 stage 里的新本体，让它来铺文件。
///
/// 只在就地替换失败时才走。这条路的代价是**旧版本必须懂**
/// `--apply-update`——0.2.3 之前的版本并不懂，所以它只能当兜底，
/// 不能当主路径。
Future<void> _spawnTakeover(String payload) async {
  final takeover = Platform.isMacOS
      ? _macExecutableIn(_findPath(Directory(payload), _isApp) ?? payload)
      : File(_findPath(Directory(payload), _isExe) ?? launcherIn(payload)).path;
  final marker = PendingUpdate.markerFile.path;
  logLine("update", "交给新本体接管：$takeover");
  await Process.start(
    takeover,
    // macOS 的 Dart 入口拿不到 argv，所以那边只能靠环境变量传标记。
    Platform.isMacOS ? const <String>[] : ["$applyUpdateFlag$marker"],
    mode: ProcessStartMode.detached,
    environment: Platform.isMacOS
        ? {applyUpdateEnvKey: marker}
        : const <String, String>{},
  );
}

/// 如果带着更新标记，就做替换并结束进程。
///
/// 标记可以来自命令行（`--apply-update=`），也可以来自环境变量
/// `PAVL_APPLY_UPDATE`——macOS 的 Flutter 模板不传 argv，只能用后者。
///
/// 返回 true 表示已经接管过、调用方不要再往下初始化界面。
Future<bool> applyPendingIfRequested(List<String> args) async {
  String? marker;
  for (final arg in args) {
    if (arg.startsWith(applyUpdateFlag)) {
      marker = arg.substring(applyUpdateFlag.length);
    }
  }
  final fromEnv = Platform.environment[applyUpdateEnvKey];
  if (marker == null && fromEnv != null && fromEnv.isNotEmpty) {
    marker = fromEnv;
  }
  if (marker == null) return false;

  final pending = await _readMarker(marker);
  if (pending == null) {
    logLine("update", "更新标记读不出来，放弃接管");
    return false;
  }

  logLine("update", "接管更新，等待旧进程退出");
  try {
    await _waitUntilReplaceable(pending.installRoot);
    await _replace(pending);
    await PendingUpdate.clear();
    logLine("update", "新版本已就位，启动 ${pending.launchPath}");
    await Process.start(
      pending.launchPath,
      const <String>[],
      mode: ProcessStartMode.detached,
      workingDirectory: pending.installRoot,
    );
    exit(0);
  } catch (error) {
    logLine("update", "替换失败：$error");
    // 失败时保留 staged 与标记，用户手动解压也能救回来。
    exit(1);
  }
}

Future<PendingUpdate?> _readMarker(String path) async {
  try {
    final file = File(path);
    if (!await file.exists()) return null;
    return PendingUpdate.fromJson(jsonDecode(await file.readAsString()));
  } catch (error) {
    logLine("update", "读更新标记失败：$error");
    return null;
  }
}

/// 等到安装目录里的主程序不再被占用。
///
/// 旧进程退出需要一点时间（要关播放器、写配置）。用「改名再改回来」当探针：
/// 能改名说明文件句柄已经放开，也就是旧进程真的走了。
Future<void> _waitUntilReplaceable(String installRoot) async {
  if (Platform.isMacOS) {
    // .app 换的是整个目录，改名不受占用限制。
    await Future<void>.delayed(const Duration(milliseconds: 800));
    return;
  }
  final exe = launcherIn(installRoot);
  final probe = "$exe.probe";
  final deadline = DateTime.now().add(const Duration(seconds: 60));
  while (DateTime.now().isBefore(deadline)) {
    try {
      File(exe).renameSync(probe);
      File(probe).renameSync(exe);
      return;
    } catch (_) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  }
  throw UpdateException("等待旧进程退出超时。", code: "install");
}

Future<void> _replace(PendingUpdate pending) async {
  if (Platform.isMacOS) {
    await _replaceMacApp(pending);
    return;
  }
  await _copyTree(
    Directory(pending.stagedRoot),
    Directory(pending.installRoot),
  );
}

/// 覆盖式复制。`PAVL-data` 是用户自己的数据，绝不能覆盖。
Future<void> _copyTree(Directory source, Directory target) async {
  await for (final entity in source.list(followLinks: false)) {
    final name = entity.uri.pathSegments
        .where((segment) => segment.isNotEmpty)
        .last;
    if (name == "PAVL-data") continue;
    final dest = joinPath(target.path, name);
    if (entity is Directory) {
      await Directory(dest).create(recursive: true);
      await _copyTree(entity, Directory(dest));
    } else if (entity is File) {
      // 运行中的 exe 占着句柄，复制会失败——先把它改名腾位置。
      if (await File(dest).exists()) {
        try {
          await File(dest).delete();
        } catch (_) {
          final old = "$dest.old";
          try {
            await File(dest).rename(old);
          } catch (error) {
            logLine("update", "无法替换 $dest：$error");
            continue;
          }
        }
      }
      await entity.copy(dest);
    }
  }
}

/// macOS：整个 .app 换掉。先改名腾位置，再用 ditto 搬（保留符号链接）。
///
/// 要替换的 `.app` 从 `launchPath` 反推，**不能**去安装目录里扫第一个 `.app`
/// ——便携形态下安装目录可能就是 `/Applications`，扫出来的很可能是别人的程序。
Future<void> _replaceMacApp(PendingUpdate pending) async {
  final installApp = _appOfLaunchPath(pending.launchPath);
  if (installApp == null) {
    throw UpdateException("定位不到要替换的 .app。", code: "install");
  }
  final stagedApp = _findPath(Directory(pending.stagedRoot), _isApp);
  if (stagedApp == null) {
    throw UpdateException("更新包里没有找到 .app。", code: "install");
  }
  final backup = "$installApp.old";
  if (await Directory(backup).exists()) {
    await Directory(backup).delete(recursive: true);
  }
  if (await Directory(installApp).exists()) {
    await Directory(installApp).rename(backup);
  }
  final result = await Process.run("ditto", [stagedApp, installApp]);
  if (result.exitCode != 0) {
    throw UpdateException(
      "复制 .app 失败：${result.stderr.toString().trim()}",
      code: "install",
    );
  }
  try {
    await Directory(backup).delete(recursive: true);
  } catch (error) {
    logLine("update", "旧版本残留删不掉：$error");
  }
}

/// 数据目录里那个放更新包的子目录，供界面显示「已下载多少」用。
Directory get downloadsDirectory => updateDownloadsDir();
