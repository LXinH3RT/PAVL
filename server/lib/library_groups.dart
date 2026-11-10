/// 把片库的扁平索引收成「文件夹 + 集数」的行。
///
/// 片库原本是跨目录拉平的一张表，一部剧几十集就占几十行，找片时得一路往下
/// 滚。这里按目录收拢：同一文件夹里的多个视频合成一行，行上写集数，展开后
/// 才是各个文件。
///
/// 层级最多两层，多的部分不再细分：目录层级由共享端自己组织，命名里塞三层
/// 以上只会让每一行都变得很长。超过两层的视频仍归到前两层那一行里，展开时
/// 靠文件名区分。
///
/// 只装了一个视频的文件夹不单独占一行，直接显示成那一集——收拢的意义是把
/// 几十集压成一行，只有一个文件时反而多了一次点击。
///
/// 目录名相同但根目录不同的两个文件夹不算同一个（键里带根名），这样两个共
/// 享目录下同名的剧不会混成一行。
library;

import 'library.dart';
import 'sort_key.dart';

/// 片库里的一行：要么是一个文件夹（含若干视频），要么是一个散放的视频。
class LibraryGroup {
  LibraryGroup._({
    required this.isDir,
    required this.path,
    required this.name,
    required this.root,
    required this.videos,
  });

  /// 由文件夹收成的一行。
  factory LibraryGroup.dir({
    required String path,
    required String name,
    required String root,
    required List<MediaEntry> videos,
  }) =>
      LibraryGroup._(
        isDir: true,
        path: path,
        name: name,
        root: root,
        videos: videos,
      );

  /// 由单个视频构成的一行。
  factory LibraryGroup.video(MediaEntry entry) => LibraryGroup._(
        isDir: false,
        path: entry.relativePath,
        name: entry.parsed.title.isEmpty ? entry.baseName : entry.parsed.title,
        root: entry.rootName,
        videos: [entry],
      );

  /// 是不是文件夹行。
  final bool isDir;

  /// 文件夹的完整相对路径（`根名/一层/二层`），或视频的 `relativePath`。
  final String path;

  /// 显示名：文件夹取最多两段目录名，用 ` / ` 连接；视频取解析出的标题。
  final String name;

  /// 所属根目录的展示名。
  final String root;

  /// 这一行的视频，按路径排好序；文件夹行里至少一个。
  final List<MediaEntry> videos;

  /// 视频条数，文件夹行就是行上要显示的集数。
  int get count => videos.length;

  Map<String, Object?> toJson() => {
        'kind': isDir ? 'dir' : 'video',
        'path': path,
        'name': name,
        'root': root,
        'count': count,
        'items': videos.map((e) => e.toJson()).toList(),
      };
}

/// 每个文件夹最多认几层目录名。
const int libraryGroupDepth = 2;

/// 把索引按目录收成行，再按显示名排序。
///
/// 排序沿用 [compareNames]：数字段按数值、汉字按拼音，与浏览页一致。同名时
/// 比路径，保证顺序全序、翻页不重不漏。
List<LibraryGroup> groupLibrary(List<MediaEntry> all, {int maxDepth = libraryGroupDepth}) {
  final dirs = <String, _DirAgg>{};
  final videos = <LibraryGroup>[];

  for (final entry in all) {
    final segments = entry.relativePath.split('/');
    // 最后一段是文件名，前面的才是目录；第一段是根目录名。
    final dirSegments =
        segments.length > 1 ? segments.sublist(0, segments.length - 1) : const <String>[];
    final under = dirSegments.length > 1 ? dirSegments.sublist(1) : const <String>[];
    if (under.isEmpty) {
      videos.add(LibraryGroup.video(entry));
      continue;
    }
    final take = under.length < maxDepth ? under.length : maxDepth;
    final picked = under.sublist(0, take);
    final key = '${dirSegments.first}/${picked.join('/')}';
    final agg = dirs.putIfAbsent(
      key,
      () => _DirAgg(
        path: key,
        name: picked.join(' / '),
        root: dirSegments.first,
      ),
    );
    agg.videos.add(entry);
  }

  final rows = <LibraryGroup>[];
  for (final agg in dirs.values) {
    agg.videos.sort((a, b) => compareNames(a.relativePath, b.relativePath));
    // 只有一个视频的文件夹不值得先点一下再点一下：直接把它显示成那一集。
    if (agg.videos.length == 1) {
      rows.add(LibraryGroup.video(agg.videos.first));
      continue;
    }
    rows.add(LibraryGroup.dir(
      path: agg.path,
      name: agg.name,
      root: agg.root,
      videos: agg.videos,
    ));
  }
  rows.addAll(videos);

  rows.sort((a, b) {
    final byName = compareNames(a.name, b.name);
    if (byName != 0) return byName;
    return compareNames(a.path, b.path);
  });
  return rows;
}

class _DirAgg {
  _DirAgg({required this.path, required this.name, required this.root});

  final String path;
  final String name;
  final String root;
  final List<MediaEntry> videos = [];
}
