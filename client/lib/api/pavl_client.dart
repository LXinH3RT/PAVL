/// 与服务端通信的协议层。
///
/// 这一层只认 HTTP 契约，不关心 UI。所有请求都经过 [PavlClient]，
/// 由它负责注入令牌、统一错误类型、把 JSON 转成强类型模型。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 服务端返回的错误。
class PavlApiError implements Exception {
  PavlApiError(this.statusCode, this.code, this.message);

  final int statusCode;
  final String code;
  final String message;

  /// 令牌失效，需要重新配对。
  bool get isUnauthorized => statusCode == 401;

  @override
  String toString() => 'PavlApiError($statusCode, $code: $message)';
}

/// 网络层错误（连不上、超时）。
class PavlNetworkError implements Exception {
  PavlNetworkError(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => message;
}

/// 发现到的服务器。
class DiscoveredServer {
  DiscoveredServer({
    required this.name,
    required this.host,
    required this.port,
    required this.version,
    required this.serverId,
    required this.requiresPairing,
  });

  final String name;
  final String host;
  final int port;
  final String version;
  final String serverId;
  final bool requiresPairing;

  String get baseUrl => 'http://$host:$port';

  @override
  String toString() => '$name ($baseUrl)';
}

/// 已保存的服务器连接信息。
class ServerConnection {
  ServerConnection({
    required this.serverId,
    required this.name,
    required this.host,
    required this.port,
    this.token,
  });

  final String serverId;
  final String name;
  final String host;
  final int port;
  final String? token;

  String get baseUrl => 'http://$host:$port';

  bool get paired => token != null && token!.isNotEmpty;

  /// 界面用的说法，与 [paired] 同义。
  bool get hasToken => paired;

  ServerConnection copyWith({
    String? name,
    String? host,
    int? port,
    String? token,
  }) =>
      ServerConnection(
        serverId: serverId,
        name: name ?? this.name,
        host: host ?? this.host,
        port: port ?? this.port,
        token: token ?? this.token,
      );

  Map<String, Object?> toJson() => {
        'serverId': serverId,
        'name': name,
        'host': host,
        'port': port,
        if (token != null) 'token': token,
      };

  static ServerConnection fromJson(Map<String, Object?> json) => ServerConnection(
        serverId: json['serverId'] as String? ?? '',
        name: json['name'] as String? ?? '未命名',
        host: json['host'] as String? ?? '',
        port: (json['port'] as num?)?.toInt() ?? 8765,
        token: json['token'] as String?,
      );
}

/// 目录列表里挂在视频下面的外挂字幕。
class BrowseSubtitle {
  BrowseSubtitle({
    required this.name,
    required this.path,
    required this.size,
    this.matched = true,
  });

  final String name;
  final String path;
  final int size;

  /// 是否按文件名匹配到了这个视频。
  final bool matched;

  static BrowseSubtitle fromJson(Map<String, Object?> json) => BrowseSubtitle(
        name: json['name'] as String? ?? '',
        path: json['path'] as String? ?? '',
        size: (json['size'] as num?)?.toInt() ?? 0,
        matched: json['unmatched'] != true,
      );
}

/// 浏览列表中的一项。
class BrowseEntry {
  BrowseEntry({
    required this.name,
    required this.path,
    required this.isDir,
    this.size = 0,
    this.mtime = 0,
    this.kind = 'other',
    this.children = 0,
    this.subtitles = const [],
  });

  final String name;
  final String path;
  final bool isDir;
  final int size;
  final int mtime;
  final String kind;
  final int children;

  /// 属于这个视频的外挂字幕，服务端已按文件名归好。
  final List<BrowseSubtitle> subtitles;

