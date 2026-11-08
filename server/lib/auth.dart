/// 设备配对与令牌管理。
///
/// 设计要点：
/// - PIN 与 Windows 系统账号完全无关，改动 PIN 不影响任何设备。
/// - 配对成功后发一个随机令牌，客户端存系统凭据库，之后所有请求带令牌。
/// - 令牌按设备独立，可在服务端单独吊销某一台。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'config.dart';

/// 一台已配对设备。
class PairedDevice {
  PairedDevice({
    required this.id,
    required this.name,
    required this.platform,
    required this.token,
    required this.pairedAt,
    this.lastSeenAt = 0,
  });

  /// 设备标识，客户端首次生成后固定。
  final String id;

  /// 设备展示名。
  String name;

  /// 平台描述，如 android / ios / windows。
  final String platform;

  /// 访问令牌。
  final String token;

  /// 配对时间，Unix 毫秒。
  final int pairedAt;

  /// 最后活动时间，Unix 毫秒。
  int lastSeenAt;

  Map<String, Object?> toJson({bool includeToken = false}) => {
        'id': id,
        'name': name,
        'platform': platform,
        'pairedAt': pairedAt,
        'lastSeenAt': lastSeenAt,
        if (includeToken) 'token': token,
      };

  Map<String, Object?> toDisk() => {...toJson(includeToken: true)};

  static PairedDevice? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final token = raw['token'];
    if (id is! String || token is! String) return null;
    return PairedDevice(
      id: id,
      name: raw['name'] is String ? raw['name'] as String : '未知设备',
      platform: raw['platform'] is String ? raw['platform'] as String : 'unknown',
      token: token,
      pairedAt: raw['pairedAt'] is int ? raw['pairedAt'] as int : 0,
      lastSeenAt: raw['lastSeenAt'] is int ? raw['lastSeenAt'] as int : 0,
    );
  }
}

/// 配对与鉴权。
class AuthStore {
  AuthStore(this.config, this.file);

  final ServerConfig config;
  final File file;

  List<PairedDevice>? _devices;
  final Random _random = Random.secure();

  static AuthStore defaultStore(ServerConfig config) {
    final dir = ConfigStore.resolveConfigDir();
    return AuthStore(
        config, File('${dir.path}${Platform.pathSeparator}devices.json'));
  }

  /// 生成一个 6 位数字 PIN。
  static String generatePin([Random? random]) {
    final rng = random ?? Random.secure();
    // 避开前导 0，也避开 000000 这类明显弱口令。
    final value = 100000 + rng.nextInt(900000);
    return value.toString();
  }

  /// 生成 32 字节随机令牌，十六进制表示。
  String _newToken() {
    final bytes = List<int>.generate(32, (_) => _random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<List<PairedDevice>> _load() async {
    final cached = _devices;
    if (cached != null) return cached;
    final list = <PairedDevice>[];
    if (await file.exists()) {
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is List) {
          for (final item in decoded) {
            final device = PairedDevice.fromJson(item);
            if (device != null) list.add(device);
          }
        }
      } on FormatException {
        // 从空开始。
      }
    }
    _devices = list;
    return list;
  }

  Future<void> _flush(List<PairedDevice> devices) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
        jsonEncode(devices.map((d) => d.toDisk()).toList()),
        flush: true);
    await tmp.rename(file.path);
  }

  /// 列出所有已配对设备（不含令牌）。
  Future<List<Map<String, Object?>>> listDevices() async {
    final devices = await _load();
    return devices.map((d) => d.toJson()).toList();
  }

  /// 校验 PIN，成功则登记设备并返回令牌。
  ///
  /// 返回 null 表示 PIN 不匹配。
  Future<PairedDevice?> pair({
    required String pin,
    required String deviceId,
    required String deviceName,
    required String platform,
  }) async {
    if (config.pin.isEmpty) return null;
    if (pin.trim() != config.pin) return null;

    final devices = await _load();
    final now = DateTime.now().millisecondsSinceEpoch;
    // 同一 deviceId 重新配对视为重置：换新令牌，旧令牌立即失效。
    devices.removeWhere((d) => d.id == deviceId);
    final device = PairedDevice(
      id: deviceId,
      name: deviceName,
      platform: platform,
      token: _newToken(),
      pairedAt: now,
      lastSeenAt: now,
    );
    devices.add(device);
    await _flush(devices);
    return device;
  }

  /// 用令牌找设备。
  Future<PairedDevice?> findByToken(String token) async {
    if (token.isEmpty) return null;
    final devices = await _load();
    for (final device in devices) {
      if (device.token == token) return device;
    }
    return null;
  }

  /// 更新设备最后活动时间。
  Future<void> touch(PairedDevice device) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    // 一分钟内不重复写盘，避免每个请求都落盘。
    if (now - device.lastSeenAt < 60 * 1000) return;
    device.lastSeenAt = now;
    final devices = await _load();
    await _flush(devices);
  }

  /// 吊销一台设备。
  Future<bool> revoke(String deviceId) async {
    final devices = await _load();
    final before = devices.length;
    devices.removeWhere((d) => d.id == deviceId);
    if (devices.length == before) return false;
    await _flush(devices);
    return true;
  }

  /// 吊销全部设备。
  Future<int> revokeAll() async {
    final devices = await _load();
    final count = devices.length;
    devices.clear();
    await _flush(devices);
    return count;
  }

  /// 改 PIN。已配对设备不受影响。
  Future<void> changePin(String newPin) async {
    config.pin = newPin;
    await ConfigStore.defaultStore().save(config);
  }
}
