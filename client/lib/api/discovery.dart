/// LAN 发现：广播查询 + 缓存直连。
///
/// 三段式降级：
///   1. 上次连过的地址，先直接 ping（最快，通常 <50ms）
///   2. UDP 广播，收集应答（局域网内通常 <1s）
///   3. 都失败则让用户手输 IP
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'pavl_client.dart';

/// 发现协议常量，必须和服务端保持一致。
const String _magic = 'PAVL-DISCOVER-v1';
const int discoveryPort = 45789;

/// 发现结果回调。
typedef ServerFound = void Function(DiscoveredServer server);

/// 一次发现会话。
class DiscoverySession {
  DiscoverySession({this.timeout = const Duration(seconds: 3)});

  final Duration timeout;
  RawDatagramSocket? _socket;
  Timer? _deadline;
  final Set<String> _seen = {};
  final List<DiscoveredServer> _results = [];

  bool _finished = false;

  /// 已发现的结果（去重后）。
  List<DiscoveredServer> get results => List.unmodifiable(_results);

  /// 开始广播并监听应答。
  ///
  /// [onFound] 每发现一个新服务器就回调一次，便于界面边收边显示。
  Future<List<DiscoveredServer>> run({ServerFound? onFound}) async {
    _onFoundCallback = onFound;
    try {
      _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _socket!.broadcastEnabled = true;
      _socket!.listen(_onEvent, onError: (_) {});
    } on SocketException {
      // 没有可用网卡（例如完全离线），直接返回空。
      return const [];
    }

    // 先把网卡列表拿好：广播目标要用它算，而 send 是同步调用，没法在里面 await。
    _targets = await _computeBroadcastTargets();

    // 连发三次，避免首次广播被交换机或 AP 丢掉。
    _broadcast();
    Timer(const Duration(milliseconds: 600), _broadcast);
    Timer(const Duration(milliseconds: 1400), _broadcast);

    final completer = Completer<List<DiscoveredServer>>();
    _deadline = Timer(timeout, () {
      if (!completer.isCompleted) completer.complete(results);
      _close();
    });

    final list = await completer.future;
    return list;
  }

  /// 往所有可能的广播地址各发一份。
  ///
  /// 目标地址由 [_computeBroadcastTargets] 算好，这里只管发。
  void _broadcast() {
    final socket = _socket;
    if (socket == null) return;
    final payload = utf8.encode(jsonEncode({'magic': _magic}));
    for (final address in _broadcastTargets) {
      try {
        socket.send(payload, address, discoveryPort);
      } on SocketException {
        // 部分网络禁止广播，忽略即可，后面还有手动输入兜底。
      }
    }
  }

  /// 广播目标地址，[run] 里已经算好；没算过就只发全局广播。
  List<InternetAddress> get _broadcastTargets =>
      _targets ?? [InternetAddress('255.255.255.255')];

  /// 算出所有值得发一份的广播地址。
  ///
  /// 只发 `255.255.255.255` 在 macOS 上经常石沉大海：那张网卡的子网广播地址
  /// （例如 `192.168.1.255`）才是交换机真正会转发的目标，而全局广播会被系统
  /// 或路由器直接丢掉。两种都发一遍，代价只是多几个几十字节的包。
  Future<List<InternetAddress>> _computeBroadcastTargets() async {
    final targets = <InternetAddress>[InternetAddress('255.255.255.255')];
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      for (final interface in interfaces) {
        for (final subnet in interface.addresses) {
          if (subnet.type != InternetAddressType.IPv4) continue;
          if (subnet.isLoopback) continue;
          final address = _slash24Broadcast(subnet.address);
          if (address != null) targets.add(address);
        }
      }
    } on Object {
      // 列网卡失败（权限、离线）时只留全局广播。
    }
    return targets;
  }

  /// 按 /24 推算子网广播地址，例如 `192.168.1.21` → `192.168.1.255`。
  ///
  /// Dart 的 [NetworkInterface] 不暴露子网掩码，所以没法算出精确的广播地址。
  /// 家用和小型办公网络基本都是 /24，按这个假设猜一个，比只发全局广播多
  /// 一次命中机会；猜错了也只是多发一个没人收的包。
  static InternetAddress? _slash24Broadcast(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4) return null;
    final octets = <int>[];
    for (final part in parts) {
      final value = int.tryParse(part);
      if (value == null || value < 0 || value > 255) return null;
      octets.add(value);
    }
    return InternetAddress('${octets[0]}.${octets[1]}.${octets[2]}.255');
  }

  List<InternetAddress>? _targets;

  void _onEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read || _finished) return;
    final socket = _socket;
    if (socket == null) return;
    final datagram = socket.receive();
    if (datagram == null) return;

    final server = _parse(datagram.data, datagram.address.address);
    if (server == null) return;
    // 同一台服务器可能因为多网卡回多次，按 id+host 去重。
    final key = '${server.serverId}@${server.host}:${server.port}';
    if (!_seen.add(key)) return;
    _results.add(server);
    _onFoundCallback?.call(server);
  }

  ServerFound? _onFoundCallback;

  /// 解析应答包，格式不对返回 null。
  static DiscoveredServer? _parse(List<int> data, String host) {
    try {
      final decoded = jsonDecode(utf8.decode(data));
      if (decoded is! Map) return null;
      if (decoded['magic'] != _magic) return null;
      final port = (decoded['port'] as num?)?.toInt();
      if (port == null || port <= 0) return null;
      return DiscoveredServer(
        name: decoded['name'] as String? ?? 'PAVL',
        host: host,
        port: port,
        version: decoded['version'] as String? ?? '',
        serverId: decoded['id'] as String? ?? '$host:$port',
        requiresPairing: decoded['pairing'] as bool? ?? true,
        storage: decoded['storage'] as String?,
      );
    } on FormatException {
      return null;
    } on ArgumentError {
      return null;
    }
  }

  void _close() {
    _finished = true;
    _deadline?.cancel();
    _socket?.close();
    _socket = null;
  }

  void dispose() => _close();
}

/// 尝试直连一个已知地址，成功则说明服务器还在。
///
/// 返回 null 代表连不上。超时设得比较短，因为这是「秒连」路径上的第一步。
Future<DiscoveredServer?> probeHost(String host, int port) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
  try {
    final request = await client
        .getUrl(Uri.parse('http://$host:$port/api/v1/info'))
        .timeout(const Duration(seconds: 2));
    final response = await request.close().timeout(const Duration(seconds: 3));
    if (response.statusCode != 200) return null;
    final text = await utf8.decodeStream(response);
    final decoded = jsonDecode(text);
    if (decoded is! Map) return null;
    return DiscoveredServer(
      name: decoded['name'] as String? ?? 'PAVL',
      host: host,
      port: port,
      version: decoded['version'] as String? ?? '',
      serverId: decoded['id'] as String? ?? '$host:$port',
      requiresPairing: decoded['requiresPairing'] as bool? ?? true,
      storage: decoded['storage'] as String?,
    );
  } on SocketException {
    return null;
  } on TimeoutException {
    return null;
  } on FormatException {
    return null;
  } catch (_) {
    // HttpClient 在连接被重置时会抛各种底层异常，这里一律视为连不上。
    return null;
  } finally {
    client.close(force: true);
  }
}
