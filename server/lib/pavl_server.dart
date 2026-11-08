/// PAVL HTTP 服务端。
///
/// 路由集中在这里，业务逻辑都在 library / auth / streaming 里。
/// 返回给客户端的 JSON 全部是「扁平 + 显式字段」，不做嵌套优化——
/// 客户端要多端实现，可读性比体积重要。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'auth.dart';
import 'config.dart';
import 'discovery.dart';
import 'library.dart';
import 'media.dart';
import 'subtitle_match.dart';
import 'streaming.dart';

/// 服务端版本，出现在 /api/v1/info 与发现应答里。
const String pavlVersion = '0.1.0';

/// API 版本，客户端据此判断兼容性。
const int apiVersion = 1;

/// 运行中的 PAVL 服务端。
class PavlServer {
  PavlServer({
    required this.config,
    required this.configStore,
    required this.library,
    required this.auth,
    required this.metaStore,
    required this.progressStore,
    required this.serverId,
  });

  final ServerConfig config;
  final ConfigStore configStore;
  final Library library;
  final AuthStore auth;
  final MetaStore metaStore;
  final ProgressStore progressStore;

  /// 服务器唯一标识，首次启动生成，用于多服务器区分。
  final String serverId;

  HttpServer? _http;
  DiscoveryService? _discovery;
  final DateTime _startedAt = DateTime.now();

  /// 是否已启动。
  bool get running => _http != null;

  /// 实际监听端口（配置为 0 时由系统分配）。
  int get port => _http?.port ?? config.port;

  /// 启动时间。
  DateTime get startedAt => _startedAt;

  /// 发现服务是否在跑。
  bool get discoveryRunning => _discovery?.running ?? false;

  /// 启动 HTTP 与发现服务。
  Future<void> start() async {
    if (_http != null) return;
    final address = config.bindAddress == '0.0.0.0'
        ? InternetAddress.anyIPv4
        : InternetAddress.tryParse(config.bindAddress) ??
            InternetAddress.anyIPv4;
    final http = await HttpServer.bind(address, config.port, shared: false);
    _http = http;
    // 端口可能由系统分配，回写配置便于展示。
    if (config.port != http.port) {
      config.port = http.port;
    }

    if (config.enableDiscovery) {
      final discovery = DiscoveryService(
        port: config.discoveryPort,
        httpPort: http.port,
        serverName: config.serverName,
        serverId: serverId,
        version: pavlVersion,
        requiresPairing: config.pin.isNotEmpty,
      );
      final ok = await discovery.start();
      if (ok) _discovery = discovery;
    }

    // 后台预热全库索引，不阻塞启动。
    unawaited(library.refreshAll().catchError((_) => <MediaEntry>[]));

    http.listen(_handleRequest, onError: (Object _) {});
  }

  /// 停止服务。
  Future<void> stop() async {
    _discovery?.stop();
    _discovery = null;
    await _http?.close(force: true);
    _http = null;
  }

  /// 重新读取鉴权状态。
  ///
  /// 换 PIN 只影响后续配对，已配对设备的令牌继续有效——否则用户点一次
  /// 「重新生成 PIN」就得把所有设备重新配一遍。
  Future<void> reloadAuth() async {
    // 强制让 AuthStore 丢掉设备缓存，避免它拿着旧的 config.pin 做半检查。
    await auth.listDevices();
    _discovery?.requiresPairing = config.pin.isNotEmpty;
  }

