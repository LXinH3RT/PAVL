/// PAVL 服务端配置。
///
/// 端口、根目录、PIN 等全部走这一个文件，便于用户手工编辑。
///
/// 数据目录分两种形态，见 [StorageMode]：
///   - 便携版：`<程序目录>/PAVL-data/config.json`，整个文件夹拷走即搬家；
///   - 安装版：`%APPDATA%/PAVL/config.json`（Windows）或
///     `~/.config/pavl/config.json`。
library;

import 'dart:convert';
import 'dart:io';

import 'scrape/settings.dart';

/// 便携版数据目录名，与客户端保持一致。
const String portableDirName = 'PAVL-data';

/// 服务端数据的存放形态。
///
/// 判定的是「程序目录能不能写」，而不是「有没有安装程序」：本项目的服务端
/// 从来只有一个 exe，所谓安装版只是被放到了 Program Files 这类只读位置。
enum StorageMode {
  /// 程序目录可写：数据跟着程序走，删目录即卸载。
  portable('portable'),

  /// 程序目录不可写：数据放系统的用户配置目录。
  installed('installed');

  const StorageMode(this.wireName);

  /// 出现在 `/api/v1/info` 里的字面量。
  ///
  /// 客户端据此决定「播放偏好存客户端还是存服务端」，所以这两个值是对外
  /// 契约的一部分，不能随意改动。
  final String wireName;
}

/// 解析出来的数据目录及其形态。
class ConfigLocation {
  const ConfigLocation(this.dir, this.mode);

  final Directory dir;
  final StorageMode mode;
}

ConfigLocation? _resolvedLocation;

/// 当前进程的数据存放形态。
StorageMode get storageMode => resolveLocation().mode;

/// 解析数据目录与形态，结果进程内缓存。
///
/// 顺序：`PAVL_DATA_DIR` 环境变量 → 程序目录旁的 `PAVL-data/`（可写则用）
/// → 用户配置目录。
///
/// 开发时用 `dart run bin/pavl.dart` 启动，`resolvedExecutable` 指向 Dart SDK
/// 里的 dart.exe，旁边当然可写——但那是 SDK 自己的 bin 目录，配置写进去既
/// 污染 SDK，换台机器也找不到。所以由解释器启动的进程一律按安装版处理。
ConfigLocation resolveLocation() {
  final cached = _resolvedLocation;
  if (cached != null) return cached;
  final resolved = _resolveLocationUncached();
  _resolvedLocation = resolved;
  return resolved;
}

ConfigLocation _resolveLocationUncached() {
  final override = Platform.environment['PAVL_DATA_DIR'];
  if (override != null && override.isNotEmpty) {
    final dir = Directory(override);
    if (_ensureWritable(dir)) {
      return ConfigLocation(dir, StorageMode.portable);
    }
  }

  if (!_launchedByInterpreter()) {
    final exeDir = File(Platform.resolvedExecutable).parent;
    final portable =
        Directory('${exeDir.path}${Platform.pathSeparator}$portableDirName');
    if (_ensureWritable(portable)) {
      _migrateLegacyData(portable);
      return ConfigLocation(portable, StorageMode.portable);
    }
  }

  return ConfigLocation(legacyConfigDir(), StorageMode.installed);
}

/// 安装版的用户配置目录：`%APPDATA%/PAVL`、`$XDG_CONFIG_HOME/pavl` 等。
Directory legacyConfigDir() {
  final appData = Platform.environment['APPDATA'];
  if (Platform.isWindows && appData != null && appData.isNotEmpty) {
    return Directory('$appData${Platform.pathSeparator}PAVL');
  }
  final xdg = Platform.environment['XDG_CONFIG_HOME'];
  if (xdg != null && xdg.isNotEmpty) {
    return Directory('$xdg${Platform.pathSeparator}pavl');
  }
  final home = Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      Directory.current.path;
  return Directory(
      '$home${Platform.pathSeparator}.config${Platform.pathSeparator}pavl');
}

/// 老版本放在用户配置目录里的那几个文件。
const List<String> _migratedFiles = [
  'config.json',
  'devices.json',
  'progress.json',
  'prefs.json',
  'meta.json',
];

/// 首次以便携形态启动时，把用户配置目录里的数据搬过来。
///
/// 只搬目标不存在的文件，所以重复启动不会覆盖已经在用的便携数据；旧文件
/// 保留不删，用户退回旧版本时配对状态与进度还在。
void _migrateLegacyData(Directory target) {
  try {
    final legacy = legacyConfigDir();
    if (!legacy.existsSync()) return;
    for (final name in _migratedFiles) {
      final source = File('${legacy.path}${Platform.pathSeparator}$name');
      final dest = File('${target.path}${Platform.pathSeparator}$name');
      if (!source.existsSync() || dest.existsSync()) continue;
      source.copySync(dest.path);
    }
  } on FileSystemException {
    // 迁移失败就当没有旧数据，用默认配置起步。
  }
}

