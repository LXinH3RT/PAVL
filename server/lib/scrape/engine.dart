/// 刮削引擎：把「来源、匹配、缓存、海报」拼成对外的动作。
///
/// 对外只有四件事：
///   - [search]：给关键词，返回各来源的候选（手动匹配界面用）；
///   - [scrapeOne]：给一组视频（通常是一个文件夹里的整部剧）与一个候选，
///     抓详情、下海报、落盘；
///   - [autoScrape]：给片库里的文件夹批量自动匹配，只在分数够高时才采纳；
///   - [clear]：清空全部刮削结果。
///
/// 全部动作都带并发上限与请求间隔，因为这几个来源对连续请求都不客气——豆瓣
/// 尤其明显，快一点就直接给验证页。
library;

import 'dart:async';

import '../media.dart';
import 'bilibili.dart';
import 'douban.dart';
import 'http.dart';
import 'imdb.dart';
import 'match.dart';
import 'models.dart';
import 'provider.dart';
import 'settings.dart';
import 'store.dart';

/// 一次刮削动作的结果。
class ScrapeOutcome {
  const ScrapeOutcome({
    required this.paths,
    this.record,
    this.error,
  });

  /// 本次写入的路径。
  final List<String> paths;

  /// 写入的记录，失败时为 null。
  final ScrapeRecord? record;

  /// 失败原因。
  final String? error;

  bool get ok => record != null;
}

/// 批量自动匹配的汇总。
class AutoScrapeReport {
  AutoScrapeReport({
    this.scanned = 0,
    this.matched = 0,
    this.skipped = 0,
    this.failed = 0,
    this.errors = const [],
    this.startedAt = 0,
    this.finishedAt = 0,
  });

  /// 扫过的文件夹行数。
  int scanned;

  /// 采纳的数量。
  int matched;

  /// 已有记录或分数不够而跳过的数量。
  int skipped;

  /// 抓取失败的数量。
  int failed;

  /// 失败摘要，最多留十几条。
  List<String> errors;

  int startedAt;
  int finishedAt;

  Map<String, Object?> toJson() => {
        'scanned': scanned,
        'matched': matched,
        'skipped': skipped,
        'failed': failed,
        'errors': errors,
        'startedAt': startedAt,
        'finishedAt': finishedAt,
      };
}

/// 刮削引擎。
class ScrapeEngine {
  ScrapeEngine({
    required this.store,
    ScrapeHttp? http,
    this.settings = const ScrapeSettings(),
  }) : _http = http ?? ScrapeHttp() {
    _providers = _buildProviders(_http);
  }

  /// 结果存储。
  final ScrapeStore store;

  /// 抓取器。
  final ScrapeHttp _http;

  /// 配置。
  ScrapeSettings settings;

  late final Map<ScrapeSource, ScrapeProvider> _providers;

  /// 正在跑的批量任务；同一时间只允许一个。
  bool _autoRunning = false;

  /// 上一次批量任务的结果。
  AutoScrapeReport? lastReport;

  /// 是否正在自动刮削。
  bool get running => _autoRunning;

  /// 已落盘的记录条数。
  Future<int> get recordCount => store.count();

  /// 取一批路径的刮削记录，供片库列表挂显示用。
  ///
  /// 直接透给存储层：列表接口一次要拿几百条，多包一层没有意义。
  Future<Map<String, ScrapeRecord>> recordsFor(Iterable<String> paths) =>
      store.getMany(paths);

  static Map<ScrapeSource, ScrapeProvider> _buildProviders(ScrapeHttp http) => {
        ScrapeSource.douban: DoubanProvider(http),
        ScrapeSource.imdb: ImdbProvider(http),
        ScrapeSource.bilibili: BilibiliProvider(http),
      };

  /// 按关键词在所有启用的来源里找候选。
  ///
  /// 单个来源失败不影响其他来源：结果里 [ScrapeSearchResult.failures] 会列出
  /// 哪个源失败、为什么。这样豆瓣抽风的时候，IMDb 的结果照样能出来。
  Future<ScrapeSearchResult> search(
    String keyword, {
    ScrapeKind? kind,
    int? year,
    List<ScrapeSource>? sources,
  }) async {
    final query = keyword.trim();
    if (query.isEmpty) {
      return const ScrapeSearchResult(matches: [], failures: {});
    }
    if (!settings.enabled) {
      return const ScrapeSearchResult(
        matches: [],
        failures: {},
        disabled: true,
      );
    }
    final use = sources ?? settings.sources;
    final matches = <ScrapeMatch>[];
    final failures = <String, String>{};

    // 串行发请求而不是并发：这几个源对突发请求都敏感，串行还能让缓存更容易
    // 命中。搜索界面等一下是可以接受的。
    for (final source in use) {
      final provider = _providers[source];
      if (provider == null) continue;
      try {
        await _respectInterval(source);
        final candidates = await provider.search(query);
        matches.addAll(rankCandidates(
          query: query,
          candidates: candidates,
          expectedYear: year,
          expectedKind: kind,
        ));
      } on Object catch (error) {
        failures[source.wireName] = _briefError(error);
      }
    }
    return ScrapeSearchResult(matches: matches, failures: failures);
  }