  /// 主路由。
  Future<void> _handleRequest(HttpRequest request) async {
    // 局域网场景允许任意来源；客户端是原生应用，不走浏览器 CORS，
    // 但保留这个头方便将来做网页端调试。
    request.response.headers.set('Access-Control-Allow-Origin', '*');
    request.response.headers.set('Access-Control-Allow-Headers',
        'Authorization, Content-Type, X-PAVL-Device');
    request.response.headers.set('Access-Control-Allow-Methods',
        'GET, POST, PUT, DELETE, OPTIONS');
    request.response.headers.set('Server', 'PAVL/$pavlVersion');

    if (request.method == 'OPTIONS') {
      request.response.statusCode = HttpStatus.noContent;
      await request.response.close();
      return;
    }

    try {
      final segments = request.uri.pathSegments;
      if (segments.length >= 3 &&
          segments[0] == 'api' &&
          segments[1] == 'v$apiVersion') {
        final route = segments.sublist(2).join('/');
        await _route(route, request);
        return;
      }
      if (request.uri.path == '/' || request.uri.path.isEmpty) {
        await _sendJson(request, HttpStatus.ok, {
          'name': config.serverName,
          'version': pavlVersion,
          'api': apiVersion,
          'message': 'PAVL server is running.',
        });
        return;
      }
      await _sendError(request, HttpStatus.notFound, 'not_found', '未知路径');
    } catch (error, stack) {
      // 任何未捕获异常都转成 500，并把细节写进日志而不是响应体。
      stderr.writeln('[PAVL] 处理 ${request.uri} 失败: $error\n$stack');
      try {
        await _sendError(request, HttpStatus.internalServerError,
            'internal_error', '服务器内部错误');
      } catch (_) {
        // 响应已经发过就忽略。
      }
    }
  }

  Future<void> _route(String route, HttpRequest request) async {
    switch (route) {
      case 'info':
        await _handleInfo(request);
        return;
      case 'health':
        await _handleHealth(request);
        return;
      case 'pair':
        await _handlePair(request);
        return;
      case 'devices':
        await _handleDevices(request);
        return;
      case 'browse':
        await _handleBrowse(request);
        return;
      case 'library':
        await _handleLibrary(request);
        return;
      case 'media':
        await _handleMedia(request);
        return;
      case 'media/meta':
        await _handleMeta(request);
        return;
      case 'stream':
        await _handleStream(request);
        return;
      case 'subtitle':
        await _handleSubtitle(request);
        return;
      case 'progress':
        await _handleProgress(request);
        return;
      case 'recent':
        await _handleRecent(request);
        return;
      case 'refresh':
        await _handleRefresh(request);
        return;
      default:
        await _sendError(
            request, HttpStatus.notFound, 'not_found', '未知接口: $route');
    }
  }

  // ---------------------------------------------------------------- 鉴权

  /// 从请求头取令牌。
  String? _tokenOf(HttpRequest request) {
    final header = request.headers.value('authorization');
    if (header != null && header.toLowerCase().startsWith('bearer ')) {
      return header.substring(7).trim();
    }
    final direct = request.headers.value('x-pavl-token');
    if (direct != null && direct.isNotEmpty) return direct;
    // 外挂字幕由 libmpv 自己拉取，它只拿得到 URL，带不了请求头，
    // 所以这几个只读接口允许把令牌放在查询参数里。
    final query = request.uri.queryParameters['token'];
    if (query != null && query.isNotEmpty) return query;
    return null;
  }

  /// 校验令牌，未通过时直接写 401 并返回 null。
  Future<PairedDevice?> _requireAuth(HttpRequest request) async {
    // 没有设置 PIN 时视为不鉴权，方便首次配置。
    if (config.pin.isEmpty) return null;
    final token = _tokenOf(request);
    if (token == null || token.isEmpty) {
      await _sendError(request, HttpStatus.unauthorized, 'unauthorized',
          '缺少访问令牌，请先配对');
      return null;
    }
    final device = await auth.findByToken(token);
    if (device == null) {
      await _sendError(request, HttpStatus.unauthorized, 'invalid_token',
          '令牌无效或已被吊销');
      return null;
    }
    unawaited(auth.touch(device));
    return device;
  }

  // ---------------------------------------------------------------- 处理函数

  Future<void> _handleInfo(HttpRequest request) async {
    await _sendJson(request, HttpStatus.ok, {
      'name': config.serverName,
      'version': pavlVersion,
      'api': apiVersion,
      'id': serverId,
      'requiresPairing': config.pin.isNotEmpty,
      'rootCount': config.roots.length,
      'indexedCount': library.indexedCount,
      'indexedAt': library.indexedAt?.millisecondsSinceEpoch,
      'startedAt': _startedAt.millisecondsSinceEpoch,
      'uptimeSec': DateTime.now().difference(_startedAt).inSeconds,
    });
  }

  Future<void> _handleHealth(HttpRequest request) async {
    await _sendJson(request, HttpStatus.ok, {
      'ok': true,
      'version': pavlVersion,
      'uptimeSec': DateTime.now().difference(_startedAt).inSeconds,
    });
  }