  static BrowseEntry fromJson(Map<String, Object?> json) => BrowseEntry(
        name: json['name'] as String? ?? '',
        path: json['path'] as String? ?? '',
        isDir: json['isDir'] as bool? ?? false,
        size: (json['size'] as num?)?.toInt() ?? 0,
        mtime: (json['mtime'] as num?)?.toInt() ?? 0,
        kind: json['kind'] as String? ?? 'other',
        children: (json['children'] as num?)?.toInt() ?? 0,
        subtitles: [
          for (final item in (json['subtitles'] as List<Object?>? ?? const []))
            if (item is Map<String, Object?>) BrowseSubtitle.fromJson(item),
        ],
      );
}

/// 片库里的一个条目（与 [BrowseEntry] 的区别是不含目录信息）。
class MediaEntry {
  MediaEntry({
    required this.path,
    required this.name,
    this.size = 0,
    this.mtime = 0,
    this.kind = 'video',
    this.title = '',
    this.year,
    this.season,
    this.episode,
  });

  final String path;
  final String name;
  final int size;
  final int mtime;
  final String kind;

  /// 从文件名里解析出来的可读标题。
  final String title;
  final int? year;
  final int? season;
  final int? episode;

  static MediaEntry fromJson(Map<String, Object?> json) => MediaEntry(
        path: json['path'] as String? ?? '',
        name: json['name'] as String? ?? '',
        size: (json['size'] as num?)?.toInt() ?? 0,
        mtime: (json['mtime'] as num?)?.toInt() ?? 0,
        kind: json['kind'] as String? ?? 'video',
        title: json['title'] as String? ?? '',
        year: (json['year'] as num?)?.toInt(),
        season: (json['season'] as num?)?.toInt(),
        episode: (json['episode'] as num?)?.toInt(),
      );

  /// 显示用的标题：解析不出可读标题时退回文件名。
  String get displayTitle => title.isEmpty ? name : title;

  /// 季集标签，`S01E02` / `第 2 季第 10 集`，缺信息时为空串。
  String get episodeLabel {
    final hasSeason = season != null && season! > 0;
    final hasEpisode = episode != null && episode! > 0;
    if (!hasSeason && !hasEpisode) return '';
    final buffer = StringBuffer();
    if (hasSeason) buffer.write('第 $season 季');
    if (hasEpisode) {
      if (buffer.isNotEmpty) buffer.write(' ');
      buffer.write('第 $episode 集');
    }
    return buffer.toString();
  }
}

/// 片库的一页。
///
/// 除了当前页的条目，还带总数与是否还有下一页——分页控件要靠这两个字段决定
/// 按钮可用状态，只靠「这一页拿满了 60 条」来推断会在整页刚好够数时多翻一次
/// 空页。
class LibraryPage {
  LibraryPage({
    required this.items,
    required this.total,
    required this.page,
    required this.pageSize,
    required this.hasMore,
  });

  final List<MediaEntry> items;
  final int total;
  final int page;
  final int pageSize;
  final bool hasMore;

  static LibraryPage fromJson(Map<String, Object?> json) {
    final raw = json['items'] as List<Object?>? ?? const [];
    return LibraryPage(
      items: [
        for (final item in raw)
          if (item is Map<String, Object?>) MediaEntry.fromJson(item),
      ],
      total: (json['total'] as num?)?.toInt() ?? 0,
      page: (json['page'] as num?)?.toInt() ?? 1,
      pageSize: (json['pageSize'] as num?)?.toInt() ?? 60,
      hasMore: json['hasMore'] as bool? ?? false,
    );
  }

  static final LibraryPage empty = LibraryPage(
    items: const [],
    total: 0,
    page: 1,
    pageSize: 60,
    hasMore: false,
  );
}

/// 一条播放进度。
class ProgressRecord {
  ProgressRecord({
    required this.position,
    required this.duration,
    this.finished = false,
    this.updatedAt = 0,
    this.deviceName = '',
  });

  /// 秒。
  final double position;

  /// 秒。
  final double duration;
  final bool finished;
  final int updatedAt;

  /// 写这条记录的设备名；服务端未记录时为空串。
  final String deviceName;

  /// 已看比例，0–1。
  double get ratio {
    if (duration <= 0) return 0;
    return (position / duration).clamp(0.0, 1.0);
  }

  /// 是否值得问一句「要不要接着看」。
  ///
  /// 刚开始看（前 5 秒）、已经看完、或者已经看到 95% 以上都不问。
  bool get worthResuming => !finished && position > 5 && ratio < 0.95;