/// 进程是不是由 Dart 解释器拉起（开发调试）。
bool _launchedByInterpreter() {
  final name = Platform.resolvedExecutable
      .replaceAll(r'\', '/')
      .split('/')
      .last
      .toLowerCase();
  return name == 'dart' ||
      name == 'dart.exe' ||
      name == 'dartaotruntime' ||
      name == 'dartaotruntime.exe';
}

/// 建目录并写一个探针文件，确认真的能写。
bool _ensureWritable(Directory dir) {
  try {
    dir.createSync(recursive: true);
    final probe = File('${dir.path}${Platform.pathSeparator}.writable');
    probe.writeAsStringSync('');
    probe.deleteSync();
    return true;
  } on FileSystemException {
    return false;
  }
}

/// 一个媒体根目录。
class RootDir {
  RootDir({required this.path, this.name = ''});

  /// 绝对路径。
  final String path;

  /// 展示名，空则用路径最后一段。
  String name;

  String get displayName {
    if (name.isNotEmpty) return name;
    final normalized = path.replaceAll('\\', '/');
    final trimmed = normalized.endsWith('/')
        ? normalized.substring(0, normalized.length - 1)
        : normalized;
    final idx = trimmed.lastIndexOf('/');
    return idx < 0 ? trimmed : trimmed.substring(idx + 1);
  }

  Map<String, Object?> toJson() => {'path': path, 'name': name};

  static RootDir? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final path = raw['path'];
    if (path is! String || path.trim().isEmpty) return null;
    final name = raw['name'];
    return RootDir(path: path, name: name is String ? name : '');
  }
}

/// 服务端配置。
class ServerConfig {
  ServerConfig({
    this.port = 8765,
    this.serverName = 'PAVL',
    this.pin = '',
    this.serverId = '',
    this.bindAddress = '0.0.0.0',
    List<RootDir>? roots,
    this.enableDiscovery = true,
    this.discoveryPort = 45789,
    this.hideEmptyDirs = true,
    this.scrape = const ScrapeSettings(),
  }) : roots = roots ?? <RootDir>[];

  /// HTTP 监听端口。
  int port;

  /// 局域网内显示的名字。
  String serverName;

  /// 配对 PIN。空表示未设置，首次启动自动生成。
  String pin;

  /// 服务器唯一标识，首次启动生成，用于多服务器区分。
  String serverId;

  /// 监听地址。0.0.0.0 表示所有网卡。
  String bindAddress;

  /// 媒体根目录列表。
  final List<RootDir> roots;

  /// 是否启用 UDP 广播发现。
  bool enableDiscovery;

  /// UDP 发现端口。
  int discoveryPort;

  /// 浏览目录时是否隐藏「子树里没有任何视频/音频」的目录。
  ///
  /// 默认开启：与影片混放在同一个根目录下的软件目录、资料目录不会出现在
  /// 客户端列表里。想看到完整文件树时可关掉。
  bool hideEmptyDirs;

  /// 刮削配置：是否联网找影片信息、用哪几个来源。
  ///
  /// 刮削是在服务端做的：客户端只负责显示。关掉之后服务端不再发起任何外部
  /// 请求，已经刮到的记录仍然留在 `scrape.json` 里。
  ScrapeSettings scrape;

  Map<String, Object?> toJson() => {
        'port': port,
        'serverName': serverName,
        'pin': pin,
        'serverId': serverId,
        'bindAddress': bindAddress,
        'roots': roots.map((r) => r.toJson()).toList(),
        'enableDiscovery': enableDiscovery,
        'discoveryPort': discoveryPort,
        'hideEmptyDirs': hideEmptyDirs,
        'scrape': scrape.toJson(),
      };

  static ServerConfig fromJson(Map<String, Object?> json) {
    final roots = <RootDir>[];
    final rawRoots = json['roots'];
    if (rawRoots is List) {
      for (final item in rawRoots) {
        final root = RootDir.fromJson(item);
        if (root != null) roots.add(root);
      }
    }
    return ServerConfig(
      port: _asInt(json['port'], 8765),
      serverName: _asString(json['serverName'], 'PAVL'),
      pin: _asString(json['pin'], ''),
      serverId: _asString(json['serverId'], ''),
      bindAddress: _asString(json['bindAddress'], '0.0.0.0'),
      roots: roots,
      enableDiscovery: json['enableDiscovery'] is bool
          ? json['enableDiscovery']! as bool
          : true,
      discoveryPort: _asInt(json['discoveryPort'], 45789),
      hideEmptyDirs: json['hideEmptyDirs'] is bool
          ? json['hideEmptyDirs']! as bool
          : true,
      scrape: ScrapeSettings.fromJson(json['scrape']),
    );
  }

  static int _asInt(Object? value, int fallback) {
    if (value is int) return value;
    if (value is String) return int.tryParse(value) ?? fallback;
    if (value is double) return value.toInt();
    return fallback;
  }

  static String _asString(Object? value, String fallback) =>
      value is String ? value : fallback;
}

/// 配置文件的读写。
class ConfigStore {
  ConfigStore(this.file);

  final File file;

  /// 数据目录：便携版在程序目录旁，安装版在用户配置目录。
  ///
  /// 所有按文件名落盘的存储（配置、设备、进度、偏好、元数据）都从这里取
  /// 目录，所以形态判定只需要做一次。
  static Directory resolveConfigDir() => resolveLocation().dir;

  static ConfigStore defaultStore() => ConfigStore(
      File('${resolveConfigDir().path}${Platform.pathSeparator}config.json'));

  /// 读取配置；不存在时返回默认值并写盘。
  Future<ServerConfig> load() async {
    if (!await file.exists()) {
      final config = ServerConfig();
      await save(config);
      return config;
    }
    final text = await file.readAsString();
    if (text.trim().isEmpty) {
      final config = ServerConfig();
      await save(config);
      return config;
    }
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, Object?>) {
        return ServerConfig.fromJson(decoded);
      }
      if (decoded is Map) {
        return ServerConfig.fromJson(decoded.cast<String, Object?>());
      }
    } on FormatException {
      // 配置损坏时保留原文件，另存一份备份后回落到默认值。
      await file.copy('${file.path}.broken');
    }
    final config = ServerConfig();
    await save(config);
    return config;
  }

  /// 原子写入：先写临时文件再 rename，避免断电留下半个文件。
  Future<void> save(ServerConfig config) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(config.toJson()),
      flush: true,
    );
    await tmp.rename(file.path);
  }
}