  /// 把一个候选套用到一组路径（同一个文件夹里的所有集）。
  ///
  /// 剧集的信息是「整部剧」的，所以同一个文件夹里的每一集都写同一条记录；
  /// 集数由文件夹里的视频数决定，不采用来源给的集数——来源可能是按季列的，
  /// 与本地文件对不上。
  Future<ScrapeOutcome> scrapeOne({
    required List<String> paths,
    required ScrapeCandidate candidate,
    String query = '',
    int score = 0,
    bool auto = false,
  }) async {
    if (paths.isEmpty) {
      return const ScrapeOutcome(paths: [], error: '没有要写入的路径');
    }
    if (!settings.enabled) {
      return const ScrapeOutcome(paths: [], error: '刮削已在服务端关闭');
    }
    final source = ScrapeSource.parse(candidate.source);
    final provider = source == null ? null : _providers[source];
    if (source == null || provider == null) {
      return ScrapeOutcome(paths: paths, error: '不认识的来源：${candidate.source}');
    }
    try {
      await _respectInterval(source);
      final detail = await provider.detail(candidate.id, kind: candidate.kind);
      // 海报单独下：下载失败不该让整条记录作废，没有海报的刮削结果仍然有
      // 标题、简介与评分，界面降级成纯文字即可。
      String? posterName;
      final posterUrl = detail.poster ?? candidate.poster;
      if (posterUrl != null && posterUrl.isNotEmpty) {
        posterName = await _downloadPoster(posterUrl, source, detail.id);
      }
      final record = ScrapeRecord(
        source: source.wireName,
        id: detail.id,
        title: detail.title.isEmpty ? candidate.title : detail.title,
        originalTitle: detail.originalTitle ?? candidate.originalTitle,
        year: detail.year ?? candidate.year,
        kind: detail.kind == ScrapeKind.unknown ? candidate.kind : detail.kind,
        poster: posterName,
        intro: detail.intro,
        rating: detail.rating,
        ratingCount: detail.ratingCount,
        genres: detail.genres,
        countries: detail.countries,
        durations: detail.durations,
        directors: detail.directors,
        actors: detail.actors,
        episodeCount: paths.length > 1 ? paths.length : detail.episodeCount,
        releaseDate: detail.releaseDate,
        query: query,
        score: score,
        auto: auto,
        matchedAt: DateTime.now().millisecondsSinceEpoch,
      );
      await store.putAll({for (final path in paths) path: record});
      return ScrapeOutcome(paths: paths, record: record);
    } on Object catch (error) {
      return ScrapeOutcome(paths: paths, error: _briefError(error));
    }
  }

  /// 批量自动匹配。
  ///
  /// [groups] 是片库的文件夹行：每行给一个文件夹名与它下面的所有视频路径。
  /// 已经有手动记录（`auto == false`）的跳过，不动用户的决定。
  ///
  /// [onProgress] 每处理完一行回调一次，供日志与界面进度用。
  Future<AutoScrapeReport> autoScrape(
    List<ScrapeFolder> groups, {
    void Function(int done, int total)? onProgress,
    bool Function()? cancelled,
  }) async {
    if (_autoRunning) {
      return lastReport ?? AutoScrapeReport();
    }
    final report = AutoScrapeReport(
      startedAt: DateTime.now().millisecondsSinceEpoch,
    );
    lastReport = report;
    if (!settings.enabled) {
      report.finishedAt = report.startedAt;
      return report;
    }

    _autoRunning = true;
    try {
      final existing = await store.getMany(groups.expand((g) => g.paths));
      var done = 0;
      for (final group in groups) {
        if (cancelled?.call() ?? false) break;
        done++;
        report.scanned++;
        onProgress?.call(done, groups.length);
        final already = group.paths
            .map((path) => existing[path])
            .whereType<ScrapeRecord>()
            .toList();
        // 已有记录就不重复刮：手动指定的记录永不覆盖，自动刮到的也不再动。
        if (already.isNotEmpty) {
          report.skipped++;
          continue;
        }
        final query = group.query;
        if (query.isEmpty) {
          report.skipped++;
          continue;
        }
        try {
          final found = await search(query, kind: group.kind, year: group.year);
          final best = found.matches.isEmpty ? null : found.matches.first;
          if (best == null || !best.strong) {
            report.skipped++;
            continue;
          }
          final outcome = await scrapeOne(
            paths: group.paths,
            candidate: best.candidate,
            query: query,
            score: best.score,
            auto: true,
          );
          if (outcome.ok) {
            report.matched++;
          } else {
            report.failed++;
            report.errors = _appendError(report.errors, outcome.error);
          }
        } on Object catch (error) {
          report.failed++;
          report.errors = _appendError(report.errors, _briefError(error));
        }
      }
    } finally {
      _autoRunning = false;
      report.finishedAt = DateTime.now().millisecondsSinceEpoch;
    }
    return report;
  }