  static ProgressRecord? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    return ProgressRecord(
      position: (json['position'] as num?)?.toDouble() ?? 0,
      duration: (json['duration'] as num?)?.toDouble() ?? 0,
      finished: json['finished'] as bool? ?? false,
      updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
      deviceName: json['deviceName'] as String? ?? '',
    );
  }
}

/// 最近播放列表里的一条。
///
/// 服务端只存了进度（路径、位置、时长、更新时间），没有标题与文件名，所以
/// 界面上要显示可读名称时得自己从路径里截——这里提供 [displayName] 做这件事，
/// 免得到处重复写字符串处理。
class RecentEntry {
  RecentEntry({
    required this.path,
    required this.position,
    required this.duration,
    this.finished = false,
    this.updatedAt = 0,
    this.deviceName = '',
  });

  final String path;
  final double position;
  final double duration;
  final bool finished;
  final int updatedAt;
  final String deviceName;

  /// 已看比例，0–1。
  double get ratio {
    if (duration <= 0) return 0;
    return (position / duration).clamp(0.0, 1.0);
  }

  /// 路径末段。`电影/某片.mkv` → `某片.mkv`。
  String get displayName {
    final idx = path.lastIndexOf('/');
    return idx < 0 ? path : path.substring(idx + 1);
  }

  /// 上一级目录，用于在最近列表里补充位置信息。
  String get parentPath {
    final idx = path.lastIndexOf('/');
    return idx < 0 ? '' : path.substring(0, idx);
  }

  static RecentEntry fromJson(Map<String, Object?> json) => RecentEntry(
        path: json['path'] as String? ?? '',
        position: (json['position'] as num?)?.toDouble() ?? 0,
        duration: (json['duration'] as num?)?.toDouble() ?? 0,
        finished: json['finished'] as bool? ?? false,
        updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
        deviceName: json['deviceName'] as String? ?? '',
      );
}

/// 与某个视频关联的外挂字幕。
class SidecarSubtitle {  SidecarSubtitle({
    required this.name,
    required this.path,
    this.size = 0,
    this.matched = true,
  });

  final String name;
  final String path;
  final int size;

  /// 是否按文件名匹配到了这个视频。
  final bool matched;

  /// 服务端虽归到了这个视频名下，但文件名对不上（目录里只有一部片时的兜底）。
  bool get sibling => !matched;

  static SidecarSubtitle fromJson(Map<String, Object?> json) => SidecarSubtitle(
        name: json['name'] as String? ?? '',
        path: json['path'] as String? ?? '',
        size: (json['size'] as num?)?.toInt() ?? 0,
        matched: (json['match'] as String? ?? 'exact') != 'none',
      );
}

/// 播放一个视频之前需要知道的全部信息。
class MediaDetail {
  MediaDetail({
    required this.path,
    required this.name,
    this.size = 0,
    this.mtime = 0,
    this.title = '',
    this.year,
    this.season,
    this.episode,
    this.meta,
    this.progress,
    this.subtitles = const [],
  });

  final String path;
  final String name;
  final int size;
  final int mtime;
  final String title;
  final int? year;
  final int? season;
  final int? episode;

  /// 客户端历史上回写过的媒体信息，可能为空。
  final Map<String, Object?>? meta;

  /// 服务端记的最近一次播放进度（顶层口径，可能来自别的设备）。
  final ProgressRecord? progress;

  /// 同目录下的外挂字幕。
  final List<SidecarSubtitle> subtitles;

  static MediaDetail fromJson(Map<String, Object?> json) => MediaDetail(
        path: json['path'] as String? ?? '',
        name: json['name'] as String? ?? '',
        size: (json['size'] as num?)?.toInt() ?? 0,
        mtime: (json['mtime'] as num?)?.toInt() ?? 0,
        title: json['title'] as String? ?? '',
        year: (json['year'] as num?)?.toInt(),
        season: (json['season'] as num?)?.toInt(),
        episode: (json['episode'] as num?)?.toInt(),
        meta: json['meta'] is Map<String, Object?>
            ? json['meta'] as Map<String, Object?>
            : null,
        progress: ProgressRecord.fromJson(json['progress']),
        subtitles: [
          for (final item in (json['subtitles'] as List<Object?>? ?? const []))
            if (item is Map<String, Object?>) SidecarSubtitle.fromJson(item),
        ],
      );
}

