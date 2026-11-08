/// 片库索引。
///
/// 服务端不解析视频内容，索引里保存的只有「文件系统中能看到的事实」：
/// 路径、大小、修改时间、扩展名、从文件名猜出的标题。
/// 时长、分辨率、编码这些需要读容器头的信息由客户端播放后回写。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'config.dart';
import 'media.dart';
import 'subtitle_match.dart';

/// 一个媒体条目的静态信息。
class MediaEntry {
  MediaEntry({
    required this.relativePath,
    required this.rootName,
    required this.size,
    required this.modifiedMs,
    required this.kind,
  });

  /// 相对根目录的路径，统一用 `/` 分隔，作为对外唯一标识。
  final String relativePath;

  /// 所属根目录的展示名。
  final String rootName;

  /// 字节大小。
  final int size;

  /// 修改时间，Unix 毫秒。
  final int modifiedMs;

  /// 种类。
  final MediaKind kind;

  String get fileName {
    final idx = relativePath.lastIndexOf('/');
    return idx < 0 ? relativePath : relativePath.substring(idx + 1);
  }

  String get baseName {
    final name = fileName;
    final idx = name.lastIndexOf('.');
    return idx <= 0 ? name : name.substring(0, idx);
  }

  ParsedName get parsed => parseFileName(baseName);

  Map<String, Object?> toJson() => {
        'path': relativePath,
        'root': rootName,
        'size': size,
        'mtime': modifiedMs,
        'kind': kind.name,
        'name': fileName,
        'title': parsed.title,
        if (parsed.year != null) 'year': parsed.year,
        if (parsed.season != null) 'season': parsed.season,
        if (parsed.episode != null) 'episode': parsed.episode,
      };
}

/// 目录项（浏览用）。
class BrowseSubtitle {
  BrowseSubtitle({
    required this.name,
    required this.relativePath,
    required this.size,
    this.matched = true,
  });

  final String name;
  final String relativePath;
  final int size;

  /// 是否按文件名匹配到了这个视频。
  ///
  /// 不匹配的条目是「同目录下不属于任何视频的散字幕」，只为不让文件凭空
  /// 消失才挂到列表里；界面要区分显示。
  final bool matched;

  Map<String, Object?> toJson() => {
        'name': name,
        'path': relativePath,
        'size': size,
        if (!matched) 'unmatched': true,
      };
}

class BrowseEntry {
  BrowseEntry({
    required this.name,
    required this.relativePath,
    required this.isDir,
    this.size = 0,
    this.modifiedMs = 0,
    this.kind = MediaKind.other,
    this.childCount = 0,
    List<BrowseSubtitle> subtitles = const [],
  }) : subtitles = List<BrowseSubtitle>.unmodifiable(subtitles);

  final String name;
  final String relativePath;
  final bool isDir;
  final int size;
  final int modifiedMs;
  final MediaKind kind;

  /// 目录内的条目数（仅目录有效）。
  final int childCount;

  /// 属于这个视频的外挂字幕。
  ///
  /// 字幕不再和视频平铺在同一层：一个目录里几十个字幕会把视频挤下去，用户
  /// 也看不出哪个字幕配哪部片。归属由 [subtitleBelongsTo] 判定。
  final List<BrowseSubtitle> subtitles;

  Map<String, Object?> toJson() => {
        'name': name,
        'path': relativePath,
        'isDir': isDir,
        if (!isDir) 'size': size,
        if (!isDir) 'mtime': modifiedMs,
        if (!isDir) 'kind': kind.name,
        if (isDir) 'children': childCount,
        if (subtitles.isNotEmpty)
          'subtitles': [for (final s in subtitles) s.toJson()],
      };
}

/// 列目录时的中间结构：先收集元数据，再决定字幕归属。
class _PendingFile {
  _PendingFile({
    required this.name,
    required this.relativePath,
    required this.size,
    required this.modifiedMs,
    required this.kind,
  });

