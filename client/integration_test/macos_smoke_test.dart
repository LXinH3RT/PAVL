/// macOS 端到端冒烟测试。
///
/// 在真实的 .app 进程里跑，验证的是「装到用户机器上能不能用」这条链路：
/// 配对换令牌、列目录、拉流并真正解出视频帧、上报播放进度。这些都无法用
/// 单元测试覆盖——它们依赖网络栈、libmpv 的 ffi 加载和视频解码器。
///
/// 运行前需要在同一局域网内启动一个 PAVL 服务端，并通过 `--dart-define`
/// 传入地址与 PIN：
///
///   flutter test integration_test/macos_smoke_test.dart -d macos \
///     --dart-define=PAVL_TEST_HOST=192.168.1.10 \
///     --dart-define=PAVL_TEST_PORT=8765 \
///     --dart-define=PAVL_TEST_PIN=123456
///
/// 服务端根目录里至少要有一个视频文件，否则拉流用例会跳过。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'package:pavl_client/api/discovery.dart';
import 'package:pavl_client/api/pavl_client.dart';
import 'package:pavl_client/store/app_store.dart';
import 'package:pavl_client/util/app_log.dart';
import 'package:pavl_client/util/platform_support.dart';

const String _host = String.fromEnvironment('PAVL_TEST_HOST');
const int _port = int.fromEnvironment('PAVL_TEST_PORT', defaultValue: 8765);
const String _pin =
    String.fromEnvironment('PAVL_TEST_PIN', defaultValue: '123456');
