/// 服务端自更新：查 GitHub 最新发布、下载、替换自身、重启。
///
/// 和客户端是同一套思路，只是没有界面——入口在托盘菜单。
///
/// 难点同样是 **Windows 上运行中的 exe 不能被覆盖**。做法：
///
/// 1. 旧进程把 zip 解到 `<数据目录>/update/staged-<版本>/`；
/// 2. 写 `pending.json`，拉起 staged 里的新 `pavl.exe`，带上
///    `--apply-update=<标记文件>` 与同样的数据目录环境变量；
/// 3. 新本体启动后只做一件事：等旧进程退出（轮询能否改名），把文件铺进安装
///    目录，再从安装目录正常启动、自己退出。
///
/// 服务端的包只有三个文件（`pavl.exe` / `LICENSE.txt` / `README.txt`），铺过去
/// 很轻；`PAVL-data` 是用户数据，永远不碰。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'pavl_server.dart' show pavlVersion;

/// 仓库坐标。
const String githubOwner = 'LXinH3RT';
const String githubRepo = 'PAVL';

/// 发布页与最新版本接口。
String get releasesPageUrl => 'https://github.com/$githubOwner/$githubRepo/releases';
String get latestReleaseApiUrl =>
    'https://api.github.com/repos/$githubOwner/$githubRepo/releases/latest';

/// 命令行约定：新本体被拉起时带这个前缀做自我替换。
const String applyUpdateFlag = '--apply-update=';

/// 检查或替换失败时抛这个，带上人话。
class UpdateException implements Exception {
  UpdateException(this.message, {this.code});

  final String message;
  final String? code;

  @override
  String toString() => message;
}

/// 一个可下载的发布包。
class ReleaseAsset {
  const ReleaseAsset({
    required this.name,
    required this.url,
    required this.size,
  });

  final String name;
  final Uri url;
  final int size;

  String get sizeText {
    final mb = size / (1024 * 1024);
    return mb >= 1 ? '${mb.toStringAsFixed(1)} MB' : '${(size / 1024).round()} KB';
  }
}

/// GitHub 上的一个发布。
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

  /// `v0.2.4` → `0.2.4`。
  String get version => normalizeVersion(tag);

  /// 服务端那个包。
  ReleaseAsset? get serverAsset {
    for (final asset in assets) {
      if (asset.name.contains('windows_server') && asset.name.endsWith('.zip')) {
        return asset;
      }
    }
    return null;
  }
}

/// 去掉前缀 `v`、构建号与预发布后缀，只留 `1.2.3` 这样的主体。
String normalizeVersion(String raw) {
  var text = raw.trim();
  if (text.startsWith('v') || text.startsWith('V')) {
    text = text.substring(1);
  }
  final plus = text.indexOf('+');
  if (plus >= 0) text = text.substring(0, plus);
  final dash = text.indexOf('-');
  if (dash >= 0) text = text.substring(0, dash);
  return text;
}

/// 比较两个版本号：a<b 返回负数，相等返回 0，a>b 返回正数。
int compareVersions(String a, String b) {
  final left = normalizeVersion(a).split('.');
  final right = normalizeVersion(b).split('.');
  final length = left.length > right.length ? left.length : right.length;
  for (var i = 0; i < length; i++) {
    final l = i < left.length ? int.tryParse(left[i]) ?? 0 : 0;
    final r = i < right.length ? int.tryParse(right[i]) ?? 0 : 0;
    if (l != r) return l - r;
  }
  return 0;
}

/// [latest] 是否比当前版本新。
bool isNewerVersion(String latest, {String current = pavlVersion}) =>
    compareVersions(latest, current) > 0;

/// 数据目录下的更新工作区。
Directory updateWorkDir(String dataDir) =>
    Directory(_join(dataDir, 'update'));

String _join(String parent, String child) {
  if (parent.endsWith('\\') || parent.endsWith('/')) return '$parent$child';
  return '$parent${Platform.pathSeparator}$child';
}