  final String name;
  final String relativePath;
  final int size;
  final int modifiedMs;
  final MediaKind kind;
}

/// 片库索引服务。
///
/// 采用「按需扫描 + 内存缓存」：首次浏览某目录时同步扫描并缓存，
/// 之后按 mtime 判断是否失效。全库视图需要一次完整遍历，结果缓存到下次刷新。
class Library {
  Library(this.config);

  final ServerConfig config;

  /// 相对路径 → 目录项缓存。
  final Map<String, _DirCache> _dirs = {};

  /// 全库视频索引，`refreshAll()` 时整体重建。
  List<MediaEntry>? _allMedia;
  DateTime? _allMediaAt;
  bool _scanning = false;

  /// 当前是否正在全库扫描。
  bool get scanning => _scanning;

  /// 全库索引的构建时间。
  DateTime? get indexedAt => _allMediaAt;

  /// 已索引的视频数量。
  int get indexedCount => _allMedia?.length ?? 0;

  /// 清空缓存，强制下次重新扫描。
  void invalidate() {
    _dirs.clear();
    _allMedia = null;
    _allMediaAt = null;
  }

  /// 把相对路径解析为绝对路径，并校验没有越出根目录。
  ///
  /// 返回 null 表示路径非法（越权或根不存在）。
  RootDir? _resolveRoot(String relPath) {
    for (final root in config.roots) {
      if (relPath == root.displayName) return root;
      if (relPath.startsWith('${root.displayName}/')) return root;
    }
    return null;
  }

  /// 把「根名/子路径」翻译成绝对文件路径。
  String? resolveAbsolute(String relPath) {
    final root = _resolveRoot(relPath);
    if (root == null) return null;
    var sub = relPath == root.displayName
        ? ''
        : relPath.substring(root.displayName.length + 1);
    // 逐段校验，禁止 .. 逃逸。
    final parts = <String>[];
    for (final seg in sub.split('/')) {
      if (seg.isEmpty || seg == '.') continue;
      if (seg == '..') return null;
      parts.add(seg);
    }
    final sep = Platform.pathSeparator;
    final base = root.path.endsWith(sep) || root.path.endsWith('/')
        ? root.path
        : root.path + sep;
    final abs = base + parts.join(sep);
    // 二次确认：规范化后仍必须以根目录开头。
    final normalizedAbs = _normalize(abs);
    final normalizedRoot = _normalize(root.path);
    if (!normalizedAbs.toLowerCase().startsWith(
        normalizedRoot.toLowerCase())) {
      return null;
    }
    return abs;
  }

  static String _normalize(String path) {
    final isWindows = Platform.isWindows;
    var p = path.replaceAll(isWindows ? '\\' : '/', '/');
    final out = <String>[];
    for (final seg in p.split('/')) {
      if (seg.isEmpty || seg == '.') continue;
      if (seg == '..') {
        if (out.isNotEmpty) out.removeLast();
        continue;
      }
      out.add(seg);
    }
    final joined = out.join('/');
    return isWindows ? joined.toLowerCase() : joined;
  }

