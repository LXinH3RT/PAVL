/// 把文件夹名或文件名对上一个来源条目。
///
/// 这是刮削里最容易出错的一环，也是最不值得「聪明」的一环：片名与文件名的
/// 差距太大（`The.Glory.S01E15.1080p.WEB-DL.x264` 对 `黑暗荣耀`），任何基于
/// 字符串的猜测都会有一批必然猜错。所以这里的策略是：
///
///   1. 先做规范化，把年份、季集、压制标记、括号全部剥掉；
///   2. 用规范化后的标题去查，让来源自己排序；
///   3. 只做保守的打分——标题完全一致或互相包含才算强命中，其余都算弱；
///   4. 分数不够就返回 null，交给用户手选，而不是硬配一个错的。
///
/// 宁可让用户多点一次，也不要让片库显示成另一部片的海报。
library;

import '../media.dart';
import 'models.dart';

/// 一次匹配的结果。
class ScrapeMatch {
  const ScrapeMatch({
    required this.candidate,
    required this.score,
    required this.query,
    this.strong = false,
  });

  /// 选中的候选。
  final ScrapeCandidate candidate;

  /// 分数，越高越可信。
  final int score;

  /// 实际拿去查询的关键词，界面上要显示「按 xxx 找到的」。
  final String query;

  /// 是否算强命中。
  ///
  /// 只有强命中才会被自动采纳；弱命中要在界面上让用户确认。
  final bool strong;
}

/// 从文件名里抽出用于搜索的关键词。
///
/// 走的是服务端已有的 [parseFileName]，它已经把年份、`SxxExx`、`第 N 集`、
/// 方括号分组与压制标记都剥掉了。剧集文件只留标题——集号不参与搜索，因为
/// 来源条目是「整部剧」而不是单集。
String scrapeQueryOfFile(String fileName) {
  final base = _baseName(fileName);
  final parsed = parseFileName(base);
  var title = parsed.title;
  // 文件名里如果只剩一堆数字，说明原名本来就没意义（`01.mkv`），这时退回用
  // 上一级目录名，那个通常是剧名。
  if (title.isEmpty || RegExp(r'^[\d\s\-_]+$').hasMatch(title)) {
    return '';
  }
  return _normalize(title);
}

/// 从文件夹名里抽出用于搜索的关键词。
///
/// 文件夹名比文件名干净，通常直接就是片名，但仍有 `[压制组]`、`1080p` 之类
/// 的噪声，一样过一遍规范化。
String scrapeQueryOfFolder(String folderName) {
  return _normalize(folderName);
}

/// 把候选按「跟关键词的接近程度」排序并按需截断。
///
/// [query] 是规范化之前的原始关键词，用来在标题里找子串；[normalizedQuery]
/// 是规范化之后的形式，用来做全等比较。
List<ScrapeMatch> rankCandidates({
  required String query,
  required List<ScrapeCandidate> candidates,
  int? expectedYear,
  ScrapeKind? expectedKind,
  int limit = 8,
}) {
  final normalizedQuery = _normalize(query);
  if (normalizedQuery.isEmpty) return const [];
  final matches = <ScrapeMatch>[];
  for (final candidate in candidates) {
    final score = _scoreOf(
      normalizedQuery: normalizedQuery,
      candidate: candidate,
      expectedYear: expectedYear,
      expectedKind: expectedKind,
    );
    if (score <= 0) continue;
    matches.add(ScrapeMatch(
      candidate: candidate,
      score: score,
      query: query,
      strong: score >= _strongThreshold,
    ));
  }
  // 同分时先比季号：同一个分数的多半是同一部剧的几季（豆瓣每一季都是独立
  // 条目），拿第一季当代表，海报与简介才是整部剧的印象而不是最终季。
  matches.sort((a, b) {
    final byScore = b.score.compareTo(a.score);
    if (byScore != 0) return byScore;
    final aSeason = _seasonOf(a.candidate);
    final bSeason = _seasonOf(b.candidate);
    if (aSeason != bSeason) {
      if (aSeason == null) return 1;
      if (bSeason == null) return -1;
      return aSeason.compareTo(bSeason);
    }
    final aPoster = a.candidate.poster != null ? 1 : 0;
    final bPoster = b.candidate.poster != null ? 1 : 0;
    if (aPoster != bPoster) return bPoster - aPoster;
    final aYear = a.candidate.year != null ? 1 : 0;
    final bYear = b.candidate.year != null ? 1 : 0;
    return bYear - aYear;
  });
  final limited = _demoteAmbiguous(matches.take(limit).toList());
  return limited;
}

/// 把「同题不同版」的强命中降成弱命中。
///
/// 文件名里常没有年份，`东方快车谋杀案` 能同时匹配到 1974 与 2017 两版，
/// 分数一模一样。这种时候自动采纳必然有一半概率配错，与其赌一把，不如让用户
/// 在候选里点一下——界面上两版的年份、海报都摆在那里，一眼就能选对。
///
/// 同一部剧的不同季不算歧义：上面已经按季号排过序，取第一季是合理的默认。
List<ScrapeMatch> _demoteAmbiguous(List<ScrapeMatch> matches) {
  if (matches.length < 2) return matches;
  final top = matches.first.score;
  if (matches[1].score != top) return matches;
  final firstSeason = _seasonOf(matches.first.candidate);
  final secondSeason = _seasonOf(matches[1].candidate);
  if (firstSeason != null && secondSeason != null) return matches;

  final years = <int>{};
  for (final match in matches) {
    if (match.score != top) break;
    final year = match.candidate.year;
    if (year != null) years.add(year);
  }
  if (years.length < 2) return matches;
  return [
    for (final match in matches)
      if (match.score == top && match.strong)
        ScrapeMatch(
          candidate: match.candidate,
          score: match.score,
          query: match.query,
          strong: false,
        )
      else
        match,
  ];
}

