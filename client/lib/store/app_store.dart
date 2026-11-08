/// 本地持久化：服务器列表、设备身份、每部片的音轨字幕偏好。
///
/// 用 JSON 文件存，不引第三方依赖。位置在系统的应用数据目录下，
/// 卸载应用时不会被一并删除，重装后配对状态还在。
library;

import 'dart:convert';
import 'dart:io';

import '../api/pavl_client.dart';

/// 应用数据目录。
Directory appDataDir() {
  final env = Platform.environment;
  final String base;
  if (Platform.isWindows) {
    base = env['APPDATA'] ?? env['LOCALAPPDATA'] ?? '.';
  } else if (Platform.isMacOS) {
    base = '${env['HOME'] ?? '.'}/Library/Application Support';
  } else {
    base = env['XDG_CONFIG_HOME'] ?? '${env['HOME'] ?? '.'}/.config';
  }
  return Directory('$base${Platform.pathSeparator}PAVL');
}

/// 一部片的音轨字幕偏好。
class TrackPreference {
  TrackPreference({this.audioId, this.subtitleId, this.subtitlePath});

  /// 音轨 id，null 表示跟随文件默认。
  final String? audioId;

  /// 内嵌字幕轨 id，'no' 表示关闭。
  final String? subtitleId;

  /// 外挂字幕的服务器路径，优先于 [subtitleId]。
  final String? subtitlePath;

  Map<String, Object?> toJson() => {
        if (audioId != null) 'audioId': audioId,
        if (subtitleId != null) 'subtitleId': subtitleId,
        if (subtitlePath != null) 'subtitlePath': subtitlePath,
      };

  static TrackPreference fromJson(Map<String, Object?> json) => TrackPreference(
        audioId: json['audioId'] as String?,
        subtitleId: json['subtitleId'] as String?,
        subtitlePath: json['subtitlePath'] as String?,
      );
}

/// 应用配置。
class AppStore {
  AppStore._(this._file);

  final File _file;

  /// 设备唯一 id，首次启动生成后固定不变。
  String deviceId = '';
  String deviceName = '';

  /// 已保存的服务器。
  List<ServerConnection> servers = [];

  /// 上次选中的服务器 id。
  String? lastServerId;

  /// 每部片的音轨字幕偏好，键是服务器 id + 片路径。
  Map<String, TrackPreference> trackPreferences = {};

  /// 进度模式：true 用服务端跨设备进度，false 只用本机记录。
  bool crossDeviceProgress = false;

  static AppStore? _instance;

  /// 载入单例。
  static Future<AppStore> load() async {
    final cached = _instance;
    if (cached != null) return cached;

    final dir = appDataDir();
    await dir.create(recursive: true);
    final file = File('${dir.path}${Platform.pathSeparator}client.json');
    final store = AppStore._(file);
    await store._read();
    _instance = store;
    return store;
  }

  Future<void> _read() async {
    Map<String, Object?> json = {};
    if (await _file.exists()) {
      try {
        final decoded = jsonDecode(await _file.readAsString());
        if (decoded is Map) json = decoded.cast<String, Object?>();
      } on FormatException {
        // 文件损坏时从空配置开始，不阻断启动。
      }
    }

    deviceId = json['deviceId'] as String? ?? _newDeviceId();
    deviceName = json['deviceName'] as String? ?? Platform.localHostname;
    lastServerId = json['lastServerId'] as String?;
    crossDeviceProgress = json['crossDeviceProgress'] as bool? ?? false;

    final rawServers = json['servers'];
    if (rawServers is List) {
      servers = rawServers
          .whereType<Map>()
          .map((e) => ServerConnection.fromJson(e.cast<String, Object?>()))
          .toList();
    }

    final rawPrefs = json['trackPreferences'];
    if (rawPrefs is Map) {
      rawPrefs.forEach((key, value) {
        if (key is String && value is Map) {
          trackPreferences[key] =
              TrackPreference.fromJson(value.cast<String, Object?>());
        }
      });
    }

    // 首次运行生成了新 id，立刻落盘，避免每次启动都变。
    if (json['deviceId'] != deviceId) await save();
  }

  static String _newDeviceId() {
    // 用时间戳 + 随机数拼一个足够唯一的 id，不引入 uuid 依赖。
    final now = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    final random = now.hashCode.toRadixString(16).padLeft(8, '0');
    return '$now-$random';
  }

  Future<void> save() async {
    final json = <String, Object?>{
      'deviceId': deviceId,
      'deviceName': deviceName,
      if (lastServerId != null) 'lastServerId': lastServerId,
      'crossDeviceProgress': crossDeviceProgress,
      'servers': servers.map((e) => e.toJson()).toList(),
      'trackPreferences': trackPreferences.map(
        (key, value) => MapEntry(key, value.toJson()),
      ),
    };
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(jsonEncode(json), flush: true);
    await tmp.rename(_file.path);
  }

  /// 偏好键。
  static String prefKey(String serverId, String path) => '$serverId::$path';

  /// 记录一部片的音轨字幕选择。
  Future<void> setTrackPreference(
    String serverId,
    String path,
    TrackPreference pref,
  ) async {
    trackPreferences[prefKey(serverId, path)] = pref;
    await save();
  }

  TrackPreference? trackPreference(String serverId, String path) =>
      trackPreferences[prefKey(serverId, path)];

  /// 写入或更新一台服务器。
  Future<void> upsertServer(ServerConnection connection) async {
    final index = servers.indexWhere((e) => e.serverId == connection.serverId);
    if (index >= 0) {
      servers[index] = connection;
    } else {
      servers.add(connection);
    }
    lastServerId = connection.serverId;
    await save();
  }

  /// 按 id 找服务器。
  ServerConnection? serverById(String? id) {
    if (id == null) return null;
    for (final server in servers) {
      if (server.serverId == id) return server;
    }
    return null;
  }

  /// 上次使用的服务器。
  ServerConnection? get lastServer => serverById(lastServerId);

  /// 删除一台服务器。
  Future<void> removeServer(String serverId) async {
    servers.removeWhere((e) => e.serverId == serverId);
    if (lastServerId == serverId) lastServerId = null;
    await save();
  }
}