  /// 浏览某个目录。`relPath` 为空表示根列表。
  Future<List<BrowseEntry>> browse(String relPath, {String sort = 'name'}) async {
    if (relPath.isEmpty) {
      return [
        for (final root in config.roots)
          if (Directory(root.path).existsSync())
            BrowseEntry(
              name: root.displayName,
              relativePath: root.displayName,
              isDir: true,
              childCount: _cachedChildCount(root.displayName, root.path),
            ),
      ]..sort((a, b) => naturalCompare(a.name, b.name));
    }

    final abs = resolveAbsolute(relPath);
    if (abs == null) return const [];
    final dir = Directory(abs);
    if (!await dir.exists()) return const [];

    final cache = _dirs[relPath];
    if (cache != null && await cache.isFresh(dir)) {
      return _sortEntries(cache.entries, sort);
    }

    final entries = <BrowseEntry>[];
    final files = <_PendingFile>[];
    try {
      await for (final entity in dir.list(followLinks: false)) {
        final name = _baseName(entity.path);
        if (name.startsWith('.')) continue;
        final childRel = '$relPath/$name';
        if (entity is Directory) {
          entries.add(BrowseEntry(
            name: name,
            relativePath: childRel,
            isDir: true,
            childCount: 0,
          ));
        } else if (entity is File) {
          final kind = kindOf(name);
          if (kind == MediaKind.other) continue;
          final stat = await entity.stat();
          files.add(_PendingFile(
            name: name,
            relativePath: childRel,
            size: stat.size,
            modifiedMs: stat.modified.millisecondsSinceEpoch,
            kind: kind,
          ));
        }
      }
    } on FileSystemException {
      // 权限不足或无权限的目录直接当作空目录，不向客户端抛错。
      return const [];
    }

    // 字幕挂到视频下面，不平铺。
    final videos = <_PendingFile>[];
    final subtitles = <_PendingFile>[];
    for (final f in files) {
      if (f.kind == MediaKind.subtitle) {
        subtitles.add(f);
      } else {
        videos.add(f);
      }
    }
    final attached = <String, List<BrowseSubtitle>>{};
    final orphans = <_PendingFile>[];
    if (videos.isNotEmpty) {
      final keys = <String, SubtitleKey?>{};
      for (final v in videos) {
        keys[v.relativePath] = SubtitleKey.parse(v.name);
      }
      for (final sub in subtitles) {
        final subKey = SubtitleKey.parse(sub.name);
        _PendingFile? owner;
        if (subKey != null) {
          for (final v in videos) {
            final vk = keys[v.relativePath];
            if (vk != null && vk.matches(subKey)) {
              owner = v;
              break;
            }
          }
        }
        if (owner == null) {
          orphans.add(sub);
        } else {
          attached.putIfAbsent(owner.relativePath, () => []).add(
                BrowseSubtitle(
                  name: sub.name,
                  relativePath: sub.relativePath,
                  size: sub.size,
                ),
              );
        }
      }
    } else {
      orphans.addAll(subtitles);
    }

    // 一个视频都没匹配上的散字幕仍然单独列出，否则文件会凭空消失。
    if (orphans.isNotEmpty && videos.isNotEmpty) {
      final only = videos.length == 1 ? videos.first : null;
      if (only != null) {
        // 目录里只有一部片：没有别的候选，散字幕只能是它的。
        attached.putIfAbsent(only.relativePath, () => []).addAll(
              orphans.map((o) => BrowseSubtitle(
                    name: o.name,
                    relativePath: o.relativePath,
                    size: o.size,
                    matched: false,
                  )),
            );
        orphans.clear();
      }
    }

    for (final v in videos) {
      final subs = attached[v.relativePath];
      entries.add(BrowseEntry(
        name: v.name,
        relativePath: v.relativePath,
        isDir: false,
        size: v.size,
        modifiedMs: v.modifiedMs,
        kind: v.kind,
        subtitles: subs == null
            ? const []
            : (subs..sort((a, b) => naturalCompare(a.name, b.name))),
      ));
    }
    // 实在归不了的字幕单独保留，避免文件列表与文件系统不一致。
    for (final o in orphans) {
      entries.add(BrowseEntry(
        name: o.name,
        relativePath: o.relativePath,
        isDir: false,
        size: o.size,
        modifiedMs: o.modifiedMs,
        kind: o.kind,
      ));
    }

    _dirs[relPath] = _DirCache(entries, DateTime.now());
    return _sortEntries(entries, sort);
  }

  int _cachedChildCount(String relPath, String absPath) {
    final cache = _dirs[relPath];
    return cache?.entries.length ?? 0;
  }