/// 查 GitHub 上的最新发布。
Future<ReleaseInfo> fetchLatestRelease({Duration timeout = const Duration(seconds: 20)}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final uri = Uri.parse(latestReleaseApiUrl);
    final request = await client.getUrl(uri).timeout(timeout);
    request.headers.set('Accept', 'application/vnd.github+json');
    request.headers.set('X-GitHub-Api-Version', '2022-11-28');
    request.headers.set('User-Agent', 'PAVL-Server/$pavlVersion');
    final response = await request.close().timeout(timeout);
    final text = await response.transform(utf8.decoder).join();
    if (response.statusCode == 404) {
      throw UpdateException('仓库里还没有已发布的版本。', code: 'notfound');
    }
    if (response.statusCode == 403 || response.statusCode == 429) {
      throw UpdateException(
        'GitHub 拒绝了这次查询（接口限流）。等一会儿再试。',
        code: 'ratelimit',
      );
    }
    if (response.statusCode != 200) {
      throw UpdateException('查询失败：HTTP ${response.statusCode}', code: 'http');
    }
    final decoded = jsonDecode(text);
    if (decoded is! Map) {
      throw UpdateException('GitHub 返回的不是一个发布对象。', code: 'http');
    }
    return _parseRelease(decoded.cast<String, Object?>());
  } on UpdateException {
    rethrow;
  } on SocketException catch (error) {
    throw UpdateException('网络不通：${error.message}', code: 'network');
  } on TimeoutException {
    throw UpdateException('查询超时，请检查网络。', code: 'network');
  } finally {
    client.close(force: true);
  }
}

ReleaseInfo _parseRelease(Map<String, Object?> json) {
  final assets = <ReleaseAsset>[];
  final rawAssets = json['assets'];
  if (rawAssets is List) {
    for (final raw in rawAssets) {
      if (raw is! Map) continue;
      final name = raw['name'];
      final url = raw['browser_download_url'];
      if (name is! String || url is! String) continue;
      final parsed = Uri.tryParse(url);
      if (parsed == null) continue;
      assets.add(
        ReleaseAsset(
          name: name,
          url: parsed,
          size: raw['size'] is int ? raw['size']! as int : 0,
        ),
      );
    }
  }
  final published = json['published_at'];
  return ReleaseInfo(
    tag: json['tag_name'] is String ? json['tag_name']! as String : '',
    name: json['name'] is String ? json['name']! as String : '',
    body: json['body'] is String ? json['body']! as String : '',
    publishedAt: published is String ? DateTime.tryParse(published) : null,
    assets: assets,
  );
}

/// 下载更新包到 `<数据目录>/update/`，重名就直接覆盖重下。
Future<File> downloadAsset(
  ReleaseAsset asset, {
  required String dataDir,
  void Function(int received, int total)? onProgress,
}) async {
  final dir = updateWorkDir(dataDir);
  await dir.create(recursive: true);
  final target = File(_join(dir.path, asset.name));
  final part = File('${target.path}.part');
  if (await part.exists()) await part.delete();

  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final request = await client.getUrl(asset.url);
    request.headers.set('User-Agent', 'PAVL-Server/$pavlVersion');
    final response = await request.close();
    if (response.statusCode != 200) {
      throw UpdateException(
        '下载失败：HTTP ${response.statusCode}',
        code: 'network',
      );
    }
    final sink = part.openWrite();
    var received = 0;
    await for (final chunk in response) {
      sink.add(chunk);
      received += chunk.length;
      onProgress?.call(received, asset.size);
    }
    await sink.flush();
    await sink.close();
    if (asset.size > 0 && received != asset.size) {
      await part.delete();
      throw UpdateException(
        '下载不完整（$received/${asset.size} 字节），请重试。',
        code: 'network',
      );
    }
    if (await target.exists()) await target.delete();
    await part.rename(target.path);
    return target;
  } on UpdateException {
    rethrow;
  } on SocketException catch (error) {
    throw UpdateException('网络不通：${error.message}', code: 'network');
  } finally {
    client.close(force: true);
  }
}

