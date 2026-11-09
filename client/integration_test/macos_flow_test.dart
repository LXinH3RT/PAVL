/// macOS 业务链路测试：播放、进度、字幕、媒体信息回写。
///
/// 与 `macos_smoke_test.dart` 的分工：那个验的是「零件能不能用」（libmpv 能
/// 不能解码、网络能不能通），这个验的是「装配起来对不对」——把真实的
/// [PlaybackController] 拉起来播放，检查它有没有按设计上报进度、回写媒体
/// 信息、挂上外挂字幕。这些逻辑都在客户端里，出错只会表现为「进度没同步」
/// 或「字幕不显示」，单元测试碰不到。
///
///   flutter test integration_test/macos_flow_test.dart -d macos \
///     --dart-define=PAVL_TEST_HOST=192.168.1.10 \
///     --dart-define=PAVL_TEST_PORT=8765 \
///     --dart-define=PAVL_TEST_PIN=123456
///
/// 服务端根目录里至少要有一个带外挂字幕的视频。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'package:pavl_client/api/pavl_client.dart';
import 'package:pavl_client/player/playback_controller.dart';
import 'package:pavl_client/store/app_store.dart';
import 'package:pavl_client/util/app_log.dart';
import 'package:pavl_client/util/platform_support.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

const String _host = String.fromEnvironment('PAVL_TEST_HOST');
const int _port = int.fromEnvironment('PAVL_TEST_PORT', defaultValue: 8765);
const String _pin =
    String.fromEnvironment('PAVL_TEST_PIN', defaultValue: '123456');

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
        name: 'flow-test',
        host: _host,
        port: _port,
      ),
    );
    final token = await anonymous.pair(
      pin: _pin,
      deviceId: 'macos-flow-test',
      deviceName: 'macOS 链路测试',
      platform: platformTag,
    );
    anonymous.close();

    client = PavlClient(
      connection: ServerConnection(
        serverId: 'flow-test',
        name: 'macOS 链路测试',
        host: _host,
        port: _port,
        token: token,
      ),
    );
    videoPath = await _findFirstVideo(client);
  });

  tearDownAll(() => client.close());

  testWidgets('外挂字幕能下载并解析', (tester) async {
    if (_host.isEmpty) {
      markTestSkipped('未提供 PAVL_TEST_HOST');
      return;
    }
    if (videoPath == null) {
      markTestSkipped('服务端里没有视频文件');
      return;
    }

    final detail = await client.media(videoPath!);
    logLine('test', '影片 ${detail.path} 外挂字幕 ${detail.subtitles.length} 条');
    if (detail.subtitles.isEmpty) {
      markTestSkipped('这个视频没有外挂字幕');
      return;
    }

    // 走客户端真正用的那条地址（令牌在查询参数里，libmpv 带不了请求头）。
    final subtitle = detail.subtitles.first;
    final uri = client.subtitleUri(subtitle.path);
    final request = await HttpClient().getUrl(uri);
    final response = await request.close();
    expect(response.statusCode, 200, reason: '字幕应当可以直接下载');

    final body =
        await response.transform(const SystemEncoding().decoder).join();
    expect(body.trim(), isNotEmpty);
    logLine('test', '字幕 ${subtitle.name} 长度 ${body.length}');
  });

  testWidgets('播放会推进位置并在结束时回写进度', (tester) async {
    if (_host.isEmpty) {
      markTestSkipped('未提供 PAVL_TEST_HOST');
      return;
    }
    if (videoPath == null) {
      markTestSkipped('服务端里没有视频文件');
      return;
    }

    final detail = await client.media(videoPath!);

    // 先把服务端上这部片的进度清掉，否则读到的是上一次测试留下的值，
    // 断言「进度被写进去了」就失去了意义。
    await client.putProgress(
      path: detail.path,
      position: 0,
      duration: 0,
      finished: false,
    );

    // 真机验证要用真实的控制器，它才包含节流、终态保护这些逻辑。
    final controller = PlaybackController(
      client: client,
      store: store,
      mediaDetail: detail,
    );
    addTearDown(controller.dispose);

    // VideoController 要挂进树里才会创建纹理，否则 media_kit 保持 vid=no
    // 不解码视频，位置也不会推进。
    await tester.pumpWidget(
      MaterialApp(
        home: Video(controller: controller.videoController),
      ),
    );
    await tester.pump();

    await controller.open();

    var position = Duration.zero;
    for (var i = 0; i < 75; i++) {
      await tester.pump(const Duration(milliseconds: 200));
      position = controller.position;
      if (position > const Duration(seconds: 2)) break;
    }
    expect(position, greaterThan(Duration.zero), reason: '播放位置没有推进');
    logLine('test', '播放到 ${position.inMilliseconds}ms');

    // 拉到接近片尾再等播放结束，这样能走到「看完」的上报分支。
    final total = controller.duration;
    expect(total, greaterThan(Duration.zero), reason: '拿不到时长');
    await controller.seek(total - const Duration(milliseconds: 600));

    var finished = false;
    for (var i = 0; i < 100; i++) {
      await tester.pump(const Duration(milliseconds: 200));
      if (controller.player.state.completed) {
        finished = true;
        break;
      }
    }
    logLine('test', '播放结束=$finished，控制器位置 ${controller.position}');

    // dispose 会强制上报一次进度，这是退出播放页时的真实路径。
    await controller.dispose();
    await tester.pump();

    final record = await client.getProgress(detail.path);
    expect(record, isNotNull, reason: '服务端应当收到进度记录');
    logLine(
      'test',
      '进度 ${record!.position.toStringAsFixed(1)}/'
          '${record.duration.toStringAsFixed(1)} 看完=${record.finished}',
    );
    expect(record.position, greaterThan(0), reason: '位置应当大于 0');
    expect(record.duration, greaterThan(0), reason: '应当带上总时长');
    if (finished) {
      expect(
        record.finished,
        isTrue,
        reason: '播到结尾后应当标记为看完',
      );
    }

    // 媒体信息由客户端解码后回写，服务端自己不看文件内容。
    final after = await client.media(detail.path);
    final meta = after.meta;
    expect(meta, isNotNull, reason: '播放后应当回写了媒体信息');
    logLine('test', '媒体信息 $meta');
    // 只要求「是真实分辨率」，不锁死具体尺寸：换个测试片源不该红。
    expect((meta!['width'] as num?)?.toInt() ?? 0, greaterThan(0));
    expect((meta['height'] as num?)?.toInt() ?? 0, greaterThan(0));
  });

  testWidgets('播放记录会进入最近列表', (tester) async {
    if (_host.isEmpty) {
      markTestSkipped('未提供 PAVL_TEST_HOST');
      return;
    }
    final items = await client.recent(limit: 10);
    logLine('test', '最近 ${items.length} 条');
    expect(items, isNotEmpty, reason: '刚写过进度，最近列表里应当有记录');
  });

  testWidgets('播放期间持有屏幕唤醒锁，暂停与退出时释放', (tester) async {
    if (_host.isEmpty) {
      markTestSkipped('未提供 PAVL_TEST_HOST');
      return;
    }
    if (videoPath == null) {
      markTestSkipped('服务端里没有视频文件');
      return;
    }

    final detail = await client.media(videoPath!);
    final controller = PlaybackController(
      client: client,
      store: store,
      mediaDetail: detail,
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: Video(controller: controller.videoController)),
    );
    await tester.pump();
    await controller.open();

    // 断言读的是插件自己的状态，而不是播放控制器里的标志位。
    //
    // macOS 侧的插件是把 IOPMAssertionCreateWithName 的返回值当成功标志的
    // （见 WakelockPlusMacosPlugin.swift 的 enableWakelock），系统拒绝申请
    // 时这个值会一直是 false。只查控制器字段等于自己证明自己。
    var lockedWhilePlaying = false;
    for (var i = 0; i < 75; i++) {
      await tester.pump(const Duration(milliseconds: 200));
      if (await WakelockPlus.enabled) {
        lockedWhilePlaying = true;
        break;
      }
    }
    logLine('test', '播放中唤醒锁=$lockedWhilePlaying');
    expect(lockedWhilePlaying, isTrue, reason: '播放期间应当持有屏幕唤醒锁');

    await controller.pause();
    var releasedOnPause = false;
    for (var i = 0; i < 25; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (!await WakelockPlus.enabled) {
        releasedOnPause = true;
        break;
      }
    }
    logLine('test', '暂停后释放=$releasedOnPause');
    expect(releasedOnPause, isTrue, reason: '暂停后应当释放屏幕唤醒锁');

    // 暂停后继续播，锁要能重新拿到。播完再拖回来看是最常见的用法，
    // 如果释放时把内部状态写死，这一步就会失败。
    await controller.play();
    var relocked = false;
    for (var i = 0; i < 25; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (await WakelockPlus.enabled) {
        relocked = true;
        break;
      }
    }
    logLine('test', '恢复后重新持有=$relocked');
    expect(relocked, isTrue, reason: '继续播放后应当重新持有唤醒锁');

    await controller.dispose();
    await tester.pump();

    // 退出播放页必须放锁，否则用户关掉窗口去睡觉，机器会整夜不熄屏。
    var releasedOnDispose = false;
    for (var i = 0; i < 25; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (!await WakelockPlus.enabled) {
        releasedOnDispose = true;
        break;
      }
    }
    logLine('test', '退出后释放=$releasedOnDispose');
    expect(releasedOnDispose, isTrue, reason: '退出播放页后应当释放屏幕唤醒锁');
  });
}

/// 找第一个视频文件，优先挑带外挂字幕的那个。
Future<String?> _findFirstVideo(PavlClient client) async {
  Future<List<BrowseEntry>> walk(String path, int depth) async {
    if (depth < 0) return const [];
    final entries = await client.browse(path);
    final videos = [
      for (final entry in entries)
        if (!entry.isDir && entry.kind == 'video') entry,
    ];
    if (videos.isNotEmpty) return videos;
    for (final entry in entries) {
      if (!entry.isDir) continue;
      final found = await walk(entry.path, depth - 1);
      if (found.isNotEmpty) return found;
    }
    return const [];
  }

  final videos = await walk('', 3);
  if (videos.isEmpty) return null;

  // 有字幕的优先，字幕用例才能跑起来；同组里挑最大的，避开占位文件。
  final withSubtitle = videos.where((e) => e.subtitles.isNotEmpty).toList();
  final pool = withSubtitle.isNotEmpty ? withSubtitle : videos;
  pool.sort((a, b) => b.size.compareTo(a.size));
  return pool.first.path;
}
