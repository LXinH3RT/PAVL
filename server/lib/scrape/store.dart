/// 刮削结果与海报的落地存储。
///
/// 刮到的信息必须落盘，否则每次刷新片库都要重新联网：一个几十部的片库就是
/// 上百次请求，既慢又容易被对方限流。
///
/// 存两份东西：
///   - `scrape.json`：路径 → 刮削结果（标题、简介、评分等纯文本）；
///   - `posters/`：海报图片文件，文件名为内容哈希，天然去重。
///
/// 海报不存对方地址而存文件，是因为豆瓣、IMDb 的图床都校验 Referer，客户端
/// 直连会 403。落成本地文件之后由服务端自己发，客户端只要一个普通地址。
library;

import 'dart:convert';
import 'dart:io';

import '../config.dart';
import 'models.dart';

/// 一条刮削记录。
class ScrapeRecord {
  ScrapeRecord({
    required this.source,
    required this.id,
    required this.title,
    this.originalTitle,
    this.year,
    this.kind = ScrapeKind.unknown,
    this.poster,
    this.intro,
    this.rating,
    this.ratingCount,
    this.genres = const [],
    this.countries = const [],
    this.durations = const [],
    this.directors = const [],
    this.actors = const [],
    this.episodeCount,
    this.releaseDate,
    this.query = '',
    this.score = 0,
    this.auto = true,
    this.matchedAt = 0,
  });

  final String source;
  final String id;
  final String title;
  final String? originalTitle;
  final int? year;
  final ScrapeKind kind;

  /// 海报文件名（相对 `posters/` 目录），没有海报时为 null。
  final String? poster;

  final String? intro;
  final double? rating;
  final int? ratingCount;
  final List<String> genres;
  final List<String> countries;
  final List<String> durations;
  final List<String> directors;
  final List<String> actors;
  final int? episodeCount;
  final String? releaseDate;

  /// 实际用来查询的关键词。
  final String query;

  /// 匹配得分。
  final int score;

  /// 是否自动采纳。手动指定的记录 auto 为 false，之后的自动刮削不会覆盖它。
  final bool auto;

  /// 刮削时间，Unix 毫秒。
  final int matchedAt;

  ScrapeRecord copyWith({String? poster, bool? auto, int? matchedAt}) =>
      ScrapeRecord(
        source: source,
        id: id,
        title: title,
        originalTitle: originalTitle,
        year: year,
        kind: kind,
        poster: poster ?? this.poster,
        intro: intro,
        rating: rating,
        ratingCount: ratingCount,
        genres: genres,
        countries: countries,
        durations: durations,
        directors: directors,
        actors: actors,
        episodeCount: episodeCount,
        releaseDate: releaseDate,
        query: query,
        score: score,
        auto: auto ?? this.auto,
        matchedAt: matchedAt ?? this.matchedAt,
      );

  /// 转成对外 JSON。
  ///
  /// [posterBase] 是海报的访问前缀（`/api/v1/poster?name=`），拼上文件名才是
  /// 客户端能直接用的地址。
  Map<String, Object?> toJson({String? posterBase}) {
    final detail = ScrapeDetail(
      source: source,
      id: id,
      title: title,
      originalTitle: originalTitle,
      year: year,
      kind: kind,
      intro: intro,
      rating: rating,
      ratingCount: ratingCount,
      genres: genres,
      countries: countries,
      durations: durations,
      directors: directors,
      actors: actors,
      episodeCount: episodeCount,
      releaseDate: releaseDate,
    );
    return {
      ...detail.toJson(),
      if (poster != null && posterBase != null) 'posterUrl': '$posterBase$poster',
      'query': query,
      'score': score,
      'auto': auto,
      'matchedAt': matchedAt,
    };
  }

  Map<String, Object?> toStorage() => {
        'source': source,
        'id': id,
        'title': title,
        if (originalTitle != null) 'originalTitle': originalTitle,
        if (year != null) 'year': year,
        'kind': kind.name,
        if (poster != null) 'poster': poster,
        if (intro != null) 'intro': intro,
        if (rating != null) 'rating': rating,
        if (ratingCount != null) 'ratingCount': ratingCount,
        if (genres.isNotEmpty) 'genres': genres,
        if (countries.isNotEmpty) 'countries': countries,
        if (durations.isNotEmpty) 'durations': durations,
        if (directors.isNotEmpty) 'directors': directors,
        if (actors.isNotEmpty) 'actors': actors,
        if (episodeCount != null) 'episodeCount': episodeCount,
        if (releaseDate != null) 'releaseDate': releaseDate,
        'query': query,
        'score': score,
        'auto': auto,
        'matchedAt': matchedAt,
      };

  static ScrapeRecord? fromStorage(Object? raw) {
    if (raw is! Map) return null;
    final source = raw['source'];
    final id = raw['id'];
    final title = raw['title'];
    if (source is! String || id is! String || title is! String) return null;
    return ScrapeRecord(
      source: source,
      id: id,
      title: title,
      originalTitle: _str(raw['originalTitle']),
      year: _int(raw['year']),
      kind: ScrapeKind.parse(_str(raw['kind'])),
      poster: _str(raw['poster']),
      intro: _str(raw['intro']),
      rating: _double(raw['rating']),
      ratingCount: _int(raw['ratingCount']),
      genres: _strList(raw['genres']),
      countries: _strList(raw['countries']),
      durations: _strList(raw['durations']),
      directors: _strList(raw['directors']),
      actors: _strList(raw['actors']),
      episodeCount: _int(raw['episodeCount']),
      releaseDate: _str(raw['releaseDate']),
      query: _str(raw['query']) ?? '',
      score: _int(raw['score']) ?? 0,
      auto: raw['auto'] is bool ? raw['auto']! as bool : true,
      matchedAt: _int(raw['matchedAt']) ?? 0,
    );
  }

