/// 豆瓣刮削。
///
/// 豆瓣是三个来源里中文信息最全的一个：评分、人数、简介、分类、国家、时长、
/// 导演与演员都有现成字段。
///
/// 有一点必须记住：**网页版详情页进不去**。`movie.douban.com/subject/<id>/`
/// 会被反爬重定向到 `sec.douban.com` 的验证页，就算把浏览器的那套请求头全
/// 带上也过不去。可用的只有移动端的 rexxar 接口，它对 `Referer` 的要求很
/// 宽松但**必须不是空的**，否则一样被挡。
library;

import 'models.dart';
import 'provider.dart';

/// 豆瓣的数据来源。
class DoubanProvider extends ScrapeProvider {
  DoubanProvider(super.http);

  @override
  ScrapeSource get source => ScrapeSource.douban;

  /// 详情接口要求的 Referer。
  ///
  /// 用移动端域名而不是 `movie.douban.com`：接口本身挂在移动站下，带别的站
  /// 的 Referer 会被当成盗链。
  static const Map<String, String> _detailHeaders = {
    'Referer': 'https://m.douban.com/',
  };

  @override
  Future<List<ScrapeCandidate>> search(String keyword) async {
    if (keyword.trim().isEmpty) return const [];
    final url =
        'https://movie.douban.com/j/subject_suggest?q=${Uri.encodeQueryComponent(keyword)}';
    final decoded = await http.getJson(url);
    if (decoded is! List) return const [];
    final out = <ScrapeCandidate>[];
    for (final item in decoded) {
      if (item is! Map) continue;
      final id = _str(item['id']);
      final title = _str(item['title']);
      if (id == null || title == null) continue;
      final year = _int(item['year']);
      // suggest 用 `type=movie|tv` 区分，但很多剧集被标成 movie，不能全信；
      // 有 episode 字段说明它是多集，这才是可靠的剧集信号。
      final episodes = _int(item['episode']);
      final declared = ScrapeKind.parse(_str(item['type']));
      final kind = episodes != null && episodes > 1
          ? ScrapeKind.tv
          : (declared == ScrapeKind.movie && episodes == null
              ? ScrapeKind.movie
              : declared);
      out.add(ScrapeCandidate(
        source: wireName,
        id: id,
        title: title,
        originalTitle: _str(item['sub_title']),
        year: year,
        kind: kind,
        poster: _str(item['img']),
        // 副标题凑出「年份 · 原名」，界面上灰字显示，方便同名作品区分。
        hint: _hintOf(year: year, originalTitle: _str(item['sub_title'])),
        episodeCount: episodes,
      ));
    }
    return out;
  }

  @override
  Future<ScrapeDetail> detail(String id,
      {ScrapeKind kind = ScrapeKind.unknown}) async {
    // movie 与 tv 是两个路径，猜错会拿到 301。接口在换路径时会回一个很小的
    // 跳转提示页而不是 JSON，所以这里按已知类型直接走对的那条，未知就两条都
    // 试一遍。
    final path = kind == ScrapeKind.tv ? 'tv' : 'movie';
    final decoded = await _getDetail(path, id);
    if (decoded != null) return _toDetail(id, decoded);
    if (kind == ScrapeKind.unknown) {
      final other = await _getDetail(path == 'movie' ? 'tv' : 'movie', id);
      if (other != null) return _toDetail(id, other);
    }
    // 已知类型但那条路径不通时，仍再试另一条——豆瓣的类型标注本身就不可靠。
    final fallback = await _getDetail(path == 'movie' ? 'tv' : 'movie', id);
    if (fallback != null) return _toDetail(id, fallback);
    throw StateError('豆瓣详情取不到：$id');
  }

  Future<Map<String, Object?>?> _getDetail(String path, String id) async {
    final url = 'https://m.douban.com/rexxar/api/v2/$path/$id';
    try {
      final decoded = await http.getJson(url, headers: _detailHeaders);
      if (decoded is Map<String, Object?>) return decoded;
      if (decoded is Map) return decoded.cast<String, Object?>();
      return null;
    } on Object {
      return null;
    }
  }

  ScrapeDetail _toDetail(String id, Map<String, Object?> json) {
    final rating = json['rating'];
    double? score;
    int? count;
    if (rating is Map) {
      score = _double(rating['value']);
      count = _int(rating['count']);
    }
    final episodes = _int(json['episodes_count']);
    final declared = ScrapeKind.parse(_str(json['type']));
    // is_tv 是豆瓣自己给的布尔，比 type 字段可靠。
    final isTv = json['is_tv'] == true;
    final kind = isTv || (episodes != null && episodes > 1)
        ? ScrapeKind.tv
        : (declared == ScrapeKind.unknown && episodes == null
            ? ScrapeKind.unknown
            : declared);
    return ScrapeDetail(
      source: wireName,
      id: id,
      title: _str(json['title']) ?? '',
      originalTitle: _str(json['original_title']),
      year: _int(json['year']),
      kind: kind,
      poster: _posterOf(json),
      intro: _str(json['intro']),
      rating: score,
      ratingCount: count,
      genres: _strList(json['genres']),
      countries: _strList(json['countries']),
      durations: _strList(json['durations']),
      directors: _namesOf(json['directors']),
      actors: _namesOf(json['actors']),
      episodeCount: episodes,
      releaseDate: _str(json['pubdate']) ?? _str(json['release_date']),
    );
  }

  /// 取海报地址。
  ///
  /// `pic.normal` 是竖版海报（约 300 宽），`cover_url` 是横版剧照。片库是竖
  /// 排列表，用竖版更合适，所以优先 pic。
  static String? _posterOf(Map<String, Object?> json) {
    final pic = json['pic'];
    if (pic is Map) {
      final normal = _str(pic['normal']);
      if (normal != null) return normal;
      final large = _str(pic['large']);
      if (large != null) return large;
    }
    final cover = _str(json['cover_url']);
    if (cover != null) return cover;
    return _str(json['cover']);
  }

  static List<String> _namesOf(Object? raw) {
    if (raw is! List) return const [];
    final out = <String>[];
    for (final item in raw) {
      if (item is Map) {
        final name = _str(item['name']);
        if (name != null) out.add(name);
      } else if (item is String && item.isNotEmpty) {
        out.add(item);
      }
    }
    return out;
  }

  static String? _hintOf({int? year, String? originalTitle}) {
    final parts = <String>[];
    if (year != null) parts.add('$year');
    if (originalTitle != null && originalTitle.isNotEmpty) {
      parts.add(originalTitle);
    }
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
    if (raw is! List) return const [];
    final out = <String>[];
    for (final item in raw) {
      if (item is String && item.trim().isNotEmpty) out.add(item.trim());
    }
    return out;
  }
}
