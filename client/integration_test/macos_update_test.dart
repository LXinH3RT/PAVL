/// macOS 自动更新的端到端验证。
///
/// 这条路径不能只靠读代码确认：它要真的下载线上包、把磁盘上的 `.app`
/// 换掉，然后重启。最危险的一步是**定位替换目标**——macOS 的安装目录常常
/// 就是 `/Applications`，里面躺着一堆别人的应用。早期实现靠「扫安装目录里
/// 第一个 `.app`」，会认到 `AdGuard Mini.app` 之类的邻居，再把它改名、
/// 用 `ditto` 覆盖，等于毁掉别人的程序。所以测试里特意放一个名字排在最前
/// 的诱饵 `.app`，跑完必须完好无损。
///
/// 这个测试会改写磁盘、退出进程、下载几十兆，所以默认跳过，只在你明确要
/// 验证更新链路时打开：
///
///     cd client
///     flutter test integration_test/macos_update_test.dart -d macos \
///       --dart-define=PAVL_TEST_UPDATE=1 \
///       --dart-define=PAVL_VERSION=0.0.9 \
///       --dart-define=PAVL_TEST_EXPECT=0.2.4
///
/// 三个参数的意思：`PAVL_TEST_UPDATE` 是开关；`PAVL_VERSION` 要比线上发布
/// 低，否则走「已经是最新版本」分支，测不到替换；`PAVL_TEST_EXPECT` 是期望
/// 查到的最新版本，留空则接受发布页上的任意版本。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:pavl_client/core/update_install.dart';
import 'package:pavl_client/core/update_service.dart';
import 'package:pavl_client/util/app_log.dart';
import 'package:pavl_client/util/build_info.dart';

/// 默认关闭，见文件头的说明。
const bool _enabled = bool.fromEnvironment('PAVL_TEST_UPDATE');

/// 期望查到的版本号，空字符串表示不校验。
const String _expectVersion =
    String.fromEnvironment('PAVL_TEST_EXPECT', defaultValue: '');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('查最新发布并就地替换自己，不碰目录里别的 App', (tester) async {
    if (!_enabled) {
      logLine('update', '跳过更新验证：没有设置 PAVL_TEST_UPDATE=1');
      return;
    }

    logLine('update', '=== 集成测试开始，本体 ${Platform.resolvedExecutable}');

    // 一、定位。这三条断言是防回归的核心。
    final currentApp = currentAppPath();
    logLine('update', '当前 .app：$currentApp');
    expect(currentApp, isNotNull, reason: '必须能沿可执行路径找到 .app');

    final install = installRootOf();
    final launch = launcherIn(install);
    logLine('update', '安装目录 $install，启动路径 $launch');
    expect(launch, '$currentApp/Contents/MacOS/PAVL',
        reason: '启动路径必须在自己的包里，不能落到邻居身上');

    // 二、诱饵：名字排在 PAVL.app 前面，老实现会挑到它。
    final decoy = Directory('$install/AAA-not-pavl.app');
    await decoy.create(recursive: true);
    final decoyMarker = File('${decoy.path}/keep.txt');
    await decoyMarker.writeAsString('不要动我');
    logLine('update', '放下诱饵 ${decoy.path}');

    // 三、查发布。
    final service = UpdateService();
    final latest = await service.fetchLatest();
    logLine('update', '最新发布 ${latest.version}（tag ${latest.tag}）');
    if (_expectVersion.isNotEmpty) {
      expect(normalizeVersion(latest.version), _expectVersion);
    }
    expect(isNewerVersion(latest.version, current: appVersion), isTrue,
        reason: '在线版本必须比本地新，否则测的不是更新路径');

    final asset = latest.assetFor('macos');
    expect(asset, isNotNull, reason: '发布里要有 macos_client 包');
    logLine('update', '更新包 ${asset!.name}，${asset.size} 字节');

    // 四、下载。断点续传、分块拼接都在这里过一遍。
    final zip = await service.download(asset);
    final actualSize = await zip.length();
    logLine('update', '下载完成 ${zip.path}，$actualSize 字节');
    expect(actualSize, asset.size);

    // 五、替换。`beginApply` 会铺完文件再拉起新本体，本进程随即退出，
    // 所以后面两行断言是这条链路最后一次说话。
    logLine('update', '开始就地替换');
    await beginApply(zip: zip, version: normalizeVersion(latest.version));

    // 诱饵必须原样还在——被改名成 .old 或者被覆盖都算失败。
    expect(await decoyMarker.exists(), isTrue, reason: '诱饵被动了');
    expect(await File('${decoy.path}.old').exists(), isFalse,
        reason: '诱饵被改名了');
    logLine('update', '诱饵完好，交给新本体');
    await decoy.delete(recursive: true);
  });
}