/// 与服务端通信的客户端。
///
/// 除了 [pair]，所有请求都会带上 [ServerConnection.token]。
class PavlClient {
  PavlClient({required this.connection, HttpClient? httpClient})
      : _http = httpClient ?? HttpClient() {
    _http.connectionTimeout = const Duration(seconds: 6);
  }

  final ServerConnection connection;
  final HttpClient _http;

  /// 播放器要用的请求头（libmpv 只认 URL 和请求头）。
  Map<String, String> get mediaHeaders {
    final token = connection.token;
    if (token == null || token.isEmpty) return const {};
    return {'Authorization': 'Bearer $token'};
  }

  /// 视频流地址。
  Uri streamUri(String path) => Uri.parse('${connection.baseUrl}/api/v1/stream')
      .replace(queryParameters: {'path': path});

  /// 外挂字幕地址。
  ///
  /// libmpv 加载外挂字幕时只拿得到一个 URL，带不了请求头，所以令牌
  /// 放在查询参数里由服务端认。
  Uri subtitleUri(String path) {
    final token = connection.token;
    return Uri.parse('${connection.baseUrl}/api/v1/subtitle').replace(
      queryParameters: {
        'path': path,
        if (token != null && token.isNotEmpty) 'token': token,
      },
    );
  }

  /// 服务器基本信息，不需要配对。
  Future<Map<String, Object?>> info() async =>
      _getJson('/api/v1/info', auth: false);

  /// 用 PIN 换一个长期令牌。
  ///
  /// [platform] 必填而不是给默认值：客户端要同时跑在 Windows 与 macOS 上，
  /// 留一个 `'windows'` 的默认值，漏传时服务端设备列表里就会把 Mac 显示成
  /// Windows，而且这种错误不会报错，只能靠人看。调用方一律传
  /// `platformTag`（见 `util/platform_support.dart`）。
  Future<String> pair({
    required String pin,
    required String deviceId,
    required String deviceName,
    required String platform,
  }) async {
    final json = await _postJson('/api/v1/pair', {
      'pin': pin,
      'deviceId': deviceId,
      'deviceName': deviceName,
      'platform': platform,
    }, auth: false);
    final token = json['token'] as String?;
    if (token == null || token.isEmpty) {
      throw PavlApiError(200, 'no_token', '服务端没有返回令牌');
    }
    return token;
  }

  /// 列一层目录。
  Future<List<BrowseEntry>> browse(String path) async {
    final json = await _getJson('/api/v1/browse', query: {'path': path});
    final items = json['entries'] as List<Object?>? ?? const [];
    return [
      for (final item in items)
        if (item is Map<String, Object?>) BrowseEntry.fromJson(item),
    ];
  }

  /// 片库分页列表。
  ///
  /// 顺序由服务端决定（按标题的自然序，汉字按拼音），客户端不再重排：分页
  /// 是把全库切片之后再发过来的，客户端若只对当前页排序，跨页的顺序就会乱。
  Future<LibraryPage> library({
    int page = 1,
    int pageSize = 60,
    String? query,
    String? kind,
  }) async {
    final json = await _getJson('/api/v1/library', query: {
      'page': '$page',
      'pageSize': '$pageSize',
      if (query != null && query.isNotEmpty) 'q': query,
      if (kind != null && kind.isNotEmpty) 'kind': kind,
    });
    return LibraryPage.fromJson(json);
  }

  /// 单个视频的详情（含外挂字幕与最近进度）。
  Future<MediaDetail> media(String path) async {
    final json = await _getJson('/api/v1/media', query: {'path': path});
    return MediaDetail.fromJson(json);
  }