const String _mediaPath = String.fromEnvironment('PAVL_TEST_MEDIA');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // 和 main.dart 一样，libmpv 是 ffi 加载的，任何 Player 构造之前必须初始化。
  MediaKit.ensureInitialized();

  group('macOS 运行环境', () {
    testWidgets('平台标识与数据目录', (tester) async {
      if (!Platform.isMacOS) {
        markTestSkipped('只在 macOS 上跑：本组断言的是 macOS 专属的数据目录约定');
        return;
      }
      expect(platformTag, 'macos');
      expect(platformLabel, 'macOS');

      final dir = Directory(appDataDir().path);
      expect(dir.existsSync(), isTrue, reason: '数据目录应当已经建好');
      // macOS 的数据目录必须落在用户的 Library 下，而不是 .app 体内。
      expect(dir.path, contains('/Library/Application Support/PAVL'));
      expect(dir.path, isNot(contains('.app/')));
    });

    testWidgets('日志可写', (tester) async {
      logLine('test', 'macOS 冒烟测试写入一行');
      final file = File(logFile().path);
      expect(file.existsSync(), isTrue);
      expect(file.readAsStringSync(), contains('macOS 冒烟测试写入一行'));
    });
  });

  group('局域网发现', () {
    testWidgets('广播能收到应答', (tester) async {
      if (_host.isEmpty) {
        markTestSkipped('未提供 PAVL_TEST_HOST，跳过发现用例');
        return;
      }
      final session = DiscoverySession(timeout: const Duration(seconds: 5));
      addTearDown(session.dispose);
      final results = await session.run();
      expect(results, isNotEmpty, reason: '应当至少发现一台服务器');
      expect(
        results.any((s) => s.host == _host),
        isTrue,
        reason: '应当发现指定的测试服务器 $_host',
      );
    });
  });

  group('协议链路', () {
    late PavlClient client;
    late String token;

    setUpAll(() async {
      client = PavlClient(
        connection: ServerConnection(
          serverId: '',
          name: 'test',
          host: _host,
          port: _port,
        ),
      );
    });

    tearDownAll(() => client.close());

    testWidgets('info 无需鉴权', (tester) async {
      final info = await client.info();
      expect(info['api'], 1);
      expect(info['id'], isNotEmpty);
    });

    testWidgets('用 PIN 换令牌', (tester) async {
      token = await client.pair(
        pin: _pin,
        deviceId: 'macos-smoke-test',
        deviceName: 'macOS 冒烟测试',
        platform: platformTag,
      );
      expect(token, isNotEmpty);
      logLine('test', '配对成功，令牌长度 ${token.length}');
    });

    testWidgets('列出根目录', (tester) async {
      final authed = PavlClient(
        connection: client.connection.copyWith(token: token),
      );
      addTearDown(authed.close);
      final entries = await authed.browse('');
      expect(entries, isNotEmpty, reason: '服务端根目录不应为空');
      for (final entry in entries.take(5)) {
        logLine('test', '条目 ${entry.name} 目录=${entry.isDir}');
      }
    });

    testWidgets('拉流并解出首帧', (tester) async {
      final authed = PavlClient(
        connection: client.connection.copyWith(token: token),
      );
      addTearDown(authed.close);

      // 没指定就自己找：从根目录往下走一层，取第一个视频文件。硬编码路径
      // 会让用例依赖测试机的目录结构，换个根目录就红。
      final path =
          _mediaPath.isNotEmpty ? _mediaPath : await _findFirstVideo(authed);
      if (path == null) {
        markTestSkipped('服务端里没有视频文件，跳过拉流用例');
        return;
      }

      final uri = authed.streamUri(path);
      logLine('test', '拉流 ${redactUri(uri)}');

      // 直接驱动 libmpv，绕开业务界面：这里要验的是解码链路，不是布局。
      //
      // 两个必须的点：
      //   1. 必须挂 VideoController。media_kit 默认 `vid=no` 不解码视频，
      //      只有 VideoController 附加后才改成 auto；不挂声音正常、画面全黑。
      //   2. 必须把 Video 组件真正挂进树里。VideoController 在构造时注册了
      //      post-frame 回调，纹理要等第一帧才创建，光 new 一个对象不会推进。
      final player = Player();
      final controller = VideoController(player);
      addTearDown(player.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Video(controller: controller),
        ),
      );
      await tester.pump();

      await player
          .open(Media(uri.toString(), httpHeaders: authed.mediaHeaders));

      // 等首帧。硬解初始化在 Apple Silicon 上通常 300~800ms，给足 20 秒。
      // 用 pump 推进帧，让纹理回调有机会跑。
      var gotVideo = false;
      for (var i = 0; i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 200));
        final params = player.state.videoParams;
        if (params.w != null && params.w! > 0) {
          gotVideo = true;
          logLine('test', '首帧 ${params.w}x${params.h}');
          break;
        }
      }
      expect(gotVideo, isTrue, reason: '20 秒内没有解出视频帧');

      final duration = player.state.duration;
      expect(duration, greaterThan(Duration.zero), reason: '拿不到时长说明解封装失败');
      logLine('test', '时长 ${duration.inSeconds}s');

      // 播放推进：位置必须真的往前走，而不是停在 0。
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      final position = player.state.position;
      expect(position, greaterThan(Duration.zero), reason: '播放位置没有推进');
      logLine('test', '位置 ${position.inMilliseconds}ms');
    });
  });
}

/// 从根目录往下找最大的视频文件，返回它的相对路径。
///
/// 挑最大的而不是第一个：测试目录里常掺着几百字节的占位文件，它们同样带
/// `.mkv` 后缀、同样被判成视频，但 libmpv 解不出帧，会让解码用例假阴性。
/// 真实影片总是目录里最大的那个。
///
/// 走三层：测试媒体目录的结构通常是一层分类、一层影片，留一层余量；再深
/// 就该靠 `PAVL_TEST_MEDIA` 指定了。
Future<String?> _findFirstVideo(PavlClient client) async {
  final found = <BrowseEntry>[];

  Future<void> walk(String path, int depth) async {
    if (depth < 0) return;
    final entries = await client.browse(path);
    for (final entry in entries) {
      if (!entry.isDir && entry.kind == 'video') {
        found.add(entry);
      } else if (entry.isDir) {
        // 注意 await：不等待会让并发的递归与本函数的收集顺序错乱。
        await walk(entry.path, depth - 1);
      }
    }
  }

  await walk('', 3);
  if (found.isEmpty) return null;
  found.sort((a, b) => b.size.compareTo(a.size));
  return found.first.path;
}