/// 待办标记：谁铺到哪、启动什么。
class PendingUpdate {
  const PendingUpdate({
    required this.stagedRoot,
    required this.installRoot,
    required this.launchPath,
    required this.dataDir,
  });

  final String stagedRoot;
  final String installRoot;
  final String launchPath;
  final String dataDir;

  Map<String, Object?> toJson() => {
    'stagedRoot': stagedRoot,
    'installRoot': installRoot,
    'launchPath': launchPath,
    'dataDir': dataDir,
  };

  static PendingUpdate? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final staged = raw['stagedRoot'];
    final install = raw['installRoot'];
    final launch = raw['launchPath'];
    final data = raw['dataDir'];
    if (staged is! String || install is! String || launch is! String) return null;
    return PendingUpdate(
      stagedRoot: staged,
      installRoot: install,
      launchPath: launch,
      dataDir: data is String ? data : '',
    );
  }

  Future<void> write(File marker) async {
    await marker.parent.create(recursive: true);
    await marker.writeAsString(jsonEncode(toJson()), flush: true);
  }
}

/// 解压 zip 到目标目录。
Future<void> extractZip(File zip, Directory target) async {
  await target.create(recursive: true);
  final result = await Process.run('tar', <String>[
    '-xf',
    zip.path,
    '-C',
    target.path,
  ]);
  if (result.exitCode != 0) {
    throw UpdateException(
      '解压失败：${result.stderr.toString().trim()}',
      code: 'install',
    );
  }
}

/// 在解压结果里找 `pavl.exe` 所在目录。
String findPayloadRoot(Directory staged) {
  final direct = File(_join(staged.path, 'pavl.exe'));
  if (direct.existsSync()) return staged.path;
  for (final entity in staged.listSync()) {
    if (entity is Directory) {
      final nested = File(_join(entity.path, 'pavl.exe'));
      if (nested.existsSync()) return entity.path;
    }
  }
  throw UpdateException('更新包里没有找到 pavl.exe。', code: 'install');
}

/// 铺好文件、拉起接管进程，然后调用方必须退出。
///
/// 接管这一步不能交给刚下载的那个新 exe：它可能是 0.2.3 这种还没认识到
/// `--apply-update` 的构建，会当成普通启动，抢不到端口就退了，文件一个都
/// 铺不上。所以这里把**当前正在跑的这份 exe** 复制到更新目录里当替身——
/// 它认识自己的参数，能等旧进程真正退出之后再铺文件、再拉起新本体。
Future<void> beginApply({
  required File zip,
  required String version,
  required String dataDir,
  required String installRoot,
}) async {
  final work = updateWorkDir(dataDir);
  final staged = Directory(_join(work.path, 'staged-$version'));
  if (staged.existsSync()) staged.deleteSync(recursive: true);
  await extractZip(zip, staged);

  final payload = findPayloadRoot(staged);
  final marker = File(_join(work.path, 'pending.json'));

  await PendingUpdate(
    stagedRoot: payload,
    installRoot: installRoot,
    launchPath: _join(installRoot, 'pavl.exe'),
    dataDir: dataDir,
  ).write(marker);

  final helperDir = Directory(_join(work.path, 'helper-$version'));
  await helperDir.create(recursive: true);
  final helper = File(_join(helperDir.path, 'pavl.exe'));
  if (helper.existsSync()) helper.deleteSync();
  await File(Platform.resolvedExecutable).copy(helper.path);

  await Process.start(
    helper.path,
    <String>['$applyUpdateFlag${marker.path}'],
    mode: ProcessStartMode.detached,
    workingDirectory: helperDir.path,
    environment: {'PAVL_DATA_DIR': dataDir},
  );
}

