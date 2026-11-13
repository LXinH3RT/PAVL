/// 刮削用的 HTTP 层。
///
/// 只依赖 `dart:io` 的 [HttpClient]，不引第三方包——服务端除了排序用的拼音
/// 字典之外一直是零依赖，刮削不值得为它破例。
///
/// 这一层负责三件事：带超时的 GET、把结果当 JSON 或字节返回、按 URL 做短期
/// 缓存。重试与限速放在调用方，因为不同来源的容忍度不一样。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'provider.dart';

/// 抓取失败。
///
/// 带着「能不能重试」的判断：[retryable] 为真时通常是网络抖动或对方限流，
/// 换个时间点还有机会；为假一般是地址写错或对方明确拒绝，重试没意义。
class ScrapeHttpError implements Exception {
  ScrapeHttpError(this.message, {this.statusCode, this.retryable = false});

  final String message;
  final int? statusCode;
  final bool retryable;

  @override
  String toString() => 'ScrapeHttpError($message)';
}

/// 一条缓存记录。
class _Cached {
  _Cached(this.body, this.expiresAt);

  final String body;
  final DateTime expiresAt;

  bool get fresh => DateTime.now().isBefore(expiresAt);
}

/// 带缓存与超时的抓取器。
///
/// 缓存的意义不只是省流量：刮削时同一个关键词可能被电影与剧集各匹配一次，
/// 详情页也可能被界面反复打开。给一个几分钟的短缓存，用户来回点的时候就不
/// 会每次都打对方服务器——这既是礼貌，也是避免被限流的手段。
class ScrapeHttp implements ScrapeHttpLike {
  ScrapeHttp({this.timeout = const Duration(seconds: 10), this.cacheTtl = const Duration(minutes: 30)});

  /// 单次请求的超时。
  final Duration timeout;

  /// 成功响应的缓存时长。
  final Duration cacheTtl;

  final HttpClient _client = HttpClient()..connectionTimeout = const Duration(seconds: 8);

  final Map<String, _Cached> _cache = {};

  /// 已经发出去的请求数，用于诊断。
  int get requestCount => _requestCount;
  int _requestCount = 0;

  /// 取一张网页/接口，返回响应体文本。
  ///
  /// [headers] 里必须带对方要求的 `Referer`——豆瓣与 B站 都靠它过人机校验，
  /// 少了会拿到 403 或 412，而不是错误提示。
  Future<String> getText(
    String url, {
    Map<String, String>? headers,
    String? accept,
  }) async {
    final cacheKey = url;
    final cached = _cache[cacheKey];
    if (cached != null && cached.fresh) return cached.body;

    final body = await _fetch(url, headers: headers ?? const {}, accept: accept);
    _cache[cacheKey] = _Cached(body, DateTime.now().add(cacheTtl));
    _prune();
    return body;
  }

  /// 取 JSON。
  ///
  /// 有些接口（B站）会返回带 `\u0000` 或多余前缀的响应，先裁到第一个花括号
  /// 再解析，省得每个调用方各写一遍。
  Future<Object?> getJson(
    String url, {
    Map<String, String>? headers,
  }) async {
    final text = await getText(url, headers: headers, accept: 'application/json');
    final trimmed = _trimToJson(text);
    if (trimmed == null) {
      throw ScrapeHttpError('响应不是 JSON：${text.length} 字节');
    }
    try {
      return jsonDecode(trimmed);
    } on FormatException catch (error) {
      throw ScrapeHttpError('解析 JSON 失败：$error');
    }
  }

  /// 取二进制（海报）。
  ///
  /// 海报要落地成文件再由服务端自己发，不能把对方地址直接交给客户端：豆瓣与
  /// IMDb 的图床都看 `Referer`，客户端直连会 403。
  Future<List<int>> getBytes(
    String url, {
    Map<String, String> headers = const {},
  }) async {
    final merged = <String, String>{...headers};
    final request = await _open(url, merged, accept: 'image/*');
    try {
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw ScrapeHttpError('HTTP ${response.statusCode}',
            statusCode: response.statusCode,
            retryable: response.statusCode == 429 || response.statusCode >= 500);
      }
      final bytes = <int>[];
      await for (final chunk in response) {
        bytes.addAll(chunk);
      }
      if (bytes.isEmpty) throw ScrapeHttpError('空响应');
      return bytes;
    } finally {
      // HttpClient 的连接由内部池管理，这里不需要显式关闭。
    }
  }

  Future<String> _fetch(
    String url, {
    Map<String, String> headers = const {},
    String? accept,
  }) async {
    final request = await _open(url, headers, accept: accept);
    try {
      final response = await request.close();
      final status = response.statusCode;
      final body = await response.transform(utf8.decoder).join();
      if (status != HttpStatus.ok) {
        throw ScrapeHttpError(
          'HTTP $status',
          statusCode: status,
          retryable: status == 429 || status >= 500,
        );
      }
      return body;
    } on SocketException catch (error) {
      throw ScrapeHttpError('网络不通：${error.message}', retryable: true);
    } on TimeoutException {
      throw ScrapeHttpError('请求超时（${timeout.inSeconds} 秒）', retryable: true);
    }
  }

  Future<HttpClientRequest> _open(
    String url,
    Map<String, String> headers, {
    String? accept,
  }) async {
    _requestCount++;
    final uri = Uri.parse(url);
    final request = await _client.getUrl(uri).timeout(timeout);
    request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
    if (accept != null) request.headers.set(HttpHeaders.acceptHeader, accept);
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'gzip');
    headers.forEach(request.headers.set);
    return request;
  }

  /// 丢掉过期缓存，顺便防止长时间运行后无限增长。
  void _prune() {
    if (_cache.length < 256) return;
    _cache.removeWhere((_, value) => !value.fresh);
  }

  /// 清空缓存，强制下次重新抓。
  void clearCache() => _cache.clear();

  void close() {
    _cache.clear();
    _client.close(force: true);
  }

  /// 把响应裁成纯 JSON 文本。
  ///
  /// 有的接口在 JSON 前后挂了提示文字或 NUL 字节（B站的风控页、豆瓣的
  /// JSONP 包装都见过），所以不能直接 `jsonDecode` 整串。开头既可能是对象
  /// 也可能是数组——豆瓣的联想接口返回的就是 `[{...},{...}]`，只认花括号会
  /// 把整个数组当成非法响应。
  static String? _trimToJson(String text) {
    final objectAt = text.indexOf('{');
    final arrayAt = text.indexOf('[');
    int start;
    if (objectAt < 0) {
      start = arrayAt;
    } else if (arrayAt < 0) {
      start = objectAt;
    } else {
      start = objectAt < arrayAt ? objectAt : arrayAt;
    }
    if (start < 0) return null;

    // 结尾按开头类型找对应的那个字符：数组里也套着对象，
    // 一律找最后的 `}` 会把数组的 `]` 切掉。
    final end = text[start] == '['
        ? text.lastIndexOf(']')
        : text.lastIndexOf('}');
    if (end <= start) return null;
    return text.substring(start, end + 1);
  }

  /// 各来源都不拒绝的 UA。
  ///
  /// 用真实浏览器串而不是自报家门：豆瓣会对陌生 UA 直接丢到验证页，B站 会
  /// 返回 412。
  static const String _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
}