  List<BrowseEntry> _sortEntries(List<BrowseEntry> entries, String sort) {
    final copy = List<BrowseEntry>.from(entries);
    switch (sort) {
      case 'size':
        copy.sort((a, b) {
          if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
          return b.size.compareTo(a.size);
        });
      case 'mtime':
        copy.sort((a, b) {
          if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
          return b.modifiedMs.compareTo(a.modifiedMs);
        });
      case 'natural':
        copy.sort((a, b) {
          if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
          return naturalCompare(a.name, b.name);
        });
      default:
        copy.sort((a, b) {
          if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        });
    }
    return copy;
  }

  /// 全库扫描，构建扁平索引。
  ///
  /// 这是一个耗时操作（取决于文件数量），调用方应当并发度受限、
  /// 且不要阻塞 HTTP 响应。
  Future<List<MediaEntry>> refreshAll({void Function(int count)? onProgress}) async {
    if (_scanning) return _allMedia ?? const [];
    _scanning = true;
    try {
      final result = <MediaEntry>[];
      for (final root in config.roots) {
        final rootDir = Directory(root.path);
        if (!await rootDir.exists()) continue;
        final rootName = root.displayName;
        try {
          await for (final entity
              in rootDir.list(recursive: true, followLinks: false)) {
            if (entity is! File) continue;
            final name = _baseName(entity.path);
            if (name.startsWith('.')) continue;
            final kind = kindOf(name);
            if (kind != MediaKind.video && kind != MediaKind.audio) continue;
            FileStat stat;
            try {
              stat = await entity.stat();
            } on FileSystemException {
              continue;
            }
            final rel = _relativeTo(root.path, entity.path);
            if (rel == null) continue;
            result.add(MediaEntry(
              relativePath: '$rootName/$rel',
              rootName: rootName,
              size: stat.size,
              modifiedMs: stat.modified.millisecondsSinceEpoch,
              kind: kind,
            ));
            if (result.length % 200 == 0) {
              onProgress?.call(result.length);
            }
          }
        } on FileSystemException {
          continue;
        }
      }
      result.sort((a, b) => naturalCompare(a.relativePath, b.relativePath));
      _allMedia = result;
      _allMediaAt = DateTime.now();
      onProgress?.call(result.length);
      return result;
    } finally {
      _scanning = false;
    }
  }

  /// 取全库索引，没有则触发一次扫描。
  Future<List<MediaEntry>> getAll() async {
    final cached = _allMedia;
    if (cached != null) return cached;
    return refreshAll();
  }

  /// 按路径精确查一个条目。
  Future<MediaEntry?> findEntry(String relPath) async {
    final all = await getAll();
    for (final entry in all) {
      if (entry.relativePath == relPath) return entry;
    }
    return null;
  }

  static String? _relativeTo(String root, String child) {
    final sep = Platform.pathSeparator;
    final normalizedRoot = root.endsWith(sep) ? root : root + sep;
    if (!child.toLowerCase().startsWith(normalizedRoot.toLowerCase())) {
      return null;
    }
    return child
        .substring(normalizedRoot.length)
        .replaceAll(Platform.pathSeparator, '/');
  }

  static String _baseName(String path) {
    final normalized = path.replaceAll('\\', '/');
    final idx = normalized.lastIndexOf('/');
    return idx < 0 ? normalized : normalized.substring(idx + 1);
  }
}

/// 单个目录的缓存。
class _DirCache {
  _DirCache(this.entries, this.at);

  final List<BrowseEntry> entries;
  final DateTime at;

  /// 5 分钟内的缓存直接复用；超时后仍复用，但会在后台刷新。
  Future<bool> isFresh(Directory dir) async {
    if (DateTime.now().difference(at) < const Duration(minutes: 5)) {
      return true;
    }
    return false;
  }
}

/// 元数据回写存储：客户端播放后写回的时长、编码、分辨率等。
class MetaStore {
  MetaStore(this.file);

  final File file;
  Map<String, Map<String, Object?>>? _cache;