/// 如果命令行带着 `--apply-update=`，就做替换并结束进程。
///
/// 返回 true 表示已经接管过，调用方不要再起服务。
Future<bool> applyPendingIfRequested(List<String> args) async {
  String? markerPath;
  for (final arg in args) {
    if (arg.startsWith(applyUpdateFlag)) {
      markerPath = arg.substring(applyUpdateFlag.length);
    }
  }
  if (markerPath == null) return false;

  final marker = File(markerPath);
  PendingUpdate? pending;
  try {
    if (await marker.exists()) {
      pending = PendingUpdate.fromJson(jsonDecode(await marker.readAsString()));
    }
  } catch (_) {
    pending = null;
  }
  if (pending == null) {
    stderr.writeln('[update] 更新标记读不出来，放弃接管');
    return false;
  }

  stderr.writeln('[update] 接管更新，等待旧进程退出');
  try {
    await _waitUntilReplaceable(pending.installRoot);
    await _copyPayload(Directory(pending.stagedRoot), Directory(pending.installRoot));
    await marker.delete();
    stderr.writeln('[update] 新版本已就位，启动 ${pending.launchPath}');
    await Process.start(
      pending.launchPath,
      const <String>[],
      mode: ProcessStartMode.detached,
      workingDirectory: pending.installRoot,
      environment: {'PAVL_DATA_DIR': pending.dataDir},
    );
    exit(0);
  } catch (error) {
    stderr.writeln('[update] 替换失败：$error');
    exit(1);
  }
}

/// 等到安装目录里的 pavl.exe 不再被占用。
///
/// 用「改名再改回来」当探针：能改名说明旧进程真的走了。
Future<void> _waitUntilReplaceable(String installRoot) async {
  final exe = _join(installRoot, 'pavl.exe');
  final probe = '$exe.probe';
  final deadline = DateTime.now().add(const Duration(seconds: 60));
  while (DateTime.now().isBefore(deadline)) {
    try {
      File(exe).renameSync(probe);
      File(probe).renameSync(exe);
      return;
    } catch (_) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  }
  throw UpdateException('等待旧进程退出超时。', code: 'install');
}

/// 覆盖式复制，跳过用户数据目录。
Future<void> _copyPayload(Directory source, Directory target) async {
  await for (final entity in source.list(followLinks: false)) {
    final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
    if (name == 'PAVL-data') continue;
    final dest = _join(target.path, name);
    if (entity is Directory) {
      await Directory(dest).create(recursive: true);
      await _copyPayload(entity, Directory(dest));
    } else if (entity is File) {
      if (File(dest).existsSync()) {
        try {
          File(dest).deleteSync();
        } catch (_) {
          // 运行中的旧本体删不掉就先改名腾位置。
          try {
            File(dest).renameSync('$dest.old');
          } catch (error) {
            stderr.writeln('[update] 无法替换 $dest：$error');
            continue;
          }
        }
      }
      await entity.copy(dest);
    }
  }
}

/// 清掉上次更新留下的 `.old` 文件。
void cleanStaleFiles(String installRoot) {
  try {
    for (final entity in Directory(installRoot).listSync()) {
      if (entity is File && entity.path.endsWith('.old')) {
        try {
          entity.deleteSync();
        } catch (_) {
          // 还占着就算了，下次再说。
        }
      }
    }
  } catch (_) {
    // 目录读不了不影响主流程。
  }
}

/// 清掉更新目录里的解压结果与替身副本。
///
/// 下载下来的 zip 不能动，那是断点续传的依据；`staged-*` 与 `helper-*`
/// 都是中间产物，留着只会占地方。
void cleanStaleUpdateDirs(String dataDir) {
  try {
    final work = updateWorkDir(dataDir);
    if (!work.existsSync()) return;
    for (final entity in work.listSync()) {
      if (entity is! Directory) continue;
      final name = entity.uri.pathSegments
          .where((segment) => segment.isNotEmpty)
          .last;
      if (!name.startsWith('staged-') && !name.startsWith('helper-')) continue;
      try {
        entity.deleteSync(recursive: true);
      } catch (_) {
        // 替身还在跑或者被占用，下次启动再清。
      }
    }
  } catch (_) {
    // 目录读不了不影响主流程。
  }
}