  Future<void> _handlePair(HttpRequest request) async {
    if (request.method != 'POST') {
      await _sendError(
          request, HttpStatus.methodNotAllowed, 'method_not_allowed', '需要 POST');
      return;
    }
    final body = await _readJsonBody(request);
    if (body == null) {
      await _sendError(
          request, HttpStatus.badRequest, 'bad_request', '请求体不是合法 JSON');
      return;
    }
    final pin = body['pin'];
    final deviceId = body['deviceId'];
    final deviceName = body['deviceName'];
    final platform = body['platform'];
    if (pin is! String || deviceId is! String) {
      await _sendError(
          request, HttpStatus.badRequest, 'bad_request', '缺少 pin 或 deviceId');
      return;
    }
    if (config.pin.isEmpty) {
      await _sendError(request, HttpStatus.badRequest, 'no_pin',
          '服务端尚未设置 PIN，请先在服务端设置');
      return;
    }
    final device = await auth.pair(
      pin: pin,
      deviceId: deviceId,
      deviceName: deviceName is String && deviceName.isNotEmpty
          ? deviceName
          : '未命名设备',
      platform: platform is String ? platform : 'unknown',
    );
    if (device == null) {
      await _sendError(
          request, HttpStatus.forbidden, 'bad_pin', 'PIN 不正确');
      return;
    }
    await _sendJson(request, HttpStatus.ok, {
      'token': device.token,
      'deviceId': device.id,
      'serverName': config.serverName,
      'api': apiVersion,
    });
  }

  Future<void> _handleDevices(HttpRequest request) async {
    final device = await _requireAuth(request);
    if (config.pin.isNotEmpty && device == null) return;

    if (request.method == 'GET') {
      await _sendJson(request, HttpStatus.ok, {
        'devices': await auth.listDevices(),
      });
      return;
    }
    if (request.method == 'DELETE') {
      final id = request.uri.queryParameters['id'];
      if (id == null || id.isEmpty) {
        await _sendError(
            request, HttpStatus.badRequest, 'bad_request', '缺少 id');
        return;
      }
      final ok = await auth.revoke(id);
      await _sendJson(request, ok ? HttpStatus.ok : HttpStatus.notFound, {
        'ok': ok,
      });
      return;
    }
    await _sendError(
        request, HttpStatus.methodNotAllowed, 'method_not_allowed', '不支持的方法');
  }

  Future<void> _handleBrowse(HttpRequest request) async {
    final authDevice = await _requireAuth(request);
    if (config.pin.isNotEmpty && authDevice == null) return;
    final path = request.uri.queryParameters['path'] ?? '';
    final sort = request.uri.queryParameters['sort'] ?? 'normal';
    final entries = await library.browse(path, sort: sort);
    await _sendJson(request, HttpStatus.ok, {
      'path': path,
      'parent': _parentOf(path),
      'sort': sort,
      'entries': entries.map((e) => e.toJson()).toList(),
    });
  }

  Future<void> _handleLibrary(HttpRequest request) async {
    final authDevice = await _requireAuth(request);
    if (config.pin.isNotEmpty && authDevice == null) return;

    final query = request.uri.queryParameters;
    final page = int.tryParse(query['page'] ?? '1') ?? 1;
    final pageSize =
        (int.tryParse(query['pageSize'] ?? '100') ?? 100).clamp(1, 500);
    final keyword = (query['q'] ?? '').trim().toLowerCase();
    final kindFilter = query['kind'];

    var all = await library.getAll();
    if (keyword.isNotEmpty) {
      all = all
          .where((e) =>
              e.relativePath.toLowerCase().contains(keyword) ||
              e.parsed.title.toLowerCase().contains(keyword))
          .toList();
    }
    if (kindFilter != null) {
      all = all.where((e) => e.kind.name == kindFilter).toList();
    }

    final total = all.length;
    final startIdx = ((page - 1) * pageSize).clamp(0, total);
    final endIdx = (startIdx + pageSize).clamp(0, total);
    final slice = startIdx >= total ? <MediaEntry>[] : all.sublist(startIdx, endIdx);

    await _sendJson(request, HttpStatus.ok, {
      'total': total,
      'page': page,
      'pageSize': pageSize,
      'hasMore': endIdx < total,
      'indexedAt': library.indexedAt?.millisecondsSinceEpoch,
      'items': slice.map((e) => e.toJson()).toList(),
    });
  }

