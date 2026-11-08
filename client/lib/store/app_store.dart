/// 本地持久化：服务器列表、设备身份、每部片的音轨字幕偏好。
///
/// 用 JSON 文件存，不引第三方依赖。位置优先取可执行文件同级的
/// `PAVL-data/`（便携），该目录不可写时才退回系统的应用数据目录。
library;

import 'dart:convert';
import 'dart:io';

import '../api/pavl_client.dart';

/// 便携目录名：放在可执行文件旁边，整个文件夹拷走就能带着配对状态。
///
/// 不能叫 `data`：Flutter 自己的资源目录就叫 `data`（app.so、flutter_assets
/// 都在里面），混在一起容易被清理工具误删。
const String portableDirName = 'PAVL-data';

Directory? _resolvedDataDir;

/// 应用数据目录。
///
/// 优先用可执行文件同级的 `PAVL-data/`：便携版整包复制后配对状态、播放进度
/// 偏好、日志都跟着走，也不会因为用户配置目录不可写而失败。该目录建不出来
/// （装到只读位置、exe 放在 Program Files 下但没有权限）时，退回系统配置目录。
Directory appDataDir() {
  final cached = _resolvedDataDir;
  if (cached != null) return cached;

  final portable = Directory(
    '${File(Platform.resolvedExecutable).parent.path}'
    '${Platform.pathSeparator}$portableDirName',
  );
  if (_ensureWritable(portable)) {
    _resolvedDataDir = portable;
    return portable;
  }

  final legacy = legacyDataDir();
  try {
    legacy.createSync(recursive: true);
  } catch (_) {
    // 连系统配置目录都建不出来时只能退回临时目录，至少不让启动崩掉。
    _resolvedDataDir = Directory.systemTemp;
    return _resolvedDataDir!;
  }
  _resolvedDataDir = legacy;
  return legacy;
}

/// 旧版本的配置目录（%APPDATA%\PAVL 等）。
///
/// 只用于把老用户的 client.json 迁移到便携目录，不再作为主存储位置。
Directory legacyDataDir() {
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

/// 临时文件目录。
///
/// 不直接用 [Directory.systemTemp]：某些机器上 TEMP/TMP 没配好，Windows 会
/// 回退到 C:\WINDOWS\TEMP，普通用户写不进去。播放内核会在这个目录里建播放
/// 列表与字幕临时文件，写不进去就等于任何片都打不开。
Directory appTempDir() {
  final dir =
      Directory('${appDataDir().path}${Platform.pathSeparator}temp');
  try {
    dir.createSync(recursive: true);
  } catch (_) {
    // 建不出来时也返回路径，调用方自己去处理失败。
  }
  return dir;
}

bool _ensureWritable(Directory dir) {
  try {
    dir.createSync(recursive: true);
    final probe = File('${dir.path}${Platform.pathSeparator}.writable');
    probe.writeAsStringSync('', flush: false);
    probe.deleteSync();
    return true;
  } catch (_) {
    return false;
  }
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
    if (!await file.exists()) await _migrateLegacyConfig(file);
    final store = AppStore._(file);
    await store._read();
    _instance = store;
    return store;
  }

  /// 把老版本存在 %APPDATA%\PAVL 的配置搬到便携目录。
  ///
  /// 只在便携目录里还没有配置时搬一次；搬完保留旧文件不删，用户回退到老
  /// 版本时配对状态还在。
  static Future<void> _migrateLegacyConfig(File target) async {
    try {
      final legacy =
          File('${legacyDataDir().path}${Platform.pathSeparator}client.json');
      if (await legacy.exists()) {
        await target.writeAsString(await legacy.readAsString(), flush: true);
      }
    } catch (_) {
      // 迁移失败就当没有旧配置，用空配置起步。
    }
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
