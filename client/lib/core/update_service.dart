/// 在线更新：查 GitHub release、下载新包、替换本体。
///
/// 便携版不是一个安装程序，而是一个 zip。所以更新不能走「运行安装包」那一
/// 套，只能自己下载 zip、解开、替换文件，再把新版本拉起来。Windows 上运行
/// 中的 exe 不能直接被覆盖，但可以改名，于是流程是：先把本体改成 `.old`，
/// 把新文件铺进去，启动新本体，然后退出。`.old` 留给下次启动时清掉。
///
/// 下载走多连接分块：从国内拉 GitHub 的单个连接只有几十 KB/s，46 MB 的包要
/// 十几分钟，分成八块并发能到十倍以上。分块还能断点续传——某一块下完就落在
/// `*.parts/N.part` 里，下次只补没下完的块。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../store/app_store.dart';
import '../util/app_log.dart';
import '../util/build_info.dart';

/// 仓库坐标。PAVL 是公开仓库，查 release 不需要令牌。
const String kGitHubOwner = "LXinH3RT";
const String kGitHubRepo = "PAVL";
const String kReleasesPageUrl =
    "https://github.com/$kGitHubOwner/$kGitHubRepo/releases";
const String kLatestReleaseApiUrl =
    "https://api.github.com/repos/$kGitHubOwner/$kGitHubRepo/releases/latest";

/// 更新过程里能说清原因的失败。
///
/// [code] 给界面判断用（`network` / `notfound` / `ratelimit` / `http` /
/// `cancelled` / `install`），[message] 是可以直接显示给用户的中文句子。
class UpdateException implements Exception {
  UpdateException(this.message, {this.code});

  final String message;
  final String? code;

  @override
  String toString() => message;
}

/// 一个可下载的发布附件。
class ReleaseAsset {
  const ReleaseAsset({
    required this.name,
    required this.downloadUrl,
    required this.size,
  });

  final String name;
  final Uri downloadUrl;
  final int size;

  /// 人类可读的体积，弹窗里显示用。
  String get sizeText {
    if (size <= 0) return "未知大小";
    if (size < 1024 * 1024) return "${(size / 1024).toStringAsFixed(0)} KB";
    return "${(size / (1024 * 1024)).toStringAsFixed(1)} MB";
  }
}

/// 一次发布的信息。
class ReleaseInfo {
  const ReleaseInfo({
    required this.tag,
    required this.name,
    required this.body,
    required this.publishedAt,
    required this.assets,
  });

  final String tag;
  final String name;
  final String body;
  final DateTime? publishedAt;
  final List<ReleaseAsset> assets;

  /// 去掉 `v` 前缀与构建号之后的版本。
  String get version => normalizeVersion(tag);

  /// 按当前平台挑出该下哪个附件。
  ReleaseAsset? assetFor(String platform) {
    final want = platform == "macos" ? "macos_client" : "windows_client";
    for (final asset in assets) {
      final lower = asset.name.toLowerCase();
      if (!lower.endsWith(".zip")) continue;
      if (lower.contains(want)) return asset;
    }
    return null;
  }
}

/// 下载进度。
class DownloadProgress {
  const DownloadProgress({required this.received, required this.total});

  final int received;
  final int total;

  /// 总长未知时返回 null，界面画成不确定进度条。
  double? get fraction => total <= 0 ? null : (received / total).clamp(0.0, 1.0);

  String get receivedText => _mb(received);

  String get totalText => _mb(total);

  static String _mb(int bytes) =>
      "${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB";
}

/// 取消下载的把手。
///
/// 用户关掉弹窗时置位，正在跑的请求在下一个回调点退出。
class DownloadCancellation {
  bool _cancelled = false;

  bool get cancelled => _cancelled;

  void cancel() => _cancelled = true;

  void throwIfCancelled() {
    if (_cancelled) throw UpdateException("已取消", code: "cancelled");
  }
}