  /// 清空全部刮削结果。
  Future<void> clear() async {
    await store.clear();
    _http.clearCache();
  }

  /// 取海报文件的绝对路径。
  Future<String?> posterPath(String name) => store.posterPath(name);

  /// 释放网络资源。
  void close() => _http.close();

  Future<String?> _downloadPoster(
      String url, ScrapeSource source, String detailId) async {
    try {
      final bytes = await _http.getBytes(url, headers: _posterHeaders(source));
      if (bytes.length < 512) return null;
      return await store.savePoster(bytes, sourceId: detailId);
    } on Object {
      // 海报失败不致命，降级成无图。
      return null;
    }
  }

  /// 各来源图床要求的请求头。
  ///
  /// 豆瓣与 B站 都校验 Referer，少了回 403；IMDb 的图床（metahub / m.media-amazon）
  /// 不校验，带不带都行。
  static Map<String, String> _posterHeaders(ScrapeSource source) {
    switch (source) {
      case ScrapeSource.douban:
        return const {'Referer': 'https://movie.douban.com/'};
      case ScrapeSource.bilibili:
        return const {'Referer': 'https://www.bilibili.com/'};
      case ScrapeSource.imdb:
        return const {};
    }
  }

  /// 同一个来源的两次请求之间至少隔这么久。
  ///
  /// 豆瓣最敏感：实测 0.3 秒间隔就会被拦，这里保守取 1.2 秒。IMDb 与 B站 的
  /// 接口是 CDN 上的静态 JSON，快一点没关系。
  static Duration _intervalOf(ScrapeSource source) {
    switch (source) {
      case ScrapeSource.douban:
        return const Duration(milliseconds: 1200);
      case ScrapeSource.bilibili:
        return const Duration(milliseconds: 400);
      case ScrapeSource.imdb:
        return const Duration(milliseconds: 250);
    }
  }

  final Map<ScrapeSource, DateTime> _lastRequestAt = {};

  Future<void> _respectInterval(ScrapeSource source) async {
    final last = _lastRequestAt[source];
    final interval = _intervalOf(source);
    if (last != null) {
      final elapsed = DateTime.now().difference(last);
      if (elapsed < interval) {
        await Future<void>.delayed(interval - elapsed);
      }
    }
    _lastRequestAt[source] = DateTime.now();
  }

  static List<String> _appendError(List<String> current, String? error) {
    if (error == null || error.isEmpty) return current;
    if (current.length >= 10) return current;
    return [...current, error];
  }

  static String _briefError(Object error) {
    final text = error.toString();
    return text.length > 160 ? '${text.substring(0, 160)}…' : text;
  }
}

/// 关键词搜索结果。
class ScrapeSearchResult {
  const ScrapeSearchResult({
    required this.matches,
    required this.failures,
    this.disabled = false,
  });

  /// 按分数排好的候选。
  final List<ScrapeMatch> matches;

  /// 哪个源失败了、为什么。
  final Map<String, String> failures;

  /// 是否因为服务端关闭了刮削而没查。
  final bool disabled;

  Map<String, Object?> toJson() => {
        'disabled': disabled,
        'failures': failures,
        'items': matches
            .map((m) => {
                  ...m.candidate.toJson(),
                  'score': m.score,
                  'strong': m.strong,
                  'query': m.query,
                })
            .toList(),
      };
}

/// 批量刮削的输入：一个文件夹行。
class ScrapeFolder {
  const ScrapeFolder({
    required this.name,
    required this.paths,
    this.query = '',
    this.kind,
    this.year,
  });

  /// 显示名，用于日志。
  final String name;

  /// 这一行包含的视频路径。
  final List<String> paths;

  /// 用于搜索的关键词。
  final String query;

  final ScrapeKind? kind;
  final int? year;

  /// 从一个文件夹或文件名构造。
  static ScrapeFolder of({
    required String name,
    required List<String> paths,
    bool isFolder = true,
  }) {
    final query =
        isFolder ? scrapeQueryOfFolder(name) : scrapeQueryOfFile(name);
    // 剧集在文件名里能看出季集，文件夹名看不出，所以类型只能从文件名推。
    ScrapeKind? kind;
    int? year;
    if (paths.isNotEmpty) {
      final parsed = parseFileName(_baseNameOf(paths.first));
      if (parsed.isEpisode) kind = ScrapeKind.tv;
      year = parsed.year;
    }
    return ScrapeFolder(
      name: name,
      paths: paths,
      query: query,
      kind: kind,
      year: year,
    );
  }

  static String _baseNameOf(String path) {
    final normalized = path.replaceAll('\\', '/');
    final name = normalized.substring(normalized.lastIndexOf('/') + 1);
    final dot = name.lastIndexOf('.');
    return dot <= 0 ? name : name.substring(0, dot);
  }
}
