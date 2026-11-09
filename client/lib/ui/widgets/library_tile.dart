/// 片库列表的行。
///
/// 与浏览页的 [EntryTile] 分开：那边每行是一个文件系统条目，要显示「几项」、
/// 文件夹图标、外挂字幕提示；这边每行是一部片，要显示解析出来的标题、季集
/// 编号和文件大小。硬塞进同一个组件会让两边都长出一堆「当前是不是目录」的
/// 分支。
library;

import 'package:flutter/material.dart';

import '../../api/pavl_client.dart';
import '../../app.dart';

/// 片库里的一部片。
class LibraryTile extends StatelessWidget {
  const LibraryTile({super.key, required this.entry, required this.onTap});

  final MediaEntry entry;
  final VoidCallback onTap;

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
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
