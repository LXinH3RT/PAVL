/// 刮削来源的公共接口。
///
/// 每个来源各写一个实现，对外只暴露两个动作：按关键词找候选、按 id 取详情。
/// 匹配打分、缓存、落地全部在上层做，来源这边只负责「把对方的数据翻译成
/// [ScrapeCandidate] 与 [ScrapeDetail]」。
library;

import 'models.dart';

/// [ScrapeProvider] 需要的抓取能力。
///
/// 单独抽出来是为了让来源实现不直接依赖 `dart:io`：测试里塞个假的就能跑，
/// 不必真的联网。
abstract class ScrapeHttpLike {
  /// 取 JSON。[headers] 为空表示不加额外请求头。
  Future<Object?> getJson(String url, {Map<String, String>? headers});

  /// 取文本。
  Future<String> getText(String url, {Map<String, String>? headers, String? accept});
}

/// 一个影片信息来源。
abstract class ScrapeProvider {
  ScrapeProvider(this.http);

  /// 抓取器，带缓存与超时。
  final ScrapeHttpLike http;

  /// 这个实现对应哪个来源。
  ScrapeSource get source;

  /// 配置与接口里用的字面量。
  String get wireName => source.wireName;

  /// 按关键词找候选，按相关度从高到低返回。
  ///
  /// 抓取失败时抛异常，上层决定跳过还是重试。
  Future<List<ScrapeCandidate>> search(String keyword);

  /// 按 id 取详情。
  ///
  /// [kind] 是搜索阶段已知的类型，有些来源要据此换接口路径；未知时实现自己
  /// 想办法（通常是跟随重定向或挨个试）。
  Future<ScrapeDetail> detail(String id, {ScrapeKind kind = ScrapeKind.unknown});
}
