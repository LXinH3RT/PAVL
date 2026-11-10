/// 片库列表的行。
///
/// 与浏览页的 [EntryTile] 分开：那边每行是一个文件系统条目，要显示「几项」、
/// 文件夹图标、外挂字幕提示；这边每行是一部片或一个收拢后的文件夹，要显示
/// 解析出来的标题、季集编号和文件大小。硬塞进同一个组件会让两边都长出一堆
/// 「当前是不是目录」的分支。
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
  });

  final LibraryGroup group;

  /// 是否已经展开。
  final bool expanded;

  /// 点这一行时切换展开状态。
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
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
                Icon(
                  expanded ? Icons.folder_open : Icons.folder_outlined,
                  size: 20,
                  color: PavlColors.textDim,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        group.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 14),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        groupSubtitle(group),
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

/// 文件夹行下面那行说明：集数与所属共享目录。
///
/// 集数与「个视频」分开说，是因为同一个文件夹里也可能躺着几部电影而不是一部
/// 剧——那些文件解析不出集号，写「集」会让人以为漏了编号。
String groupSubtitle(LibraryGroup group) {
  final numbered = group.items.any((e) => (e.episode ?? 0) > 0);
  final unit = numbered ? '集' : '个视频';
  final parts = <String>['${group.count} $unit'];
  if (group.root.isNotEmpty) parts.add(group.root);
  return parts.join(' · ');
}

/// 片库里的一部片。
class LibraryTile extends StatelessWidget {
  const LibraryTile({
    super.key,
    required this.entry,
    required this.onTap,
    this.indent = false,
  });

  final MediaEntry entry;
  final VoidCallback onTap;

  /// 是否缩进。展开文件夹之后里面的各集缩进一级，表示从属关系。
  final bool indent;

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
                const Icon(Icons.movie_outlined,
                    size: 20, color: PavlColors.accent),
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
