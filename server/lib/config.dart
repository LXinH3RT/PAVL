/// PAVL 服务端配置。
///
/// 存储位置：%APPDATA%\PAVL\config.json（Windows）或 ~/.config/pavl/config.json。
/// 端口、根目录、PIN 等全部走这一个文件，便于用户手工编辑。
library;

import 'dart:convert';
import 'dart:io';

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

  /// 解析配置目录。优先 %APPDATA%，其次 XDG，最后 home。
  static Directory resolveConfigDir() {
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
    return Directory('$home${Platform.pathSeparator}.config'
        '${Platform.pathSeparator}pavl');
  }

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
