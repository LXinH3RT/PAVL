/// UDP 局域网发现。
///
/// 服务端在固定端口上监听一个极小的请求报文，收到就回一个 JSON，
/// 里面带服务器名、端口、版本。客户端广播一次即可拿到结果，
/// 不需要知道 IP，也不需要 mDNS 的复杂性。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 发现协议的固定魔数，避免误回其他程序的广播包。
const String discoveryMagic = 'PAVL-DISCOVER-v1';

/// 发现应答的端口。
const int defaultDiscoveryPort = 45789;

/// 一次发现请求的载荷。
String buildRequest() => jsonEncode({'magic': discoveryMagic});

/// 解析发现请求，非法返回 false。
bool isDiscoveryRequest(List<int> data) {
  try {
    final decoded = jsonDecode(utf8.decode(data));
    return decoded is Map && decoded['magic'] == discoveryMagic;
  } on FormatException {
    return false;
  } on ArgumentError {
    return false;
  }
}

/// 发现应答的载荷。
///
/// `storage` 跟 `/api/v1/info` 里那个字段同义。客户端靠它判断播放偏好该存
/// 自己这边还是存服务端，所以要跟着广播一起发出去：否则靠广播发现的安装版
/// 服务端会被当成便携版，偏好就写到错误的机器上了。
Map<String, Object?> buildResponse({
  required String serverName,
  required int httpPort,
  required String version,
  required String serverId,
  required bool requiresPairing,
  required String storage,
}) =>
    {
      'magic': discoveryMagic,
      'name': serverName,
      'port': httpPort,
      'version': version,
      'id': serverId,
      'pairing': requiresPairing,
      'storage': storage,
    };

/// 服务端发现监听器。
class DiscoveryService {
  DiscoveryService({
    required this.port,
    required this.httpPort,
    required this.serverName,
    required this.serverId,
    required this.version,
    required this.requiresPairing,
    required this.storage,
  });

  final int port;
  final int httpPort;
  final String serverName;
  final String serverId;
  final String version;

  /// 是否要求配对（PIN 已设置）。
  bool requiresPairing;

  /// 存储形态，`portable` 或 `installed`。
  final String storage;

  RawDatagramSocket? _socket;
  Timer? _beacon;

  bool get running => _socket != null;

  /// 启动监听，并周期性主动广播，减少客户端等待。
  Future<bool> start({Duration beaconInterval = const Duration(seconds: 3)}) async {
    if (_socket != null) return true;
    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        port,
        reuseAddress: true,
      );
      socket.broadcastEnabled = true;
      socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket.receive();
        if (datagram == null) return;
        if (!isDiscoveryRequest(datagram.data)) return;
        final payload = utf8.encode(jsonEncode(buildResponse(
          serverName: serverName,
          httpPort: httpPort,
          version: version,
          serverId: serverId,
          requiresPairing: requiresPairing,
          storage: storage,
        )));
        try {
          socket.send(payload, datagram.address, datagram.port);
        } on SocketException {
          // 单次发送失败不影响监听。
        }
      });
      _socket = socket;
      // 主动广播，让刚打开的客户端不用等下一次请求往返。
      _beacon = Timer.periodic(beaconInterval, (_) => _broadcast());
      return true;
    } on SocketException {
      // 端口被占用等情况，发现功能降级为不可用，不影响 HTTP 服务。
      return false;
    }
  }

  void _broadcast() {
    final socket = _socket;
    if (socket == null) return;
    final payload = utf8.encode(jsonEncode(buildResponse(
      serverName: serverName,
      httpPort: httpPort,
      version: version,
      serverId: serverId,
      requiresPairing: requiresPairing,
      storage: storage,
    )));
    try {
      socket.send(payload, InternetAddress('255.255.255.255'), port);
    } on SocketException {
      // 某些网络环境禁止全局广播，忽略。
    }
  }

  void stop() {
    _beacon?.cancel();
    _beacon = null;
    _socket?.close();
    _socket = null;
  }
}