/// 候选标题里的季号，解析不出就是 null。
int? _seasonOf(ScrapeCandidate candidate) {
  final season = parseFileName(candidate.title).season;
  return (season != null && season > 0) ? season : null;
}

/// 自动采纳的分数线。
///
/// 定得偏高是有意的：自动采纳错了，用户看到的是另一部片的简介与海报，比
/// 「什么都没刮到」更让人困惑。
const int _strongThreshold = 100;

int _scoreOf({
  required String normalizedQuery,
  required ScrapeCandidate candidate,
  int? expectedYear,
  ScrapeKind? expectedKind,
}) {
  final titles = <String>[
    _normalize(candidate.title),
    if (candidate.originalTitle != null) _normalize(candidate.originalTitle!),
  ].where((t) => t.isNotEmpty).toList();
  if (titles.isEmpty) return 0;

  var best = 0;
  for (final title in titles) {
    final score = _titleScore(normalizedQuery, title);
    if (score > best) best = score;
  }
  if (best == 0) return 0;

  // 年份差得远就明显降权：同名翻拍作品靠年份区分，`东方快车谋杀案` 有 1974 与
  // 2017 两版，配错了整部片的演职员就全错。
  final year = candidate.year;
  if (expectedYear != null && year != null) {
    final diff = (expectedYear - year).abs();
    if (diff == 0) {
      best += 30;
    } else if (diff <= 1) {
      best += 10;
    } else if (diff <= 3) {
      best -= 15;
    } else {
      best -= 45;
    }
  } else if (year != null) {
    // 查询里没年份时，有年份的候选稍微加分：它至少是个结构完整的条目。
    best += 5;
  }

  // 类型对上了加分。剧集与电影的界面差异很大，配错类型会让「集数」显示成
  // 一个莫名其妙的数字。
  if (expectedKind != null && candidate.kind != ScrapeKind.unknown) {
    if (expectedKind == candidate.kind) {
      best += 15;
    } else {
      best -= 10;
    }
  }
  return best;
}

/// 两个标题之间的基础分。
int _titleScore(String query, String title) {
  if (query == title) return 100;
  // 互相包含：`名侦探柯南` 对 `名侦探柯南：万圣节的新娘`。包含关系越是「一头
  // 一尾」越可信，所以按比例给分，避免 `柯南` 命中一堆剧场版后随便挑一个。
  if (title.startsWith(query) || query.startsWith(title)) {
    final ratio = (query.length < title.length ? query.length : title.length) /
        (query.length > title.length ? query.length : title.length);
    if (ratio >= 0.85) return 88;
    if (ratio >= 0.6) return 70;
    if (ratio >= 0.4) return 55;
    return 40;
  }
  if (title.contains(query) || query.contains(title)) {
    final ratio = (query.length < title.length ? query.length : title.length) /
        (query.length > title.length ? query.length : title.length);
    if (ratio >= 0.7) return 62;
    if (ratio >= 0.5) return 50;
    return 35;
  }
  // 去掉标点与空格后再比一次：`Spider-Man` 与 `Spider Man`。
  final looseQuery = query.replaceAll(RegExp(r'[\s\-:：·,，.。!！?？]'), '');
  final looseTitle = title.replaceAll(RegExp(r'[\s\-:：·,，.。!！?？]'), '');
  if (looseQuery.isEmpty || looseTitle.isEmpty) return 0;
  if (looseQuery == looseTitle) return 95;
  if (looseTitle.contains(looseQuery) || looseQuery.contains(looseTitle)) {
    return 45;
  }
  return 0;
}

/// 标题规范化：小写、去年份、去季集、去压制标记、去标点。
///
/// 结果用于比较，不是给人看的，所以可以把标点全删掉。
String _normalize(String raw) {
  var text = raw.trim();
  if (text.isEmpty) return '';
  // 扩展名如果有就摘掉（传进来的可能是完整文件名）。
  final dot = text.lastIndexOf('.');
  if (dot > 0 && text.length - dot <= 5) {
    text = text.substring(0, dot);
  }
  // 复用文件名解析，年份与季集就是它剥的。
  final parsed = parseFileName(text);
  text = parsed.title;
  // 中文片名里的书名号、间隔号对比较无意义。
  text = text.replaceAll(RegExp(r'[《》【】\[\]（）(){}]'), ' ');
  // 标点与常见分隔符统一成空格。连字符放在字符集最后，避免被当成范围。
  text = text.replaceAll(RegExp('[._:：·,，、!！?？"“”\'’/\\\\|+&-]'), ' ');
  text = text.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();
  return text;
}

String _baseName(String path) {
  final normalized = path.replaceAll('\\', '/');
  final name = normalized.substring(normalized.lastIndexOf('/') + 1);
  final dot = name.lastIndexOf('.');
  return dot <= 0 ? name : name.substring(0, dot);
}
