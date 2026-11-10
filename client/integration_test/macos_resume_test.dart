/// macOS 续播起点测试：验证「继续播放」真的从断点开始，而不是从头播。
///
/// 这条路径曾经坏过：`Player.open()` 返回时 libmpv 只是收下了 `loadlist`
/// 命令，文件还没解封装，紧接着发 `seek` 会失败，而 media_kit 只把它写进
/// 日志、不抛异常。表现就是 macOS 上点了「继续播放」依然从 0:00 开始。
///
/// 现在起点走 `Media(start:)`，由 libmpv 在文件加载完成的 hook 里自己跳；
/// 这个测试把它钉住——位置应当落在指定起点附近，而不是 0。
///
///   flutter test integration_test/macos_resume_test.dart -d macos \
///     --dart-define=PAVL_TEST_HOST=192.168.1.10 \
///     --dart-define=PAVL_TEST_PORT=8765 \
///     --dart-define=PAVL_TEST_PIN=123456
///
/// 服务端根目录里至少要有一个视频。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'package:pavl_client/api/pavl_client.dart';
import 'package:pavl_client/player/playback_controller.dart';
import 'package:pavl_client/store/app_store.dart';
import 'package:pavl_client/util/app_log.dart';

const String _host = String.fromEnvironment('PAVL_TEST_HOST');
const int _port = int.fromEnvironment('PAVL_TEST_PORT', defaultValue: 8799);
const String _pin =
    String.fromEnvironment('PAVL_TEST_PIN', defaultValue: '298730');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  late PavlClient client;
  late AppStore store;
  String? videoPath;

  setUpAll(() async {
    if (_host.isEmpty) return;
    store = await AppStore.load();
    final anonymous = PavlClient(
      connection: ServerConnection(
        serverId: '',
        name: 'macos-resume-test',
        host: _host,
        port: _port,
      ),
    );
    final token = await anonymous.pair(
      pin: _pin,
      deviceId: 'macos-resume-test',
      deviceName: 'macOS 续播测试',
      platform: 'macos',
    );
    anonymous.close();
    client = PavlClient(
      connection: ServerConnection(
        serverId: 'macos-resume-test',
        name: 'macos-resume-test',
        host: _host,
        port: _port,
        token: token,
      ),
    );
    final page = await client.library(page: 1, pageSize: 5);
    videoPath = page.items.isEmpty ? null : page.items.first.path;
  });

  tearDownAll(() => client.close());

  testWidgets('open(startAt:) 会把播放位置放到指定处', (tester) async {
    if (_host.isEmpty || videoPath == null) {
      markTestSkipped('没有服务端或没有视频');
      return;
    }
    final detail = await client.media(videoPath!);
    final controller = PlaybackController(
      client: client,
      store: store,
      mediaDetail: detail,
    );
    await tester.pumpWidget(
      MaterialApp(home: Video(controller: controller.videoController)),
    );
    await tester.pump();

    const startAt = Duration(minutes: 30);
    await controller.open(startAt: startAt);

    var position = Duration.zero;
    for (var i = 0; i < 100; i++) {
      await tester.pump(const Duration(milliseconds: 200));
      position = controller.position;
      if (position > Duration.zero) break;
    }
    logLine(
      'test',
      '起点 $startAt，实际位置 $position，时长 ${controller.duration}',
    );
    expect(
      position.inSeconds,
      greaterThan(1790),
      reason: '位置应当在 30 分钟附近，而不是 0',
    );
    await controller.dispose();
    await tester.pump();
  });
}
