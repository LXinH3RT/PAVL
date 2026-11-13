/// 刮削的统一数据模型。
///
/// 三个来源（豆瓣、IMDb、B站）返回的结构差别很大，进到服务端之后一律先转成
/// 这里的形状：候选（搜索结果的每条）与详情（确定某一部之后的完整信息）。
/// 只有统一了形状，匹配打分与缓存才写得干净，客户端也不用按源分支渲染。
library;

/// 支持的影片信息来源。
///
/// [wireName] 是出现在配置文件与接口里的字面量，属于对外契约，不能随意改。
enum ScrapeSource {
  douban('douban', '豆瓣'),
  imdb('imdb', 'IMDb'),
  bilibili('bilibili', 'B站');

  const ScrapeSource(this.wireName, this.label);

  /// 配置与接口里的字面量。
  final String wireName;

  /// 界面上显示的名字。
  final String label;

  /// 是否认中文名。豆瓣与 B站 是中文源，IMDb 是英文源；匹配时中文源优先
  /// 用来匹配中文文件夹名，英文源用来兜底。
  bool get isChinese => this != ScrapeSource.imdb;

  static ScrapeSource? parse(String? raw) {
    if (raw == null) return null;
    for (final source in ScrapeSource.values) {
      if (source.wireName == raw) return source;
    }
    return null;
  }
}

/// 影片类型，用于匹配时区分电影与剧集。
enum ScrapeKind {
  movie,
  tv,
  unknown;

  static ScrapeKind parse(String? raw) {
    switch (raw) {
      case 'movie':
        return ScrapeKind.movie;
      case 'tv':
      case 'series':
        return ScrapeKind.tv;
      default:
        return ScrapeKind.unknown;
    }
  }
}

/// 搜索出来的一个候选。
class ScrapeCandidate {
  const ScrapeCandidate({
    required this.source,
    required this.id,
    required this.title,
    this.originalTitle,
    this.year,
    this.kind = ScrapeKind.unknown,
    this.poster,
    this.hint,
    this.rating,
    this.episodeCount,
  });

  /// 来源。
  final String source;

  /// 来源内部的 id：豆瓣是数字 id，IMDb 是 `tt` 开头的编号，B站是 `BV` 号。
  final String id;

  /// 显示标题。
  final String title;

  /// 原名（豆瓣的 `sub_title`、IMDb 的英文原名）。
  final String? originalTitle;

  /// 年份。
  final int? year;

  /// 电影还是剧集。
  final ScrapeKind kind;

  /// 海报地址。
  final String? poster;

  /// 副标题：演员、集数之类的补充，界面上灰字显示。
  final String? hint;

  /// 评分，各源口径不同，只用于展示。
  final double? rating;

  /// 集数（剧集才有）。
  final int? episodeCount;

  Map<String, Object?> toJson() => {
        'source': source,
        'id': id,
        'title': title,
        if (originalTitle != null && originalTitle!.isNotEmpty)
          'originalTitle': originalTitle,
        if (year != null) 'year': year,
        'kind': kind.name,
        if (poster != null && poster!.isNotEmpty) 'poster': poster,
        if (hint != null && hint!.isNotEmpty) 'hint': hint,
        if (rating != null) 'rating': rating,
        if (episodeCount != null) 'episodeCount': episodeCount,
      };

  /// 从客户端回传的候选还原。
  ///
  /// 手动匹配时客户端把搜到的候选原样送回服务端，这里只认必需的三个字段：
  /// 没有 source/id/title 的那不是候选。
  static ScrapeCandidate? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final source = raw['source'];
    final id = raw['id'];
    final title = raw['title'];
    if (source is! String || id is! String || title is! String) return null;
    if (source.isEmpty || id.isEmpty) return null;
    final year = raw['year'];
    final rating = raw['rating'];
    final episodeCount = raw['episodeCount'];
    return ScrapeCandidate(
      source: source,
      id: id,
      title: title,
      originalTitle: _str(raw['originalTitle']),
      year: year is int ? year : (year is String ? int.tryParse(year) : null),
      kind: ScrapeKind.parse(raw['kind'] is String ? raw['kind']! as String : null),
      poster: _str(raw['poster']),
      hint: _str(raw['hint']),
      rating: rating is num ? rating.toDouble() : null,
      episodeCount: episodeCount is int ? episodeCount : null,
    );
  }

  static String? _str(Object? value) =>
      value is String && value.trim().isNotEmpty ? value.trim() : null;
}

/// 某一部作品的完整信息。
///
/// 字段刻意少而稳：只留片库界面用得到的（标题、年份、海报、简介、评分、
/// 分类、演职员）。来源特有的字段不进模型，否则加一个源就得改一遍客户端。
class ScrapeDetail {
  const ScrapeDetail({
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
  });

  final String source;
  final String id;
  final String title;
  final String? originalTitle;
  final int? year;
  final ScrapeKind kind;
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

  /// 评分与人数拼成一句，界面上直接显示。
  ///
  /// 各源的人数字段含义不同（豆瓣是评价人数，IMDb 是评分人数），所以只做
  /// 「分数 + 人数」的粗展示，不参与排序。
  String? get ratingText {
    final score = rating;
    if (score == null) return null;
    final count = ratingCount;
    if (count == null || count <= 0) return score.toStringAsFixed(1);
    return '${score.toStringAsFixed(1)}（$count 人）';
  }

  Map<String, Object?> toJson() => {
        'source': source,
        'id': id,
        'title': title,
        if (originalTitle != null && originalTitle!.isNotEmpty)
          'originalTitle': originalTitle,
        if (year != null) 'year': year,
        'kind': kind.name,
        if (poster != null && poster!.isNotEmpty) 'poster': poster,
        if (intro != null && intro!.isNotEmpty) 'intro': intro,
        if (rating != null) 'rating': rating,
        if (ratingCount != null) 'ratingCount': ratingCount,
        if (ratingText != null) 'ratingText': ratingText,
        if (genres.isNotEmpty) 'genres': genres,
        if (countries.isNotEmpty) 'countries': countries,
        if (durations.isNotEmpty) 'durations': durations,
        if (directors.isNotEmpty) 'directors': directors,
        if (actors.isNotEmpty) 'actors': actors,
        if (episodeCount != null) 'episodeCount': episodeCount,
        if (releaseDate != null && releaseDate!.isNotEmpty)
          'releaseDate': releaseDate,
      };
}