  Future<void> _handleMedia(HttpRequest request) async {
    final authDevice = await _requireAuth(request);
    if (config.pin.isNotEmpty && authDevice == null) return;
    final path = request.uri.queryParameters['path'];
    if (path == null || path.isEmpty) {
      await _sendError(request, HttpStatus.badRequest, 'bad_request', '缺少 path');
      return;
    }
    final entry = await library.findEntry(path);
    final abs = library.resolveAbsolute(path);
    if (abs == null) {
      await _sendError(
          request, HttpStatus.forbidden, 'forbidden', '路径越界或根不存在');
      return;
    }
    final file = File(abs);
    if (!await file.exists()) {
      await _sendError(
          request, HttpStatus.notFound, 'not_found', '文件不存在');
      return;
    }
    final meta = await metaStore.get(path);
    final progress = await progressStore.get(path);
    await _sendJson(request, HttpStatus.ok, {
      'path': path,
      if (entry != null) ...entry.toJson(),
      if (entry == null) 'name': _baseName(abs),
      'meta': meta,
      'progress': progress,
      // 同目录下的外挂字幕，供客户端自动挂载。
      'subtitles': await _sidecarSubtitles(abs, path),
    });
  }

  Future<void> _handleMeta(HttpRequest request) async {
    final authDevice = await _requireAuth(request);
    if (config.pin.isNotEmpty && authDevice == null) return;
    if (request.method != 'POST') {
      await _sendError(
          request, HttpStatus.methodNotAllowed, 'method_not_allowed', '需要 POST');
      return;
    }
    final body = await _readJsonBody(request);
    if (body == null) {
      await _sendError(
          request, HttpStatus.badRequest, 'bad_request', '请求体不是合法 JSON');
      return;
    }
    final path = body['path'];
    if (path is! String || path.isEmpty) {
      await _sendError(request, HttpStatus.badRequest, 'bad_request', '缺少 path');
      return;
    }
    final meta = <String, Object?>{};
    for (final key in const [
      'duration',
      'width',
      'height',
      'videoCodec',
      'audioCodec',
      'bitrate',
      'title',
      'poster',
      'container',
      'fps',
      'audioChannels',
    ]) {
      final value = body[key];
      if (value != null) meta[key] = value;
    }
    if (meta.isNotEmpty) await metaStore.put(path, meta);
    await _sendJson(request, HttpStatus.ok, {'ok': true, 'stored': meta.length});
  }

  Future<void> _handleStream(HttpRequest request) async {
    final authDevice = await _requireAuth(request);
    if (config.pin.isNotEmpty && authDevice == null) return;
    final path = request.uri.queryParameters['path'];
    if (path == null || path.isEmpty) {
      await _sendError(request, HttpStatus.badRequest, 'bad_request', '缺少 path');
      return;
    }
    final abs = library.resolveAbsolute(path);
    if (abs == null) {
      await _sendError(
          request, HttpStatus.forbidden, 'forbidden', '路径越界或根不存在');
      return;
    }
    final file = File(abs);
    FileStat stat;
    try {
      stat = await file.stat();
    } on FileSystemException {
      await _sendError(
          request, HttpStatus.notFound, 'not_found', '文件不存在');
      return;
    }
    if (stat.type != FileSystemEntityType.file) {
      await _sendError(
          request, HttpStatus.notFound, 'not_found', '不是普通文件');
      return;
    }

    final size = stat.size;
    final etag = weakEtag(size, stat.modified.millisecondsSinceEpoch);
    final response = request.response;
    response.headers.set('Accept-Ranges', 'bytes');
    response.headers.set('ETag', etag);
    response.headers.set('Content-Type', contentTypeOf(abs));
    response.headers.set('Cache-Control', 'no-cache');

    // 客户端缓存命中：直接 304，省一次全量传输。
    final ifNoneMatch = request.headers.value('if-none-match');
    if (ifNoneMatch != null && ifNoneMatch == etag) {
      response.statusCode = HttpStatus.notModified;
      await response.close();
      return;
    }

    final rangeHeader = request.headers.value('range');
    final result = parseRange(rangeHeader, size);

    if (rangeHeader != null && !result.isOk) {
      // 显式带了 Range 但不可满足 → 416，并回告文件大小。
      response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      response.headers.set('Content-Range', 'bytes */$size');
      await response.close();
      return;
    }

    if (result.isOk) {
      final range = result.range!;
      response.statusCode = HttpStatus.partialContent;
      response.headers.set('Content-Range',
          'bytes ${range.start}-${range.end}/$size');
      response.headers.contentLength = range.length;
      await streamFile(response, file,
          start: range.start, end: range.end);
    } else {
      response.statusCode = HttpStatus.ok;
      response.headers.contentLength = size;
      await streamFile(response, file, start: 0, end: size - 1);
    }
    await response.close();
  }

