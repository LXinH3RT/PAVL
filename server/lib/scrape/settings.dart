/// 刮削的配置项。
///
/// 单独放一个文件是为了打断循环依赖：`config.dart` 需要读写这几个字段，
/// 而刮削的存储又要用到 `config.dart` 里的数据目录。
library;

import 'models.dart';

/// 刮削的配置。
class ScrapeSettings {
  const ScrapeSettings({
    this.enabled = false,
    this.autoMatch = true,
    this.sources = defaultSources,
  });

  /// 默认启用的来源，按优先级排序。
  ///
  /// 豆瓣排第一：中文片名、简介、评分都最全，匹配质量明显好于另外两个。
  static const List<ScrapeSource> defaultSources = [
    ScrapeSource.douban,
    ScrapeSource.imdb,
    ScrapeSource.bilibili,
  ];

  /// 是否允许服务端联网刮削。
  ///
  /// 默认关：刮削要替用户去外部站点抓数据，不打招呼就发请求不合适，得由人
  /// 在设置里显式打开。关掉之后服务端不再发起任何外部请求，已经刮到的记录
  /// 仍然能读能显示。客户端那边还有一个「显示刮削信息」的显示开关，两个都
  /// 打开才会看到海报与评分。
  final bool enabled;

  /// 是否在刷新片库后自动匹配。
  ///
  /// 关掉之后只能手动挑候选，适合片库里混着大量不想刮的视频的情况——自动
  /// 匹配每部片都要搜一次，几十部就是一分钟往上。
  final bool autoMatch;

  /// 参与刮削的来源，按优先级排序。
  final List<ScrapeSource> sources;

  ScrapeSettings copyWith({
    bool? enabled,
    bool? autoMatch,
    List<ScrapeSource>? sources,
  }) =>
      ScrapeSettings(
        enabled: enabled ?? this.enabled,
        autoMatch: autoMatch ?? this.autoMatch,
        sources: sources ?? this.sources,
      );

  Map<String, Object?> toJson() => {
        'enabled': enabled,
        'autoMatch': autoMatch,
        'sources': sources.map((s) => s.wireName).toList(),
      };

  static ScrapeSettings fromJson(Object? raw) {
    if (raw is! Map) return const ScrapeSettings();
    final sources = <ScrapeSource>[];
    final rawSources = raw['sources'];
    if (rawSources is List) {
      for (final item in rawSources) {
        final source = ScrapeSource.parse(item is String ? item : null);
        if (source != null && !sources.contains(source)) sources.add(source);
      }
    }
    return ScrapeSettings(
      enabled: raw['enabled'] is bool ? raw['enabled']! as bool : false,
      autoMatch: raw['autoMatch'] is bool ? raw['autoMatch']! as bool : true,
      sources: sources.isEmpty ? defaultSources : sources,
    );
  }
}
