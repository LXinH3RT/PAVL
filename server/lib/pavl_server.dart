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
import 'library_groups.dart';
import 'media.dart';
import 'scrape/engine.dart';
import 'scrape/models.dart';
import 'scrape/store.dart';
import 'sort_key.dart';
import 'subtitle_match.dart';
import 'streaming.dart';

/// 服务端版本，出现在 /api/v1/info 与发现应答里。
const String pavlVersion = '0.2.3';

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
    required this.trackPrefStore,
    required this.serverId,
    ScrapeEngine? scrapeEngine,
  }) : scrapeEngine = scrapeEngine ?? ScrapeEngine(store: ScrapeStore.defaultStore());

  final ServerConfig config;
  final ConfigStore configStore;
  final Library library;
  final AuthStore auth;
  final MetaStore metaStore;
  final ProgressStore progressStore;
  final TrackPrefStore trackPrefStore;

  /// 刮削引擎。配置从 [ServerConfig.scrape] 来，改动会写回配置文件。
  final ScrapeEngine scrapeEngine;

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
    // 引擎里的设置跟着配置文件走：改了配置要同步，否则界面上开了刮削、
    // 服务端还按启动时那份空配置跑。
    scrapeEngine.settings = config.scrape;
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
        // 跟 /info 里那个字段同义。广播里也带上，客户端才能在选择服务器时
        // 就知道该把播放偏好写到哪一侧。
        storage: storageMode.wireName,
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
    scrapeEngine.close();
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
      case 'prefs/tracks':
        await _handleTrackPrefs(request);
        return;
      case 'recent':
        await _handleRecent(request);
        return;
      case 'refresh':
        await _handleRefresh(request);
        return;
      case 'poster':
        await _handlePoster(request);
        return;
      case 'scrape/settings':
        await _handleScrapeSettings(request);
        return;
      case 'scrape/search':
        await _handleScrapeSearch(request);
        return;
      case 'scrape/apply':
        await _handleScrapeApply(request);
        return;
      case 'scrape/auto':
        await _handleScrapeAuto(request);
        return;
      case 'scrape/clear':
        await _handleScrapeClear(request);
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
      // 便携版的数据目录跟着程序走，播放偏好不能存在服务端——否则把程序
      // 文件夹拷给第二个人，对方就会读到别人选过的音轨。客户端据此决定
      // 偏好落本地还是落服务端。
      'storage': storageMode.wireName,
      'rootCount': config.roots.length,
      'indexedCount': library.indexedCount,
      'indexedAt': library.indexedAt?.millisecondsSinceEpoch,
      'startedAt': _startedAt.millisecondsSinceEpoch,
      'uptimeSec': DateTime.now().difference(_startedAt).inSeconds,
      // 服务端有没有开刮削。客户端设置里的「使用刮削」开关只在服务端开了
      // 之后才允许打开——服务端没开的话，客户端打开了也只是空列表。
      'scrape': config.scrape.enabled,
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
    // 索引是跨目录扁平的一串视频，直接发出去的话，一部剧几十集就占几十行。
    // 这里先按目录收成「文件夹 + 集数」的行再分页：客户端拿到的一行就是一行，
    // 翻页不会把同一个文件夹切到两页里去。
    final rows = groupLibrary(all);

    final total = rows.length;
    final videoTotal = all.length;
    final startIdx = ((page - 1) * pageSize).clamp(0, total);
    final endIdx = (startIdx + pageSize).clamp(0, total);
    final slice =
        startIdx >= total ? <LibraryGroup>[] : rows.sublist(startIdx, endIdx);

    // 刮削结果按行挂上去：一行是文件夹时，取它第一个有记录的视频——同一部剧
    // 的每一集写的是同一条记录，取哪一集都一样。没有任何记录的行不带这个字段，
    // 客户端据此显示原始文件名。
    final scraped = config.scrape.enabled
        ? await scrapeEngine.recordsFor(slice.expand((r) => r.videos.map((v) => v.relativePath)))
        : const <String, ScrapeRecord>{};
    const posterBase = '/api/v1/poster?name=';

    await _sendJson(request, HttpStatus.ok, {
      'total': total,
      'videoTotal': videoTotal,
      'page': page,
      'pageSize': pageSize,
      'hasMore': endIdx < total,
      'scrapeEnabled': config.scrape.enabled,
      'indexedAt': library.indexedAt?.millisecondsSinceEpoch,
      'items': slice.map((row) {
        final json = row.toJson();
        final record = scraped[row.path] ??
            row.videos
                .map((v) => scraped[v.relativePath])
                .whereType<ScrapeRecord>()
                .firstOrNull;
        if (record != null) {
          json['scrape'] = record.toJson(posterBase: posterBase);
        }
        return json;
      }).toList(),
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

    final rangeHeader = request.headers.value('range');

    // 客户端缓存命中：直接 304，省一次全量传输。
    // 带 Range 的请求必须走 206，否则播放器 seek 时拿到 304 会当成空响应。
    final ifNoneMatch = request.headers.value('if-none-match');
    if (rangeHeader == null && ifNoneMatch != null && ifNoneMatch == etag) {
      response.statusCode = HttpStatus.notModified;
      await response.close();
      return;
    }

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

  /// 每台机器对每个影片的音轨/字幕选择。
  ///
  /// 只在安装版上有意义：便携版服务端的数据跟着程序文件夹走，存下来会跟着
  /// 文件夹一起被拷给别人，等于把甲的选择带给乙。客户端看到 `/info` 报
  /// `storage: portable` 就不会来调这个接口。
  Future<void> _handleTrackPrefs(HttpRequest request) async {
    final authDevice = await _requireAuth(request);
    if (config.pin.isNotEmpty && authDevice == null) return;
    final deviceId = _deviceIdOf(request, authDevice);
    if (deviceId == null || deviceId.isEmpty) {
      await _sendError(request, HttpStatus.badRequest, 'bad_request',
          '缺少设备标识，配对后再试');
      return;
    }

    if (request.method == 'GET') {
      final path = request.uri.queryParameters['path'];
      if (path != null && path.isNotEmpty) {
        final entry = await trackPrefStore.get(path, deviceId: deviceId);
        await _sendJson(request, HttpStatus.ok, {'path': path, 'pref': entry});
        return;
      }
      // 不带 path 时把这个设备的全部偏好一次发过去：客户端进片库时拉一次，
      // 之后每开一集都用本地缓存，不用一集一个请求。
      final all = await trackPrefStore.allFor(deviceId);
      await _sendJson(request, HttpStatus.ok, {'prefs': all});
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
      final audio = body['audio'];
      final subtitle = body['subtitle'];
      final subtitlePath = body['subtitlePath'];
      // 语言和标题一起存：同一部剧的下一集，轨道 id 往往和上一集对不上，
      // 客户端要按语言/标题回退匹配，服务端只负责原样保管。
      await trackPrefStore.put(
        path,
        deviceId: deviceId,
        fields: {
          'audio': audio is String && audio.isNotEmpty ? audio : null,
          'subtitle':
              subtitle is String && subtitle.isNotEmpty ? subtitle : null,
          'subtitlePath':
              subtitlePath is String && subtitlePath.isNotEmpty
                  ? subtitlePath
                  : null,
          'audioLang': _nonEmptyString(body['audioLang']),
          'audioTitle': _nonEmptyString(body['audioTitle']),
          'subtitleLang': _nonEmptyString(body['subtitleLang']),
          'subtitleTitle': _nonEmptyString(body['subtitleTitle']),
        },
      );
      await _sendJson(request, HttpStatus.ok, {'ok': true});
      return;
    }

    if (request.method == 'DELETE') {
      final removed = await trackPrefStore.clear(deviceId);
      await _sendJson(request, HttpStatus.ok, {'ok': true, 'removed': removed});
      return;
    }

    await _sendError(
        request, HttpStatus.methodNotAllowed, 'method_not_allowed', '不支持的方法');
  }

  /// 请求来自哪台设备。
  ///
  /// 配对了就用鉴权结果，那是可信的；没设 PIN 时服务端不鉴权，只能读客户端
  /// 自己报的 `X-PAVL-Device` 头——这种情况下谁都能冒充谁，但没设 PIN 本身
  /// 就意味着这台服务器对整个局域网开放，偏好记录被冒充不算新增风险。
  String? _deviceIdOf(HttpRequest request, PairedDevice? authDevice) {
    if (authDevice != null) return authDevice.id;
    final header = request.headers.value('x-pavl-device');
    if (header != null && header.isNotEmpty) return header;
    return null;
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
    // 目录队列与「是否含媒体」的判定都带缓存，强制刷新时一并作废，
    // 否则刚拷进来的影片要等缓存过期才会出现。
    library.invalidate();
    final count = (await library.refreshAll()).length;
    await _sendJson(request, HttpStatus.ok, {
      'ok': true,
      'count': count,
      'indexedAt': library.indexedAt?.millisecondsSinceEpoch,
    });
  }

  // ---------------------------------------------------------------- 刮削

  /// `GET /api/v1/scrape/settings`：读刮削配置。
  ///
  /// `POST` 时接受 `{enabled, autoMatch, sources}`，写回 `config.json`。
  Future<void> _handleScrapeSettings(HttpRequest request) async {
    final authDevice = await _requireAuth(request);
    if (config.pin.isNotEmpty && authDevice == null) return;

    if (request.method == 'GET') {
      await _sendJson(request, HttpStatus.ok, {
        ...config.scrape.toJson(),
        'sources': ScrapeSource.values
            .map((s) => {'id': s.wireName, 'label': s.label})
            .toList(),
        'recordCount': await scrapeEngine.recordCount,
        'running': scrapeEngine.running,
      });
      return;
    }
    if (request.method != 'POST') {
      await _sendError(request, HttpStatus.methodNotAllowed, 'method_not_allowed',
          '只支持 GET 与 POST');
      return;
    }
    final body = await _readJsonBody(request);
    if (body == null) {
      await _sendError(
          request, HttpStatus.badRequest, 'bad_request', '请求体不是合法 JSON');
      return;
    }
    var next = config.scrape;
    if (body['enabled'] is bool) {
      next = next.copyWith(enabled: body['enabled']! as bool);
    }
    if (body['autoMatch'] is bool) {
      next = next.copyWith(autoMatch: body['autoMatch']! as bool);
    }
    final rawSources = body['sources'];
    if (rawSources is List) {
      final picked = <ScrapeSource>[];
      for (final item in rawSources) {
        final source = ScrapeSource.parse(item is String ? item : null);
        if (source != null && !picked.contains(source)) picked.add(source);
      }
      if (picked.isNotEmpty) next = next.copyWith(sources: picked);
    }
    config.scrape = next;
    scrapeEngine.settings = next;
    await configStore.save(config);
    await _sendJson(request, HttpStatus.ok, {
      'ok': true,
      ...next.toJson(),
    });
  }

  /// `GET /api/v1/scrape/search?q=&kind=&year=&source=`：按关键词找候选。
  Future<void> _handleScrapeSearch(HttpRequest request) async {
    final authDevice = await _requireAuth(request);
    if (config.pin.isNotEmpty && authDevice == null) return;
    final query = request.uri.queryParameters;
    final keyword = (query['q'] ?? '').trim();
    if (keyword.isEmpty) {
      await _sendError(
          request, HttpStatus.badRequest, 'bad_request', '缺少关键词 q');
      return;
    }
    final kind = ScrapeKind.parse(query['kind']);
    final year = int.tryParse(query['year'] ?? '');
    final only = ScrapeSource.parse(query['source']);
    final result = await scrapeEngine.search(
      keyword,
      kind: kind == ScrapeKind.unknown ? null : kind,
      year: year,
      sources: only == null ? null : [only],
    );
    await _sendJson(request, HttpStatus.ok, result.toJson());
  }

  /// `POST /api/v1/scrape/apply`：把选中的候选套到一组路径上。
  Future<void> _handleScrapeApply(HttpRequest request) async {
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
    final paths = _stringList(body['paths']);
    final candidate = ScrapeCandidate.fromJson(body['candidate']);
    if (paths.isEmpty || candidate == null) {
      await _sendError(request, HttpStatus.badRequest, 'bad_request',
          '需要 paths 与 candidate');
      return;
    }
    // 只接受片库里真实存在的路径，避免客户端写进任意键。
    final known = (await library.getAll()).map((e) => e.relativePath).toSet();
    final valid = paths.where(known.contains).toList();
    if (valid.isEmpty) {
      await _sendError(
          request, HttpStatus.notFound, 'not_found', '这些路径都不在片库里');
      return;
    }
    final outcome = await scrapeEngine.scrapeOne(
      paths: valid,
      candidate: candidate,
      query: body['query'] is String ? body['query']! as String : '',
      score: body['score'] is int ? body['score']! as int : 0,
      auto: false,
    );
    if (!outcome.ok) {
      await _sendError(request, HttpStatus.badGateway, 'scrape_failed',
          outcome.error ?? '刮削失败');
      return;
    }
    await _sendJson(request, HttpStatus.ok, {
      'ok': true,
      'count': outcome.paths.length,
      'record': outcome.record!.toJson(posterBase: '/api/v1/poster?name='),
    });
  }

  /// `POST /api/v1/scrape/auto`：对整库或指定路径批量自动匹配。
  Future<void> _handleScrapeAuto(HttpRequest request) async {
    final authDevice = await _requireAuth(request);
    if (config.pin.isNotEmpty && authDevice == null) return;
    if (request.method != 'POST') {
      await _sendError(
          request, HttpStatus.methodNotAllowed, 'method_not_allowed', '需要 POST');
      return;
    }
    if (!config.scrape.enabled) {
      await _sendError(
          request, HttpStatus.forbidden, 'scrape_disabled', '服务端已关闭刮削');
      return;
    }
    if (!config.scrape.autoMatch) {
      await _sendError(request, HttpStatus.forbidden, 'auto_disabled',
          '服务端已关闭自动匹配，请手动选择');
      return;
    }
    if (scrapeEngine.running) {
      await _sendError(
          request, HttpStatus.conflict, 'busy', '上一轮刮削还没跑完');
      return;
    }
    final body = await _readJsonBody(request) ?? const <String, Object?>{};
    final only = _stringList(body['paths']);
    final known = await library.getAll();
    final selected = only.isEmpty
        ? known
        : known.where((e) => only.contains(e.relativePath)).toList();
    if (selected.isEmpty) {
      await _sendError(
          request, HttpStatus.notFound, 'not_found', '没有可刮削的视频');
      return;
    }
    final groups = _scrapeFoldersOf(selected);
    // 几百次外部请求要跑几分钟，不能堵着响应。先回「已开始」，客户端再查
    // 状态；进度写到服务端日志里，排障时能看见卡在哪一部。
    unawaited(scrapeEngine.autoScrape(groups).then((report) {
      stderr.writeln(
          '[scrape] 自动匹配结束：扫 ${report.scanned}，采纳 ${report.matched}，'
          '跳过 ${report.skipped}，失败 ${report.failed}');
      for (final error in report.errors) {
        stderr.writeln('[scrape] $error');
      }
    }).catchError((Object error) {
      stderr.writeln('[scrape] 自动匹配异常: $error');
    }));
    await _sendJson(request, HttpStatus.accepted, {
      'ok': true,
      'started': true,
      'folders': groups.length,
    });
  }

  /// `POST /api/v1/scrape/clear`：清空全部刮削结果。
  Future<void> _handleScrapeClear(HttpRequest request) async {
    final authDevice = await _requireAuth(request);
    if (config.pin.isNotEmpty && authDevice == null) return;
    if (request.method != 'POST') {
      await _sendError(
          request, HttpStatus.methodNotAllowed, 'method_not_allowed', '需要 POST');
      return;
    }
    await scrapeEngine.clear();
    await _sendJson(request, HttpStatus.ok, {'ok': true});
  }

  /// `GET /api/v1/poster?name=`：发海报文件。
  ///
  /// 客户端不直连豆瓣/IMDb 的图床——它们校验 Referer，而且把这些地址暴露给
  /// 播放器没必要。海报在刮削时就落到本地，这里只做一次文件读取。
  Future<void> _handlePoster(HttpRequest request) async {
    final authDevice = await _requireAuth(request);
    if (config.pin.isNotEmpty && authDevice == null) return;
    final name = request.uri.queryParameters['name'] ?? '';
    final path = await scrapeEngine.posterPath(name);
    if (path == null) {
      await _sendError(request, HttpStatus.notFound, 'not_found', '海报不存在');
      return;
    }
    final file = File(path);
    final response = request.response;
    response.statusCode = HttpStatus.ok;
    response.headers.contentType = _imageContentType(name);
    // 海报文件按内容哈希命名，内容不会变，可以长缓存。
    response.headers.set('Cache-Control', 'public, max-age=604800');
    response.headers.contentLength = await file.length();
    await response.addStream(file.openRead());
    await response.close();
  }

  static ContentType _imageContentType(String name) {
    if (name.endsWith('.png')) return ContentType('image', 'png');
    if (name.endsWith('.webp')) return ContentType('image', 'webp');
    return ContentType('image', 'jpeg');
  }

  /// 把一批视频按「文件夹」归堆，作为自动刮削的输入。
  ///
  /// 与片库的分类规则一致：同一个文件夹里的视频属于同一部剧，只查一次。
  List<ScrapeFolder> _scrapeFoldersOf(List<MediaEntry> entries) {
    final rows = groupLibrary(entries);
    final folders = <ScrapeFolder>[];
    for (final row in rows) {
      final paths = row.videos.map((v) => v.relativePath).toList();
      if (paths.isEmpty) continue;
      folders.add(ScrapeFolder.of(
        name: row.name,
        paths: paths,
        isFolder: row.isDir,
      ));
    }
    return folders;
  }

  static List<String> _stringList(Object? raw) {
    if (raw is! List) return const [];
    return raw.whereType<String>().where((s) => s.trim().isNotEmpty).toList();
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
        compareNames(a['name']! as String, b['name']! as String);
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

  static String? _nonEmptyString(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
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
    trackPrefStore: TrackPrefStore.defaultStore(),
    serverId: serverId,
  );
  await server.start();
  return server;
}
