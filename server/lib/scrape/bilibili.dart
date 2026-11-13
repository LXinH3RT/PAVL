/// B站刮削。
///
/// B站 在这个项目里的定位与豆瓣、IMDb 都不同：它没有「作品」概念，只有一个个
/// 用户投稿的视频。把一部影片对应到 B站 的一条投稿，本质上不可靠（同一条片
/// 可能被切成几十段，也可能根本没人上传），所以 B站 只作为「补充来源」：
/// 能查到就给出封面与简介，查不到不影响刮削结果。
///
/// 接口方面有两个反直觉的地方，都是实测出来的：
///
///   1. `search/type` 对非浏览器请求会随机 412（风控），但 `search/all/v2`
///      不需要任何请求头就能用，反过来带 `Referer` 也不影响它；
///   2. `view`（详情）**不能带 `Referer`**——带上稳定 412，去掉反而 200。
///
/// 所以搜索与详情用两套请求头：搜索什么都不带，详情只带 UA（由 HTTP 层统一
/// 加）。详情能拿到简介、封面、时长、发布日期与 UP 主，比回查搜索可靠得多。
library;

import 'models.dart';
import 'provider.dart';

/// B站 的数据来源。
class BilibiliProvider extends ScrapeProvider {
  BilibiliProvider(super.http);

  @override
  ScrapeSource get source => ScrapeSource.bilibili;

  /// 详情接口：**不要**带 `Referer`。
  ///
  /// 带上 `Referer: https://www.bilibili.com/` 时 `view` 稳定回 412，去掉就
  /// 200，这是实测三次都一致的行为，不是偶发风控。
  static const Map<String, String> _detailHeaders = {};

  /// 返回结果里最多取几条。
  ///
  /// B站 的搜索是全网视频，关键词一宽就几百条，全都灌进候选列表只会淹掉真正
  /// 想找的条目。
  static const int _maxCandidates = 12;

  @override
  Future<List<ScrapeCandidate>> search(String keyword) async {
    final query = keyword.trim();
    if (query.isEmpty) return const [];
    final url = 'https://api.bilibili.com/x/web-interface/search/all/v2'
        '?keyword=${Uri.encodeQueryComponent(query)}';
    final decoded = await http.getJson(url);
    if (decoded is! Map) return const [];
    // code 不是 0 说明被风控或参数不对，这时按「没有结果」处理，别抛异常：
    // B站 只是补充源，失败不该让整次刮削失败。
    if (decoded['code'] != 0) return const [];
    final data = decoded['data'];
    if (data is! Map) return const [];
    final groups = data['result'];
    if (groups is! List) return const [];

    final out = <ScrapeCandidate>[];
    for (final group in groups) {
      if (group is! Map) continue;
      if (group['result_type'] != 'video') continue;
      final items = group['data'];
      if (items is! List) continue;
      for (final item in items) {
        if (item is! Map) continue;
        final bvid = _str(item['bvid']);
        final title = _cleanHighlight(_str(item['title']));
        if (bvid == null || title == null) continue;
        out.add(ScrapeCandidate(
          source: wireName,
          id: bvid,
          title: title,
          poster: _posterOf(_str(item['pic'])),
          hint: _hintOf(
            author: _str(item['author']),
            duration: _str(item['duration']),
          ),
          kind: ScrapeKind.unknown,
        ));
        if (out.length >= _maxCandidates) return out;
      }
    }
    return out;
  }

  @override
  Future<ScrapeDetail> detail(String id,
      {ScrapeKind kind = ScrapeKind.unknown}) async {
    final url = 'https://api.bilibili.com/x/web-interface/view'
        '?bvid=${Uri.encodeQueryComponent(id)}';
    final decoded = await http.getJson(url, headers: _detailHeaders);
    if (decoded is Map && decoded['code'] == 0 && decoded['data'] is Map) {
      final data = (decoded['data'] as Map).cast<String, Object?>();
      final title = _str(data['title']);
      if (title != null) {
        final owner = data['owner'];
        final author = owner is Map ? _str(owner['name']) : null;
        final seconds = _int(data['duration']);
        return ScrapeDetail(
          source: wireName,
          id: id,
          title: title,
          poster: _posterOf(_str(data['pic'])),
          // `desc` 全是短横线的占位时当成没有。
          intro: _introOf(_str(data['desc'])),
          genres: [_str(data['tname_v2']), _str(data['tname'])]
              .whereType<String>()
              .where((t) => t.isNotEmpty)
              .toList(),
          durations: seconds == null || seconds <= 0
              ? const []
              : ['${(seconds / 60).ceil()} 分钟'],
          directors: author == null ? const [] : [author],
          releaseDate: _dateOf(_int(data['pubdate'])),
          kind: ScrapeKind.unknown,
        );
      }
    }
    // 详情拿不到时退回 search 回查：用 BV 号当关键词能命中那一条，至少还有
    // 封面与标题，比整条失败强。
    final candidates = await search(id);
    for (final candidate in candidates) {
      if (candidate.id != id) continue;
      return ScrapeDetail(
        source: wireName,
        id: candidate.id,
        title: candidate.title,
        poster: candidate.poster,
        intro: candidate.hint,
        kind: ScrapeKind.unknown,
      );
    }
    throw StateError('B站详情取不到：$id');
  }

  /// `desc` 只有一串短横线或者「-」时视为没有简介。
  static String? _introOf(String? desc) {
    if (desc == null) return null;
    final stripped = desc.replaceAll(RegExp(r'[-—\s]'), '');
    return stripped.isEmpty ? null : desc;
  }

  /// 秒级时间戳转 `yyyy-MM-dd`。
  static String? _dateOf(int? seconds) {
    if (seconds == null || seconds <= 0) return null;
    final date = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '${date.year}-$month-$day';
  }

  static int? _int(Object? value) {
    if (value is int) return value;
    if (value is double) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  /// B站 的封面地址有 `//` 与 `http://` 两种写法，统一升到 https。
  ///
  /// 搜索接口回 `//i0.hdslb.com/...`，详情接口回 `http://i0.hdslb.com/...`，
  /// 两者都能下，但明文地址在部分平台会被拦，这里一并改写成 https。
  static String? _posterOf(String? raw) {
    if (raw == null) return null;
    if (raw.startsWith('//')) return 'https:$raw';
    if (raw.startsWith('http://')) return 'https://${raw.substring(7)}';
    return raw;
  }

  /// 搜索结果里的标题带 `<em class="keyword">…</em>` 高亮标签，去掉标签只留
  /// 文字，顺便把 HTML 实体还原。
  static String? _cleanHighlight(String? raw) {
    if (raw == null) return null;
    var text = raw.replaceAll(RegExp(r'<[^>]*>'), '');
    text = text
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'");
    final trimmed = text.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static String? _hintOf({String? author, String? duration}) {
    final parts = <String>[];
    if (author != null && author.isNotEmpty) parts.add('UP：$author');
    if (duration != null && duration.isNotEmpty) parts.add(duration);
    return parts.isEmpty ? null : parts.join(' · ');
  }

  static String? _str(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