  static String? _str(Object? value) =>
      value is String && value.trim().isNotEmpty ? value.trim() : null;

  static int? _int(Object? value) {
    if (value is int) return value;
    if (value is double) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  static double? _double(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  static List<String> _strList(Object? raw) {
    if (raw is! List) return const [];
    return raw.whereType<String>().where((s) => s.trim().isNotEmpty).toList();
  }
}

/// 刮削结果的存储。
class ScrapeStore {
  ScrapeStore(this.file, this.posterDir);

  /// `scrape.json` 的路径。
  final File file;

  /// 海报目录。
  final Directory posterDir;

  Map<String, ScrapeRecord>? _cache;

  static ScrapeStore defaultStore() {
    final dir = ConfigStore.resolveConfigDir();
    return ScrapeStore(
      File('${dir.path}${Platform.pathSeparator}scrape.json'),
      Directory('${dir.path}${Platform.pathSeparator}posters'),
    );
  }

  Future<Map<String, ScrapeRecord>> _load() async {
    final cached = _cache;
    if (cached != null) return cached;
    final map = <String, ScrapeRecord>{};
    if (await file.exists()) {
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map) {
          final entries = decoded['entries'];
          if (entries is Map) {
            entries.forEach((key, value) {
              if (key is! String) return;
              final record = ScrapeRecord.fromStorage(value);
              if (record != null) map[key] = record;
            });
          }
        }
      } on FormatException {
        // 损坏就从空开始，下一次刮削会重新写。
      }
    }
    _cache = map;
    return map;
  }

  /// 取某条路径的记录。
  Future<ScrapeRecord?> get(String path) async {
    final map = await _load();
    return map[path];
  }

  /// 一次取多条，避免上层为每个文件夹都 await 一次。
  Future<Map<String, ScrapeRecord>> getMany(Iterable<String> paths) async {
    final map = await _load();
    final out = <String, ScrapeRecord>{};
    for (final path in paths) {
      final record = map[path];
      if (record != null) out[path] = record;
    }
    return out;
  }

  /// 全部记录，用于「已刮削」统计。
  Future<int> count() async => (await _load()).length;

  /// 写入一条。
  Future<void> put(String path, ScrapeRecord record) async {
    final map = await _load();
    map[path] = record;
    await _flush(map);
  }

  /// 批量写入，一次落盘。
  Future<void> putAll(Map<String, ScrapeRecord> records) async {
    if (records.isEmpty) return;
    final map = await _load();
    map.addAll(records);
    await _flush(map);
  }

  /// 删掉一条（清空海报引用由调用方负责）。
  Future<void> remove(String path) async {
    final map = await _load();
    if (map.remove(path) == null) return;
    await _flush(map);
  }

  /// 清空全部记录，同时尝试删掉海报文件。
  ///
  /// 海报按内容哈希命名，可能被多条记录共用，所以只在清空全部时才能整目录
  /// 删；单条删除时留着文件，下次刮到同一部片还能直接复用。
  Future<void> clear() async {
    _cache = {};
    await _flush(_cache!);
    try {
      if (await posterDir.exists()) {
        await posterDir.delete(recursive: true);
      }
    } on FileSystemException {
      // 删不掉就留着，不影响下一次刮削。
    }
  }

  /// 把海报字节写进 `posters/`，返回文件名。
  ///
  /// 文件名用内容哈希，同一张图重复下载只会留一份。
  Future<String?> savePoster(List<int> bytes, {String? sourceId}) async {
    if (bytes.isEmpty) return null;
    await posterDir.create(recursive: true);
    final name = '${_hashOf(bytes, sourceId)}${_extensionOf(bytes)}';
    final target = File('${posterDir.path}${Platform.pathSeparator}$name');
    if (!await target.exists()) {
      final tmp = File('${target.path}.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(target.path);
    }
    return name;
  }

  /// 海报文件的绝对路径，不存在时返回 null。
  Future<String?> posterPath(String name) async {
    // 文件名只允许字母数字与点，杜绝 `../` 之类的路径穿越。
    if (!RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(name)) return null;
    final file = File('${posterDir.path}${Platform.pathSeparator}$name');
    if (!await file.exists()) return null;
    return file.path;
  }

  Future<void> _flush(Map<String, ScrapeRecord> map) async {
    await file.parent.create(recursive: true);
    final payload = <String, Object?>{
      'version': 1,
      'entries': map.map((key, value) => MapEntry(key, value.toStorage())),
    };
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(payload), flush: true);
    await tmp.rename(file.path);
  }

  /// 内容哈希：用源 id 参与，避免两张不同的图撞名。
  ///
  /// 不用加密哈希，FNV-1a 足够区分海报，也省掉算 CRC32 的额外实现。
  static String _hashOf(List<int> bytes, String? sourceId) {
    var hash = 0x811c9dc5;
    for (final byte in bytes) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    final prefix = (sourceId ?? '').replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    final suffix = hash.toRadixString(16).padLeft(8, '0');
    return prefix.isEmpty ? 'p$suffix' : '$prefix-$suffix';
  }

  /// 按文件头猜扩展名，猜不出按 jpg 存。
  ///
  /// 扩展名只影响服务端回 Content-Type，猜错最多是一次 MIME 不对，不影响显示。
  static String _extensionOf(List<int> bytes) {
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return '.png';
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return '.jpg';
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46) {
      return '.webp';
    }
    return '.jpg';
  }
}
