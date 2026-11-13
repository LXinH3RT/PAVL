/// 片库里的一行。
///
/// 与浏览页的 [EntryTile] 分开：那边每行是一个文件系统条目，要显示「几项」、
/// 文件夹图标、外挂字幕提示；这边每行是一部片或一个收拢后的文件夹，要显示
/// 解析出来的标题、季集编号和文件大小。硬塞进同一个组件会让两边都长出一堆
/// 「当前是不是目录」的分支。
///
/// 刮削到信息之后，行首的图标换成海报，标题换成刮到的片名，副行补上年份与
/// 评分；没刮到就保持原样，两种状态的行高一致，列表不会跳。
library;

import 'package:flutter/material.dart';

import '../../api/pavl_client.dart';
import '../../app.dart';

/// 片库里的一个文件夹：一行写文件夹名与集数，点开才是里面的各集。
class LibraryGroupTile extends StatelessWidget {
  const LibraryGroupTile({
    super.key,
    required this.group,
    required this.expanded,
    required this.onTap,
    this.posterUrl,
  });

  final LibraryGroup group;

  /// 是否已经展开。
  final bool expanded;

  /// 点这一行时切换展开状态。
  final VoidCallback onTap;

  /// 海报的绝对地址，没刮到或客户端关掉刮削时为 null。
  final String? posterUrl;

  @override
  Widget build(BuildContext context) {
    final scrape = group.scrape;
    final title = (scrape?.title.isNotEmpty ?? false) ? scrape!.title : group.name;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                _Leading(
                  posterUrl: posterUrl,
                  fallback: Icon(
                    expanded ? Icons.folder_open : Icons.folder_outlined,
                    size: 20,
                    color: PavlColors.textDim,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 14),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        groupSubtitle(group, showScrape: posterUrl != null),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          color: PavlColors.textDim,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  expanded ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                  color: PavlColors.textDim,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 文件夹行下面那行说明：集数、评分与所属共享目录。
///
/// 集数与「个视频」分开说，是因为同一个文件夹里也可能躺着几部电影而不是一部
/// 剧——那些文件解析不出集号，写「集」会让人以为漏了编号。
///
/// [showScrape] 为假时不补年份与评分：客户端关掉刮削之后，行的副标题应当与
/// 没刮过片子的行长得一样，否则开关只关了一半。
String groupSubtitle(LibraryGroup group, {bool showScrape = true}) {
  final numbered = group.items.any((e) => (e.episode ?? 0) > 0);
  final unit = numbered ? '集' : '个视频';
  final parts = <String>['${group.count} $unit'];
  final scrape = group.scrape;
  if (showScrape && scrape != null) {
    if (scrape.year != null && scrape.year! > 0) parts.add('${scrape.year}');
    final score = scrape.rating;
    if (score != null && score > 0) parts.add('★ ${score.toStringAsFixed(1)}');
    if (scrape.genres.isNotEmpty) parts.add(scrape.genres.take(2).join(' / '));
  }
  if (group.root.isNotEmpty) parts.add(group.root);
  return parts.join(' · ');
}

/// 行首那半个图标位：有海报就显示海报，没有就显示原来的图标。
///
/// 尺寸固定，保证两种状态的行高一致——列表里混着刮到的与没刮到的行时，
/// 高度不一致会让滚动看起来在抖。
class _Leading extends StatelessWidget {
  const _Leading({required this.fallback, this.posterUrl});

  final Widget fallback;
  final String? posterUrl;

  static const double _width = 34;
  static const double _height = 48;

  @override
  Widget build(BuildContext context) {
    final url = posterUrl;
    if (url == null || url.isEmpty) {
      return SizedBox(
        width: _width,
        height: _height,
        child: Center(child: fallback),
      );
    }
    return SizedBox(
      width: _width,
      height: _height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Image.network(
          url,
          width: _width,
          height: _height,
          fit: BoxFit.cover,
          // 海报取不到时退回图标：网络断、服务端清了缓存、图片损坏都会走到
          // 这里，不该让整行变成空白。
          errorBuilder: (_, __, ___) => Center(child: fallback),
          // 占位用同色底，避免加载瞬间闪一下白块。
          loadingBuilder: (context, child, progress) => progress == null
              ? child
              : const ColoredBox(color: PavlColors.surfaceHigh),
        ),
      ),
    );
  }
}

/// 片库里的一部片。
class LibraryTile extends StatelessWidget {
  const LibraryTile({
    super.key,
    required this.entry,
    required this.onTap,
    this.indent = false,
    this.posterUrl,
  });

  final MediaEntry entry;
  final VoidCallback onTap;

  /// 是否缩进。展开文件夹之后里面的各集缩进一级，表示从属关系。
  final bool indent;

  /// 海报的绝对地址。展开后的各集不传——同一部剧的每一集海报都一样，
  /// 重复显示只是噪音。
  final String? posterUrl;

  @override
  Widget build(BuildContext context) {
    final title = entry.displayTitle;
    final episode = entry.episodeLabel;
    final meta = <String>[
      if (episode.isNotEmpty) episode,
      if (entry.year != null && entry.year! > 0) '${entry.year}',
      if (_readableSize(entry.size).isNotEmpty) _readableSize(entry.size),
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: EdgeInsets.fromLTRB(indent ? 40 : 12, 10, 12, 10),
            child: Row(
              children: [
                _Leading(
                  posterUrl: posterUrl,
                  fallback: const Icon(Icons.movie_outlined,
                      size: 20, color: PavlColors.accent),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 14),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        meta.isEmpty ? entry.path : meta.join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          color: PavlColors.textDim,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(Icons.play_circle_outline,
                    size: 18, color: PavlColors.textDim),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 最近播放的一行：多一条已看比例。
class LibraryRecentTile extends StatelessWidget {
  const LibraryRecentTile({super.key, required this.entry, required this.onTap});

  final RecentEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ratio = entry.ratio;
    final finished = entry.finished;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                const Icon(Icons.history, size: 18, color: PavlColors.textDim),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        entry.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 14),
                      ),
                      const SizedBox(height: 5),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: finished ? 1 : ratio,
                          minHeight: 3,
                          backgroundColor: PavlColors.surfaceHigh,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            finished ? PavlColors.success : PavlColors.accent,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  finished ? '已看完' : _percent(ratio),
                  style: const TextStyle(
                    fontSize: 11,
                    color: PavlColors.textDim,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _percent(double ratio) {
    if (ratio <= 0) return '未开始';
    return '${(ratio * 100).round()}%';
  }
}

/// 把字节数变成人能读的大小。
String _readableSize(int bytes) {
  if (bytes <= 0) return '';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var size = bytes.toDouble();
  var unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit++;
  }
  final text = size >= 100 ? size.toStringAsFixed(0) : size.toStringAsFixed(1);
  return '$text ${units[unit]}';
}