  /// 读进度；带 [deviceId] 时只读这台设备的记录。
  Future<ProgressRecord?> getProgress(String path, {String? deviceId}) async {
    final json = await _getJson('/api/v1/progress', query: {
      'path': path,
      if (deviceId != null && deviceId.isNotEmpty) 'device': deviceId,
    });
    return ProgressRecord.fromJson(json['progress']);
  }

  /// 写进度。
  Future<void> putProgress({
    required String path,
    required double position,
    required double duration,
    bool finished = false,
  }) async {
    await _postJson('/api/v1/progress', {
      'path': path,
      'position': position,
      'duration': duration,
      'finished': finished,
    });
  }

  /// 回写媒体信息（服务端不装 ffprobe，只能由客户端提供）。
  Future<void> putMeta(String path, Map<String, Object?> meta) async {
    await _postJson('/api/v1/media/meta', {'path': path, ...meta});
  }

  /// 最近播放列表。
  ///
  /// 服务端按最后更新时间倒序返回，每条形如
  /// `{path, position, duration, finished, updatedAt, deviceName?}`。
  Future<List<RecentEntry>> recent({int limit = 20}) async {
    final json = await _getJson('/api/v1/recent', query: {'limit': '$limit'});
    final items = json['items'] as List<Object?>? ?? const [];
    return [
      for (final item in items)
        if (item is Map<String, Object?>) RecentEntry.fromJson(item),
    ];
  }

  /// 让服务端丢掉目录缓存并重新扫描，返回扫到的视频总数。
  ///
  /// 服务端有两层缓存：目录项列表，以及「这棵子树里到底有没有媒体」的探测
  /// 结果（五分钟）。后者决定空目录要不要出现在列表里，所以刚加进共享列表
  /// 的文件夹，或者刚往里拷了影片的目录，都要等缓存过期才会冒出来。只重新
  /// 拉一次列表解决不了这个问题——那只是把同一份缓存的结论再读一遍，必须
  /// 显式让服务端作废缓存。
  Future<int> refresh() async {
    final json = await _postJson('/api/v1/refresh', const {});
    return (json['count'] as num?)?.toInt() ?? 0;
  }

  void close() => _http.close(force: true);

  // ---------------------------------------------------------------- 内部

  Future<Map<String, Object?>> _getJson(
    String path, {
    Map<String, String>? query,
    bool auth = true,
  }) =>
      _send('GET', path, query: query, auth: auth);

  Future<Map<String, Object?>> _postJson(
    String path,
    Map<String, Object?> body, {
    bool auth = true,
  }) =>
      _send('POST', path, body: body, auth: auth);

  Future<Map<String, Object?>> _send(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, Object?>? body,
    bool auth = true,
  }) async {
    final uri = Uri.parse('${connection.baseUrl}$path')
        .replace(queryParameters: query == null || query.isEmpty ? null : query);

    final HttpClientRequest request;
    try {
      request = await _http.openUrl(method, uri);
    } on SocketException catch (error) {
      throw PavlNetworkError('连不上服务器 ${connection.host}:${connection.port}', error);
    } on HttpException catch (error) {
      throw PavlNetworkError('请求失败：${error.message}', error);
    }

    final token = connection.token;
    if (auth && token != null && token.isNotEmpty) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }

    final HttpClientResponse response;
    try {
      response = await request.close();
    } on SocketException catch (error) {
      throw PavlNetworkError('连接被中断', error);
    } on HttpException catch (error) {
      throw PavlNetworkError('请求失败：${error.message}', error);
    }

    final text = await response.transform(utf8.decoder).join();
    Object? decoded;
    if (text.isNotEmpty) {
      try {
        decoded = jsonDecode(text);
      } on FormatException {
        decoded = null;
      }
    }

    if (response.statusCode >= 400) {
      final map = decoded is Map<String, Object?> ? decoded : const <String, Object?>{};
      throw PavlApiError(
        response.statusCode,
        map['error'] as String? ?? 'http_${response.statusCode}',
        map['message'] as String? ?? '请求失败（HTTP ${response.statusCode}）',
      );
    }

    if (decoded is Map<String, Object?>) return decoded;
    return <String, Object?>{};
  }
}