/// 版本号归一：「v0.2.3+5」→「0.2.3」。
String normalizeVersion(String raw) {
  var text = raw.trim();
  if (text.isEmpty) return text;
  if (text[0] == "v" || text[0] == "V") text = text.substring(1).trim();
  final plus = text.indexOf("+");
  if (plus >= 0) text = text.substring(0, plus);
  // 预发布后缀直接截掉：PAVL 只发正式版，`1.0.0-beta` 这种不需要参与比较。
  final dash = text.indexOf("-");
  if (dash > 0) text = text.substring(0, dash);
  return text.trim();
}

List<int> _versionParts(String version) => normalizeVersion(version)
    .split(".")
    .map((piece) => int.tryParse(piece) ?? 0)
    .toList(growable: false);

/// 逐段比数字，缺的段按 0 补。
int compareVersions(String a, String b) {
  final left = _versionParts(a);
  final right = _versionParts(b);
  final length = left.length > right.length ? left.length : right.length;
  for (var i = 0; i < length; i++) {
    final l = i < left.length ? left[i] : 0;
    final r = i < right.length ? right[i] : 0;
    if (l != r) return l < r ? -1 : 1;
  }
  return 0;
}

/// [latest] 是否比 [current] 新。
bool isNewerVersion(String latest, {String current = appVersion}) =>
    compareVersions(latest, current) > 0;

/// 当前平台标识，用来挑附件。
String get currentPlatform {
  if (Platform.isMacOS) return "macos";
  if (Platform.isWindows) return "windows";
  return Platform.operatingSystem;
}

/// 本地放更新包的地方。
///
/// 放在数据目录而不是系统临时目录：分块下载留下的半成品要在重启后还能接着
/// 用，临时目录会被系统清掉。
Directory updateDownloadsDir() =>
    Directory("${appDataDir().path}${Platform.pathSeparator}update");

/// 拼路径。不用 package:path，少一个依赖。
String joinPath(String parent, String child) =>
    parent.endsWith(Platform.pathSeparator)
        ? "$parent$child"
        : "$parent${Platform.pathSeparator}$child";

/// 查最新版本、下载、替换。整个流程都在客户端做。
class UpdateService {
  UpdateService({
    this.timeout = const Duration(seconds: 20),
    HttpClient? client,
  }) : _client = client ?? HttpClient() {
    _client.connectionTimeout = const Duration(seconds: 10);
  }

  final Duration timeout;
  final HttpClient _client;

  void close() => _client.close(force: true);

