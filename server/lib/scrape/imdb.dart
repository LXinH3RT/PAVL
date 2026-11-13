/// IMDb 刮削。
///
/// IMDb 拿数据的路径跟豆瓣完全不一样：它的网页与 GraphQL 都对非浏览器请求
/// 关门（详情页回 202 空响应），但有两组公开接口一直可用——
///
///   - 联想接口 `v2.sg.media-imdb.com/suggestion`：按关键词给出候选，带
///     `tt` 编号、标题、年份、演员、封面；
///   - 元数据接口 `v3-cinemeta.strem.io/meta`：按 `tt` 编号取完整信息。
///
/// 两组接口都不校验 Referer，但对中文关键词的支持有限——中文片名往往查不到
/// 东西，所以 IMDb 在这个项目里主要是「英文文件夹名」的兜底源。
library;

import 'models.dart';
import 'provider.dart';

/// IMDb 的数据来源。
class ImdbProvider extends ScrapeProvider {
  ImdbProvider(super.http);

  @override
  ScrapeSource get source => ScrapeSource.imdb;

  @override
  Future<List<ScrapeCandidate>> search(String keyword) async {
    final query = keyword.trim();
    if (query.isEmpty) return const [];
    // 接口对空格敏感，空格必须编码成 %20；用 encodeQueryComponent 会把空格
    // 变成 '+'，那个它在路径段里不认，会当成标题的一部分。
    final url =
        'https://v2.sg.media-imdb.com/suggestion/x/${Uri.encodeComponent(query)}.json';
    final decoded = await http.getJson(url);
    if (decoded is! Map) return const [];
    final list = decoded['d'];
    if (list is! List) return const [];
    final out = <ScrapeCandidate>[];
    for (final item in list) {
      if (item is! Map) continue;
      final id = _str(item['id']);
      final title = _str(item['l']);
      if (id == null || title == null) continue;
      // 只留作品，`qid` 是 person/episode 之类的就别放进来了。
      final qid = _str(item['qid']);
      if (qid != null && qid != 'movie' && qid != 'tvSeries' && qid != 'tvMiniSeries') {
        continue;
      }
      final year = _int(item['y']);
      // `q` 是 feature / TV series 之类的粗分类，`qid` 更精确。
      final kind = qid == 'movie'
          ? ScrapeKind.movie
          : (qid == 'tvSeries' || qid == 'tvMiniSeries'
              ? ScrapeKind.tv
              : _kindOfLabel(_str(item['q'])));
      String? poster;
      final image = item['i'];
      if (image is Map) {
        poster = _str(image['imageUrl']);
      }
      final cast = _str(item['s']);
      out.add(ScrapeCandidate(
        source: wireName,
        id: id,
        title: title,
        year: year,
        kind: kind,
        poster: poster,
        hint: _hintOf(year: year, cast: cast),
      ));
    }
    return out;
  }

  @override
  Future<ScrapeDetail> detail(String id,
      {ScrapeKind kind = ScrapeKind.unknown}) async {
    // cinemeta 的 movie / series 是两个路径，且猜错不会跳转，直接 404。
    final order = kind == ScrapeKind.tv
        ? const ['series', 'movie']
        : const ['movie', 'series'];
    Object? failure;
    for (final type in order) {
      try {
        final decoded =
            await http.getJson('https://v3-cinemeta.strem.io/meta/$type/$id.json');
        if (decoded is! Map) continue;
        final meta = decoded['meta'];
        if (meta is! Map) continue;
        return _toDetail(id, meta.cast<String, Object?>(), type);
      } on Object catch (error) {
        failure = error;
      }
    }
    throw StateError('IMDb 详情取不到：$id${failure == null ? '' : '（$failure）'}');
  }

  ScrapeDetail _toDetail(
      String id, Map<String, Object?> json, String type) {
    final runtime = _str(json['runtime']);
    final genres = _strList(json['genres']);
    if (genres.isEmpty) {
      final single = _str(json['genre']);
      if (single != null) genres.add(single);
    }
    final country = _str(json['country']);
    return ScrapeDetail(
      source: wireName,
      id: id,
      title: _str(json['name']) ?? '',
      originalTitle: _str(json['originalName']),
      year: _int(json['year']) ?? _yearOfLabel(_str(json['releaseInfo'])),
      kind: type == 'series' ? ScrapeKind.tv : ScrapeKind.movie,
      poster: _str(json['poster']),
      intro: _str(json['description']),
      rating: _double(json['imdbRating']),
      genres: genres,
      countries: country == null ? const [] : [country],
      durations: runtime == null ? const [] : [runtime],
      directors: _strList(json['director']),
      actors: _strList(json['cast']),
      releaseDate: _str(json['released']) ?? _str(json['releaseInfo']),
    );
  }

  static ScrapeKind _kindOfLabel(String? label) {
    if (label == null) return ScrapeKind.unknown;
    final lower = label.toLowerCase();
    if (lower.contains('series') || lower.contains('tv')) return ScrapeKind.tv;
    if (lower.contains('feature') || lower.contains('movie')) {
      return ScrapeKind.movie;
    }
    return ScrapeKind.unknown;
  }

  static int? _yearOfLabel(String? label) {
    if (label == null) return null;
    final match = RegExp(r'(19|20)\d{2}').firstMatch(label);
    return match == null ? null : int.tryParse(match.group(0)!);
  }

  static String? _hintOf({int? year, String? cast}) {
    final parts = <String>[];
    if (year != null) parts.add('$year');
    if (cast != null && cast.isNotEmpty) parts.add(cast);
    return parts.isEmpty ? null : parts.join(' · ');
  }

  static String? _str(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static int? _int(Object? value) {
    if (value is int) return value;
    if (value is double) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  static double? _double(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value.trim());
    return null;
  }

  static List<String> _strList(Object? raw) {
    if (raw is! List) return [];
    final out = <String>[];
    for (final item in raw) {
      if (item is String && item.trim().isNotEmpty) out.add(item.trim());
    }
    return out;
  }
}
