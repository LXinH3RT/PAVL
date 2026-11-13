/// B站刮削。
///
/// B站 在这个项目里的定位与豆瓣、IMDb 都不同：它没有「作品」概念，只有一个个
/// 用户投稿的视频。把一部影片对应到 B站 的一条投稿，本质上不可靠（同一条片
/// 可能被切成几十段，也可能根本没人上传），所以 B站 只作为「补充来源」：
/// 能查到就给出封面与简介，查不到不影响刮削结果。
///
/// 接口方面，`api.bilibili.com/x/web-interface/search/type` 对非浏览器请求
/// 一律回 412（风控），带 cookie 也未必通；可用的是 `search/all/v2`，它只要
/// 求一个 `Referer`，搜索结果里已经带了标题、封面、简介、时长与 UP 主，足够
/// 拼出一个候选。
library;

import 'models.dart';
import 'provider.dart';

/// B站 的数据来源。
class BilibiliProvider extends ScrapeProvider {
  BilibiliProvider(super.http);

  @override
  ScrapeSource get source => ScrapeSource.bilibili;

  /// B站 的接口要求 Referer 是自家站点，否则直接 412。
  static const Map<String, String> _headers = {
    'Referer': 'https://www.bilibili.com/',
    'Origin': 'https://www.bilibili.com',
  };

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
    final decoded = await http.getJson(url, headers: _headers);
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
    // 详情接口 `x/web-interface/view` 对非浏览器请求回 412，实测拿不到，所以
    // 这里改用 search 回查：用 BV 号当关键词能命中那一条，字段也够用。
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

  /// B站 的封面地址以 `//` 开头，补上 https。
  static String? _posterOf(String? raw) {
    if (raw == null) return null;
    if (raw.startsWith('//')) return 'https:$raw';
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
