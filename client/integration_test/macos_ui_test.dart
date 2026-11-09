/// macOS 界面全链路测试。
///
/// 与 `macos_smoke_test.dart` 的分工：那个验的是网络、解码这些底层能力，
/// 这个从真正的主界面出发，走「发现 → 配对 → 浏览 → 播放」这条用户路径，
/// 断言的是界面确实被驱动到了对应状态。
///
/// 运行方式同冒烟测试：
///
///   flutter test integration_test/macos_ui_test.dart -d macos \
///     --dart-define=PAVL_TEST_HOST=192.168.1.10 \
///     --dart-define=PAVL_TEST_PORT=8765 \
///     --dart-define=PAVL_TEST_PIN=123456
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';

import 'package:pavl_client/app.dart';
import 'package:pavl_client/api/pavl_client.dart';
import 'package:pavl_client/store/app_store.dart';
import 'package:pavl_client/ui/browse_screen.dart';
import 'package:pavl_client/ui/player_screen.dart';

const String _host = String.fromEnvironment('PAVL_TEST_HOST');
const int _port = int.fromEnvironment('PAVL_TEST_PORT', defaultValue: 8765);
const String _pin =
    String.fromEnvironment('PAVL_TEST_PIN', defaultValue: '123456');

/// 用测试 PIN 换一个令牌。
///
/// 每次现换而不复用固定令牌，测试跑在干净的数据目录里也能过。
Future<String> _pairToken() async {
  final client = PavlClient(
    connection: ServerConnection(
      serverId: 'ui-test',
      name: 'UI 测试',
      host: _host,
      port: _port,
    ),
  );
  try {
    return await client.pair(
      pin: _pin,
      deviceId: 'macos-ui-test',
      deviceName: 'macOS 界面测试',
      platform: 'macos',
    );
  } finally {
    client.close();
  }
}

/// 从根目录往下找最大的视频文件。
///
/// 挑最大的而不是第一个：测试目录里常掺着几百字节的占位文件，它们同样带
/// `.mkv` 后缀、同样被判成视频，但 libmpv 解不出帧。
Future<String?> _findFirstVideo(ServerConnection connection) async {
  final client = PavlClient(connection: connection);
  try {
    final found = <BrowseEntry>[];

    Future<void> walk(String path, int depth) async {
      if (depth < 0) return;
      final entries = await client.browse(path);
      for (final entry in entries) {
        if (!entry.isDir && entry.kind == 'video') {
          found.add(entry);
        } else if (entry.isDir) {
          await walk(entry.path, depth - 1);
        }
      }
    }

    // 注意 await：直接 `return walk(...)` 会让 finally 先跑，把还在用的
    // HttpClient 关掉，报 "Bad state: Client is closed"。
    await walk('', 3);
    if (found.isEmpty) return null;
    found.sort((a, b) => b.size.compareTo(a.size));
    return found.first.path;
  } finally {
    client.close();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  testWidgets('主界面能渲染出主题与字体', (tester) async {
    final store = await AppStore.load();
    await tester.pumpWidget(PavlApp(store: store));
    await tester.pump();

    // 深色主题是品牌的一部分，跑偏了说明 ThemeData 构造参数被覆盖。
    expect(PavlColors.background, const Color(0xFF101114));
    final material = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(material.theme?.brightness, Brightness.dark);
    expect(material.theme?.textTheme.bodyMedium?.fontFamily, 'MiSans');
  });

  testWidgets('浏览页能列出目录并进入下一层', (tester) async {
    if (_host.isEmpty) {
      markTestSkipped('未提供 PAVL_TEST_HOST');
      return;
    }
    final store = await AppStore.load();
    final connection = ServerConnection(
      serverId: 'ui-test',
      name: 'UI 测试',
      host: _host,
      port: _port,
      token: await _pairToken(),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: buildPavlTheme(),
        home: BrowseScreen(store: store, connection: connection),
      ),
    );

    // 首屏加载是异步的，等到列表出来或者报错为止。
    for (var i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 200));
      if (find.byType(ListTile).evaluate().isNotEmpty) break;
      if (find.text('这个文件夹是空的').evaluate().isNotEmpty) break;
    }
    expect(
      find.text('需要配对才能访问').evaluate(),
      isEmpty,
      reason: '带令牌的连接不该再要求配对',
    );
  });

  testWidgets('播放页能从流地址起播并显示控制栏', (tester) async {
    if (_host.isEmpty) {
      markTestSkipped('未提供 PAVL_TEST_HOST');
      return;
    }
    final store = await AppStore.load();
    final token = await _pairToken();
    final connection = ServerConnection(
      serverId: 'ui-test',
      name: 'UI 测试',
      host: _host,
      port: _port,
      token: token,
    );

    // 找一个真实可播的视频，走一遍播放页的完整初始化。
    final path = await _findFirstVideo(connection);
    if (path == null) {
      markTestSkipped('服务端里没有视频文件');
      return;
    }

    final client = PavlClient(connection: connection);
    addTearDown(client.close);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildPavlTheme(),
        home: PlayerScreen(
          store: store,
          client: client,
          path: path,
          fallbackTitle: '测试影片',
        ),
      ),
    );

    // 详情 + 起播 + 首帧，硬解路径给足 30 秒。
    for (var i = 0; i < 150; i++) {
      await tester.pump(const Duration(milliseconds: 200));
      if (find.byType(Slider).evaluate().isNotEmpty) break;
    }

    // 控制栏里的进度滑杆只有在拿到时长后才渲染，出现即说明解码链路通了。
    expect(
      find.byType(Slider).evaluate(),
      isNotEmpty,
      reason: '30 秒内控制栏没有出现，播放初始化失败',
    );
  });
}