  /// 查最新一次发布。
  ///
  /// 匿名访问 public 仓库每小时 60 次，正常点几百下也用不完，但被挡时要能说
  /// 清是「限流」而不是「网络不通」。
  Future<ReleaseInfo> fetchLatest() async {
    final request = await _client
        .getUrl(Uri.parse(kLatestReleaseApiUrl))
        .timeout(timeout, onTimeout: () => throw _networkTimeout());
    request.headers
      ..set(HttpHeaders.acceptHeader, "application/vnd.github+json")
      ..set("X-GitHub-Api-Version", "2022-11-28")
      ..set(HttpHeaders.userAgentHeader, "PAVL/$appVersion");
    final response = await request.close().timeout(
          timeout,
          onTimeout: () => throw _networkTimeout(),
        );
    final text = await utf8.decoder.bind(response).join();
    if (response.statusCode == 404) {
      throw UpdateException("仓库里还没有已发布的版本。", code: "notfound");
    }
    if (response.statusCode == 403 || response.statusCode == 429) {
      throw UpdateException(
        "GitHub 拒绝了这次查询（接口限流）。等一会儿再试。",
        code: "ratelimit",
      );
    }
    if (response.statusCode != 200) {
      throw UpdateException(
        "查询失败：HTTP ${response.statusCode}",
        code: "http",
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw UpdateException("GitHub 返回的不是合法 JSON。", code: "http");
    }
    if (decoded is! Map<String, Object?>) {
      throw UpdateException("发布信息格式不对。", code: "http");
    }
    return _parseRelease(decoded);
  }

  ReleaseInfo _parseRelease(Map<String, Object?> json) {
    final assets = <ReleaseAsset>[];
    final rawAssets = json["assets"];
    if (rawAssets is List) {
      for (final raw in rawAssets) {
        if (raw is! Map) continue;
        final name = raw["name"];
        final url = raw["browser_download_url"];
        if (name is! String || url is! String) continue;
        final uri = Uri.tryParse(url);
        if (uri == null) continue;
        final size = raw["size"];
        assets.add(
          ReleaseAsset(
            name: name,
            downloadUrl: uri,
            size: size is int ? size : 0,
          ),
        );
      }
    }
    final published = json["published_at"];
    return ReleaseInfo(
      tag: (json["tag_name"] as String?) ?? "",
      name: (json["name"] as String?) ?? "",
      body: (json["body"] as String?) ?? "",
      publishedAt: published is String ? DateTime.tryParse(published) : null,
      assets: assets,
    );
  }

  /// 下载附件到 [directory]，返回落地的文件。
  ///
  /// 分块并发；服务器不支持 Range 时退回单连接。[onProgress] 会按大约 200ms
  /// 的节奏回调，不跟着字节数抖。
  Future<File> download(
    ReleaseAsset asset, {
    Directory? directory,
    void Function(DownloadProgress)? onProgress,
    DownloadCancellation? cancellation,
    int concurrency = 8,
  }) async {
    final dir = directory ?? updateDownloadsDir();
    await dir.create(recursive: true);
    final target = File(joinPath(dir.path, asset.name));
    final parts = Directory("${target.path}.parts");

    // 已经下完了就直接用，不再重下一遍。
    if (await target.exists() && asset.size > 0) {
      if (await target.length() == asset.size) {
        onProgress?.call(DownloadProgress(received: asset.size, total: asset.size));
        return target;
      }
      await target.delete();
    }

    final total = asset.size;
    final canSplit = total >= 4 * 1024 * 1024 && concurrency > 1;
    final rangesSupported = canSplit && await _supportsRanges(asset);

    if (!rangesSupported) {
      await _downloadSingle(
        asset,
        target,
        onProgress: onProgress,
        cancellation: cancellation,
      );
      return target;
    }

    final chunkCount = concurrency.clamp(2, 16);
    final chunkSize = (total / chunkCount).ceil();
    await parts.create(recursive: true);

    // 已下完的块留着，只补缺的。
    final completed = List<int>.filled(chunkCount, 0);
    for (var i = 0; i < chunkCount; i++) {
      final file = File(joinPath(parts.path, "$i.part"));
      final expected = _chunkLength(i, chunkSize, total, chunkCount);
      if (await file.exists()) {
        final length = await file.length();
        if (length == expected) {
          completed[i] = length;
        } else {
          await file.delete();
        }
      }
    }

    var lastReport = DateTime.fromMillisecondsSinceEpoch(0);
    var reported = 0;
    void report({bool force = false}) {
      final received = completed.fold<int>(0, (sum, value) => sum + value);
      if (!force) {
        final now = DateTime.now();
        if (now.difference(lastReport).inMilliseconds < 200) return;
        lastReport = now;
      }
      if (received == reported && !force) return;
      reported = received;
      onProgress?.call(DownloadProgress(received: received, total: total));
    }

    report(force: true);

    final tasks = <Future<void>>[];
    for (var i = 0; i < chunkCount; i++) {
      final expected = _chunkLength(i, chunkSize, total, chunkCount);
      if (completed[i] == expected) continue;
      final start = i * chunkSize;
      final end = start + expected - 1;
      tasks.add(
        _downloadChunk(
          asset,
          File(joinPath(parts.path, "$i.part")),
          start,
          end,
          onBytes: (delta) {
            completed[i] += delta;
            report();
          },
          cancellation: cancellation,
        ),
      );
    }
    await Future.wait(tasks);
    cancellation?.throwIfCancelled();
    report(force: true);

    // 拼起来。
    final sink = target.openWrite();
    try {
      for (var i = 0; i < chunkCount; i++) {
        final file = File(joinPath(parts.path, "$i.part"));
        await sink.addStream(file.openRead());
      }
      await sink.flush();
    } finally {
      await sink.close();
    }

    final written = await target.length();
    if (total > 0 && written != total) {
      await target.delete();
      throw UpdateException(
        "下载不完整（$written/$total 字节），请重试。",
        code: "network",
      );
    }
    await _deleteQuietly(parts);
    return target;
  }

  /// 丢掉没下完的半成品。
  Future<void> discardPartial(ReleaseAsset asset, {Directory? directory}) async {
    final dir = directory ?? updateDownloadsDir();
    final target = File(joinPath(dir.path, asset.name));
    await _deleteQuietly(File("${target.path}.parts"));
    await _deleteQuietly(target);
  }

  int _chunkLength(int index, int chunkSize, int total, int count) {
    final start = index * chunkSize;
    if (start >= total) return 0;
    final end = start + chunkSize;
    return (end > total ? total : end) - start;
  }

  Future<bool> _supportsRanges(ReleaseAsset asset) async {
    try {
      final request = await _client
          .getUrl(asset.downloadUrl)
          .timeout(timeout, onTimeout: () => throw _networkTimeout());
      request.headers.set(HttpHeaders.rangeHeader, "bytes=0-0");
      request.headers.set(HttpHeaders.userAgentHeader, "PAVL/$appVersion");
      final response = await request.close().timeout(
            timeout,
            onTimeout: () => throw _networkTimeout(),
          );
      final ok = response.statusCode == 206;
      await response.drain<void>();
      return ok;
    } catch (error) {
      logLine("update", "探测 Range 失败，改用单连接：$error");
      return false;
    }
  }

  Future<void> _downloadSingle(
    ReleaseAsset asset,
    File target, {
    void Function(DownloadProgress)? onProgress,
    DownloadCancellation? cancellation,
  }) async {
    final partial = File("${target.path}.part");
    var received = 0;
    var offset = 0;
    if (await partial.exists()) {
      offset = await partial.length();
      received = offset;
    }
    final request = await _client
        .getUrl(asset.downloadUrl)
        .timeout(timeout, onTimeout: () => throw _networkTimeout());
    request.headers.set(HttpHeaders.userAgentHeader, "PAVL/$appVersion");
    if (offset > 0) {
      request.headers.set(HttpHeaders.rangeHeader, "bytes=$offset-");
    }
    final response = await request.close().timeout(
          timeout,
          onTimeout: () => throw _networkTimeout(),
        );
    // 服务器忽略 Range 时会回 200 + 全量，必须从头写。
    final append = offset > 0 && response.statusCode == 206;
    if (!append) {
      received = 0;
      offset = 0;
    }
    if (response.statusCode != 200 && response.statusCode != 206) {
      throw UpdateException(
        "下载失败：HTTP ${response.statusCode}",
        code: "network",
      );
    }
    final total = asset.size > 0 ? asset.size : received + response.contentLength;
    final sink = partial.openWrite();
    if (append) {
      // 追加写：先算好偏移，避免 openWrite 截断。
      await sink.close();
      final raf = await partial.open(mode: FileMode.append);
      try {
        await for (final chunk in response) {
          cancellation?.throwIfCancelled();
          await raf.writeFrom(chunk);
          received += chunk.length;
          onProgress?.call(DownloadProgress(received: received, total: total));
        }
      } finally {
        await raf.close();
      }
    } else {
      try {
        await for (final chunk in response) {
          cancellation?.throwIfCancelled();
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(DownloadProgress(received: received, total: total));
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
    }
    if (await target.exists()) await target.delete();
    await partial.rename(target.path);
  }

  Future<void> _downloadChunk(
    ReleaseAsset asset,
    File file,
    int start,
    int end, {
    required void Function(int delta) onBytes,
    DownloadCancellation? cancellation,
  }) async {
    const maxAttempts = 4;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      cancellation?.throwIfCancelled();
      final raf = await file.open(mode: FileMode.write);
      try {
        final request = await _client
            .getUrl(asset.downloadUrl)
            .timeout(timeout, onTimeout: () => throw _networkTimeout());
        request.headers.set(HttpHeaders.rangeHeader, "bytes=$start-$end");
        request.headers.set(HttpHeaders.userAgentHeader, "PAVL/$appVersion");
        final response = await request.close().timeout(
              timeout,
              onTimeout: () => throw _networkTimeout(),
            );
        if (response.statusCode != 206) {
          await response.drain<void>();
          throw UpdateException(
            "分块下载失败：HTTP ${response.statusCode}",
            code: "network",
          );
        }
        await for (final chunk in response) {
          cancellation?.throwIfCancelled();
          await raf.writeFrom(chunk);
          onBytes(chunk.length);
        }
        return;
      } catch (error) {
        if (error is UpdateException && error.code == "cancelled") rethrow;
        final retryable = attempt < maxAttempts - 1;
        logLine(
          "update",
          "第 ${attempt + 1} 次下载分块 $start-$end 失败${retryable ? "，重试" : ""}：$error",
        );
        if (!retryable) {
          throw UpdateException("下载失败：$error", code: "network");
        }
        await Future<void>.delayed(Duration(milliseconds: 400 * (attempt + 1)));
      } finally {
        await raf.close();
      }
    }
  }

  UpdateException _networkTimeout() =>
      UpdateException("连接 GitHub 超时，检查一下网络。", code: "network");
}

/// 递归删目录，不存在的当成功。
Future<void> _deleteQuietly(FileSystemEntity entity) async {
  try {
    if (await entity.exists()) await entity.delete(recursive: true);
  } catch (error) {
    logLine("update", "清理 ${entity.path} 失败：$error");
  }
}

/// 上次更新留下的中间文件，启动时清一次。
///
/// Windows 上运行中的 exe 只能改名不能删，所以更新时会把本体改成 `.old`，
/// 那时删不掉，只能等下次启动、新本体在跑的时候再清。macOS 换的是整个
/// `.app`，同样会留一份 `<App>.app.old` 在安装目录里。
///
/// 另外顺手清掉 `update/staged-*`：那是解压出来铺文件用的，铺完就该没了。
/// 但接管更新时新进程正从 staged 里跑起来，那一刻删不掉，于是留到这次启动；
/// 删不掉也只是一次空操作，下次再试。下载中的 zip 不能动——那是断点续传的
/// 依据。
Future<void> cleanStaleFiles() async {
  try {
    final exe = File(Platform.resolvedExecutable);
    if (Platform.isMacOS) {
      // 从 Contents/MacOS 往上找到 .app 的父目录，删掉遗留的 .old 整包。
      var dir = exe.parent;
      while (true) {
        if (dir.path.toLowerCase().endsWith(".app")) {
          final stale = Directory("${dir.parent.path}${Platform.pathSeparator}"
              "${dir.uri.pathSegments.where((s) => s.isNotEmpty).last}.old");
          if (await stale.exists()) {
            await stale.delete(recursive: true);
            logLine("update", "清理上次更新留下的 ${stale.path}");
          }
          break;
        }
        final parent = dir.parent;
        if (parent.path == dir.path) break;
        dir = parent;
      }
    } else {
      // 换本体时不是只换 exe：同目录的 dll、data 都在更新范围内，
      // 动不了的那些都改名成 `.old` 留在原地，这里一并清掉。
      await for (final entity in exe.parent.list(followLinks: false)) {
        final name = entity.uri.pathSegments
            .where((segment) => segment.isNotEmpty)
            .last;
        if (entity is! File || !name.endsWith(".old")) continue;
        try {
          await entity.delete();
          logLine("update", "清理上次更新留下的 ${entity.path}");
        } catch (_) {
          // 还占着就先留着，下次启动再清。
        }
      }
    }
  } catch (error) {
    logLine("update", "清理旧本体失败：$error");
  }
  // 无论哪个平台都要清，staged 是解压中间产物，跟平台无关。
  await _cleanStagedDirectories();
}

/// 清掉 `update/staged-*`。失败的直接跳过，不影响启动。
Future<void> _cleanStagedDirectories() async {
  try {
    final dir = updateDownloadsDir();
    if (!await dir.exists()) return;
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final name = entity.uri.pathSegments
          .where((segment) => segment.isNotEmpty)
          .last;
      if (!name.startsWith("staged-")) continue;
      try {
        await entity.delete(recursive: true);
        logLine("update", "清理更新解压目录 ${entity.path}");
      } catch (_) {
        // 还在跑或者被占用，下次启动再清。
      }
    }
  } catch (error) {
    logLine("update", "清理更新解压目录失败：$error");
  }
}