  static MetaStore defaultStore() {
    final dir = ConfigStore.resolveConfigDir();
    return MetaStore(
        File('${dir.path}${Platform.pathSeparator}meta.json'));
  }

  Future<Map<String, Map<String, Object?>>> _load() async {
    final cached = _cache;
    if (cached != null) return cached;
    final map = <String, Map<String, Object?>>{};
    if (await file.exists()) {
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map) {
          decoded.forEach((key, value) {
            if (key is String && value is Map) {
              map[key] = value.cast<String, Object?>();
            }
          });
        }
      } on FormatException {
        // 损坏则从空开始。
      }
    }
    _cache = map;
    return map;
  }

  Future<Map<String, Object?>?> get(String path) async {
    final map = await _load();
    return map[path];
  }

  Future<void> put(String path, Map<String, Object?> meta) async {
    final map = await _load();
    map[path] = {...(map[path] ?? const {}), ...meta, 'updatedAt': DateTime.now().millisecondsSinceEpoch};
    await _flush(map);
  }

  Future<void> _flush(Map<String, Map<String, Object?>> map) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(map), flush: true);
    await tmp.rename(file.path);
  }
}

/// 播放进度存储。
class ProgressStore {
  ProgressStore(this.file);

  final File file;
  Map<String, Map<String, Object?>>? _cache;

  static ProgressStore defaultStore() {
    final dir = ConfigStore.resolveConfigDir();
    return ProgressStore(
        File('${dir.path}${Platform.pathSeparator}progress.json'));
  }

  Future<Map<String, Map<String, Object?>>> _load() async {
    final cached = _cache;
    if (cached != null) return cached;
    final map = <String, Map<String, Object?>>{};
    if (await file.exists()) {
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map) {
          decoded.forEach((key, value) {
            if (key is String && value is Map) {
              map[key] = value.cast<String, Object?>();
            }
          });
        }
      } on FormatException {
        // 从空开始。
      }
    }
    _cache = map;
    return map;
  }

  Future<Map<String, Object?>?> get(String path, {String? deviceId}) async {
    final map = await _load();
    final entry = map[path];
    if (entry == null) return null;
    if (deviceId == null) return entry;
    final perDevice = entry['devices'];
    if (perDevice is Map && perDevice[deviceId] is Map) {
      return (perDevice[deviceId] as Map).cast<String, Object?>();
    }
    return null;
  }

  Future<void> put(
    String path, {
    required double positionSec,
    required double durationSec,
    String? deviceId,
    String? deviceName,
    bool finished = false,
  }) async {
    final map = await _load();
    final now = DateTime.now().millisecondsSinceEpoch;
    final entry = map[path] ?? <String, Object?>{};
    final devices =
        (entry['devices'] is Map) ? (entry['devices'] as Map).cast<String, Object?>() : <String, Object?>{};
    final record = <String, Object?>{
      'position': positionSec,
      'duration': durationSec,
      'finished': finished,
      'updatedAt': now,
      if (deviceName != null) 'deviceName': deviceName,
    };
    // 最近一次播放的状态单独存一份，供「继续观看」直接取。
    entry['position'] = positionSec;
    entry['duration'] = durationSec;
    entry['finished'] = finished;
    entry['updatedAt'] = now;
    if (deviceId != null) {
      devices[deviceId] = record;
      entry['devices'] = devices;
    }
    map[path] = entry;
    await _flush(map);
  }

  Future<void> _flush(Map<String, Map<String, Object?>> map) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(map), flush: true);
    await tmp.rename(file.path);
  }

  /// 最近观看列表。
  Future<List<Map<String, Object?>>> recent({int limit = 20}) async {
    final map = await _load();
    final rows = <Map<String, Object?>>[];
    map.forEach((path, entry) {
      rows.add({'path': path, ...entry});
    });
    rows.sort((a, b) => (b['updatedAt'] as int? ?? 0)
        .compareTo(a['updatedAt'] as int? ?? 0));
    return rows.take(limit).toList();
  }
}
