/// 列表里的一个条目：目录或视频。
library;

import 'package:flutter/material.dart';

import '../../api/pavl_client.dart';
import '../../app.dart';

/// 条目行。
///
/// 视频如果带有外挂字幕，会在标题下面挂一小行说明，把字幕和视频在界面上
/// 关联起来，而不是让字幕文件自己占一行。
class EntryTile extends StatelessWidget {
  const EntryTile({super.key, required this.entry, required this.onTap});

  final BrowseEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final subtitles = entry.subtitles;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _icon(),
                const SizedBox(width: 14),
                Expanded(child: _titleBlock(subtitles)),
                if (entry.isDir)
                  Text(
                    '${entry.children} 项',
                    style: const TextStyle(
                      fontSize: 12,
                      color: PavlColors.textDim,
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text(
                      _readableSize(entry.size),
                      style: const TextStyle(
                        fontSize: 12,
                        color: PavlColors.textDim,
                      ),
                    ),
                  ),
                const SizedBox(width: 8),
                Icon(
                  entry.isDir ? Icons.chevron_right : Icons.play_circle_outline,
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

  Widget _titleBlock(List<BrowseSubtitle> subtitles) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          entry.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14),
        ),
        if (subtitles.isNotEmpty) ...[
          const SizedBox(height: 3),
          Row(
            children: [
              const Icon(
                Icons.subtitles_outlined,
                size: 12,
                color: PavlColors.textDim,
              ),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  _subtitleSummary(subtitles),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    color: PavlColors.textDim,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  /// 字幕说明：匹配上就报数量，没匹配上要说明是目录里唯一一部片才挂过来的。
  static String _subtitleSummary(List<BrowseSubtitle> subtitles) {
    final matched = subtitles.where((item) => item.matched).length;
    if (matched == subtitles.length) {
      return '${subtitles.length} 条外挂字幕';
    }
    if (matched == 0) {
      return '${subtitles.length} 条同目录字幕（文件名未匹配）';
    }
    return '$matched 条已匹配，${subtitles.length - matched} 条同目录';
  }

  Widget _icon() {
    final (IconData icon, Color color) = switch (entry.kind) {
      'video' => (Icons.movie_outlined, PavlColors.accent),
      'subtitle' => (Icons.subtitles_outlined, PavlColors.textDim),
      'audio' => (Icons.audiotrack_outlined, PavlColors.textDim),
      'image' => (Icons.image_outlined, PavlColors.textDim),
      _ => entry.isDir
          ? (Icons.folder_outlined, const Color(0xFFD9A441))
          : (Icons.insert_drive_file_outlined, PavlColors.textDim),
    };
    return Icon(icon, size: 20, color: color);
  }

  /// 把字节数变成人能读的大小。
  static String _readableSize(int bytes) {
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
}