  Future<void> _handleSubtitle(HttpRequest request) async {
    final authDevice = await _requireAuth(request);
    if (config.pin.isNotEmpty && authDevice == null) return;
    final path = request.uri.queryParameters['path'];
    if (path == null || path.isEmpty) {
      await _sendError(request, HttpStatus.badRequest, 'bad_request', '缺少 path');
      return;
    }
    final abs = library.resolveAbsolute(path);
    if (abs == null) {
      await _sendError(
          request, HttpStatus.forbidden, 'forbidden', '路径越界或根不存在');
      return;
    }
    final file = File(abs);
    if (!await file.exists()) {
      await _sendError(
          request, HttpStatus.notFound, 'not_found', '字幕不存在');
      return;
    }
    final size = await file.length();
    final response = request.response;
    response.headers.set('Content-Type', contentTypeOf(abs));
    response.headers.set('Content-Length', '$size');
    response.statusCode = HttpStatus.ok;
    await response.addStream(file.openRead());
    await response.close();
  }

  Future<void> _handleProgress(HttpRequest request) async {
    final authDevice = await _requireAuth(request);
    if (config.pin.isNotEmpty && authDevice == null) return;

    if (request.method == 'GET') {
      final path = request.uri.queryParameters['path'];
      final deviceId = request.uri.queryParameters['device'];
      if (path == null || path.isEmpty) {
        await _sendError(
            request, HttpStatus.badRequest, 'bad_request', '缺少 path');
        return;
      }
      final entry = await progressStore.get(path, deviceId: deviceId);
      await _sendJson(request, HttpStatus.ok, {'path': path, 'progress': entry});
      return;
    }

    if (request.method == 'POST') {
      final body = await _readJsonBody(request);
      if (body == null) {
        await _sendError(
            request, HttpStatus.badRequest, 'bad_request', '请求体不是合法 JSON');
        return;
      }
      final path = body['path'];
      if (path is! String || path.isEmpty) {
        await _sendError(
            request, HttpStatus.badRequest, 'bad_request', '缺少 path');
        return;
      }
      final position = _asDouble(body['position']);
      final duration = _asDouble(body['duration']);
      if (position == null || duration == null) {
        await _sendError(request, HttpStatus.badRequest, 'bad_request',
            '缺少 position 或 duration');
        return;
      }
      await progressStore.put(
        path,
        positionSec: position,
        durationSec: duration,
        deviceId: authDevice?.id,
        deviceName: authDevice?.name,
        finished: body['finished'] == true,
      );
      await _sendJson(request, HttpStatus.ok, {'ok': true});
      return;
    }

    await _sendError(
        request, HttpStatus.methodNotAllowed, 'method_not_allowed', '不支持的方法');
  }

  Future<void> _handleRecent(HttpRequest request) async {
    final authDevice = await _requireAuth(request);
    if (config.pin.isNotEmpty && authDevice == null) return;
    final limit = int.tryParse(request.uri.queryParameters['limit'] ?? '20') ?? 20;
    final rows = await progressStore.recent(limit: limit.clamp(1, 100));
    await _sendJson(request, HttpStatus.ok, {'items': rows});
  }

  Future<void> _handleRefresh(HttpRequest request) async {
    final authDevice = await _requireAuth(request);
    if (config.pin.isNotEmpty && authDevice == null) return;
    if (request.method != 'POST') {
      await _sendError(
          request, HttpStatus.methodNotAllowed, 'method_not_allowed', '需要 POST');
      return;
    }
    final count = (await library.refreshAll()).length;
    await _sendJson(request, HttpStatus.ok, {
      'ok': true,
      'count': count,
      'indexedAt': library.indexedAt?.millisecondsSinceEpoch,
    });
  }

  // ---------------------------------------------------------------- 工具

  /// 找同目录下的外挂字幕。
  Future<List<Map<String, Object?>>> _sidecarSubtitles(
      String absPath, String relPath) async {
    final file = File(absPath);
    final dir = file.parent;
    final baseName = _baseName(absPath);
    final matched = <Map<String, Object?>>[];
    final siblings = <Map<String, Object?>>[];
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = _baseName(entity.path);
        if (!isSubtitle(name)) continue;
        final parentRel = relPath.contains('/')
            ? relPath.substring(0, relPath.lastIndexOf('/'))
            : '';
        final rel = parentRel.isEmpty ? name : '$parentRel/$name';
        final stat = await entity.stat();
        final item = <String, Object?>{
          'name': name,
          'path': rel,
          'size': stat.size,
        };
        if (subtitleBelongsTo(baseName, name)) {
          matched.add(item);
        } else {
          siblings.add(<String, Object?>{...item, 'match': 'none'});
        }
      }
    } on FileSystemException {
      // 目录不可读就当没有字幕。
    }
    int byName(Map<String, Object?> a, Map<String, Object?> b) =>
        naturalCompare(a['name']! as String, b['name']! as String);
    if (matched.isNotEmpty) {
      matched.sort(byName);
      return matched;
    }
    siblings.sort(byName);
    return siblings;
  }

  static String _parentOf(String path) {
    if (path.isEmpty) return '';
    final idx = path.lastIndexOf('/');
    return idx < 0 ? '' : path.substring(0, idx);
  }

  static String _baseName(String path) {
    final normalized = path.replaceAll('\\', '/');
    final idx = normalized.lastIndexOf('/');
    return idx < 0 ? normalized : normalized.substring(idx + 1);
  }

  static double? _asDouble(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  Future<Map<String, Object?>?> _readJsonBody(HttpRequest request) async {
    try {
      final text = await utf8.decoder.bind(request).join();
      if (text.trim().isEmpty) return <String, Object?>{};
      final decoded = jsonDecode(text);
      if (decoded is Map<String, Object?>) return decoded;
      if (decoded is Map) return decoded.cast<String, Object?>();
      return null;
    } on FormatException {
      return null;
    } on HttpException {
      return null;
    }
  }

  Future<void> _sendJson(
      HttpRequest request, int status, Object? payload) async {
    final response = request.response;
    response.statusCode = status;
    response.headers.contentType =
        ContentType('application', 'json', charset: 'utf-8');
    response.headers.set('Cache-Control', 'no-store');
    response.write(jsonEncode(payload));
    await response.close();
  }

  Future<void> _sendError(
      HttpRequest request, int status, String code, String message) async {
    await _sendJson(request, status, {
      'error': code,
      'message': message,
    });
  }
}

/// 创建并启动一个服务端实例。
Future<PavlServer> startServer({
  ServerConfig? config,
  ConfigStore? configStore,
  void Function(String message)? log,
}) async {
  final store = configStore ?? ConfigStore.defaultStore();
  final cfg = config ?? await store.load();

  // 首次启动生成 PIN 与服务器 id，写入配置。
  if (cfg.pin.isEmpty) {
    cfg.pin = AuthStore.generatePin();
    await store.save(cfg);
    log?.call('首次启动，已生成配对 PIN: ${cfg.pin}');
  }
  var serverId = cfg.serverId;
  if (serverId.isEmpty) {
    serverId = randomHex(8);
    cfg.serverId = serverId;
    await store.save(cfg);
  }

  final library = Library(cfg);
  final auth = AuthStore.defaultStore(cfg);
  final server = PavlServer(
    config: cfg,
    configStore: store,
    library: library,
    auth: auth,
    metaStore: MetaStore.defaultStore(),
    progressStore: ProgressStore.defaultStore(),
    serverId: serverId,
  );
  await server.start();
  return server;
}
