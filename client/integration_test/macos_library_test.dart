/// 片库页的 macOS 真机测试。
///
/// 与前两套的分工：`macos_smoke_test.dart` 验网络与解码，`macos_ui_test.dart`
/// 走「发现 → 配对 → 浏览 → 播放」，这里专测片库：跨目录拉平、按标题排序、
/// 关键词搜索、分页状态。
///
/// 运行方式同另外两套：
///
///   flutter test integration_test/macos_library_test.dart -d macos \
///     --dart-define=PAVL_TEST_HOST=192.168.1.10 \
///     --dart-define=PAVL_TEST_PORT=8765 \
///     --dart-define=PAVL_TEST_PIN=123456
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';

import 'package:pavl_client/api/pavl_client.dart';
import 'package:pavl_client/app.dart';
import 'package:pavl_client/store/app_store.dart';
import 'package:pavl_client/ui/library_screen.dart';
import 'package:pavl_client/ui/widgets/library_tile.dart';
import 'package:pavl_client/util/app_log.dart';

const String _host = String.fromEnvironment('PAVL_TEST_HOST');
const int _port = int.fromEnvironment('PAVL_TEST_PORT', defaultValue: 8765);
const String _pin =
    String.fromEnvironment('PAVL_TEST_PIN', defaultValue: '123456');

Future<String> _pairToken() async {
  final client = PavlClient(
    connection: ServerConnection(
      serverId: 'library-test',
      name: '片库测试',
      host: _host,
      port: _port,
    ),
  );
  try {
    return await client.pair(
      pin: _pin,
      deviceId: 'macos-library-test',
      deviceName: 'macOS 片库测试',
      platform: 'macos',
    );
  } finally {
    client.close();
  }
}

/// 等片库条目渲染出来。
///
/// 判定用 [LibraryTile] 而不是 `ListTile`：片库的每一行是自定义的 `InkWell`
/// 布局（图标 + 标题 + 副行），不是 Material 的 `ListTile`。首屏要等两次
/// 网络往返（分页 + 最近播放），给足 20 秒。
Future<void> _waitForTiles(WidgetTester tester) async {
  for (var i = 0; i < 100; i++) {
    await tester.pump(const Duration(milliseconds: 200));
    if (find.byType(LibraryTile).evaluate().isNotEmpty) return;
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  testWidgets('片库能列出全部条目并按标题排好序', (tester) async {
    if (_host.isEmpty) {
      markTestSkipped('未提供 PAVL_TEST_HOST');
      return;
    }
    final store = await AppStore.load();
    final connection = ServerConnection(
      serverId: 'library-test',
      name: '片库测试',
      host: _host,
      port: _port,
      token: await _pairToken(),
    );
    final client = PavlClient(connection: connection);
    addTearDown(client.close);

    // 先拿接口侧的顺序，用来和界面渲染的顺序对照。界面若自己又排了一遍，
    // 两边就会不一致——这正是这轮改动要消除的。
    final page = await client.library(page: 1, pageSize: libraryPageSize);
    expect(
      page.items,
      isNotEmpty,
      reason: '服务端片库为空，测试数据没准备好',
    );
    logLine('test', '接口片库 ${page.items.length} 条，共 ${page.total} 部');

    await tester.pumpWidget(
      MaterialApp(
        theme: buildPavlTheme(),
        home: LibraryScreen(store: store, client: client),
      ),
    );
    await _waitForTiles(tester);

    expect(
      find.byType(LibraryTile).evaluate(),
      isNotEmpty,
      reason: '20 秒内片库列表没有渲染出来',
    );

    // 界面上的标题应当按接口返回的顺序出现。取前三条比对，全量比对会因为
    // 列表懒加载而拿不到屏幕外的项。
    final expected = page.items.take(3).map((e) => e.displayTitle).toList();
    final rendered = <String>[];
    for (final text in tester.widgetList<Text>(find.byType(Text))) {
      final data = text.data;
      if (data != null && expected.contains(data)) rendered.add(data);
    }
    logLine('test', '界面首屏顺序 ${rendered.join(" | ")}');
    expect(
      rendered.take(expected.length).toList(),
      expected,
      reason: '界面顺序与接口不一致，说明客户端又排了一遍',
    );
  });

  testWidgets('搜索会按关键词收窄结果', (tester) async {
    if (_host.isEmpty) {
      markTestSkipped('未提供 PAVL_TEST_HOST');
      return;
    }
    final store = await AppStore.load();
    final connection = ServerConnection(
      serverId: 'library-test',
      name: '片库测试',
      host: _host,
      port: _port,
      token: await _pairToken(),
    );
    final client = PavlClient(connection: connection);
    addTearDown(client.close);

    // 用第一条的标题首字作关键词，保证一定能命中，又不至于把所有条目都筛出来。
    final all = await client.library(page: 1, pageSize: libraryPageSize);
    if (all.items.isEmpty) {
      markTestSkipped('服务端片库为空，测试数据没准备好');
      return;
    }
    final sample = all.items.first.displayTitle;
    final needle = sample.substring(0, sample.length >= 2 ? 2 : 1);
    final expected = await client.library(
      page: 1,
      pageSize: libraryPageSize,
      query: needle,
    );
    logLine('test', '关键词「$needle」命中 ${expected.total} 部');

    await tester.pumpWidget(
      MaterialApp(
        theme: buildPavlTheme(),
        home: LibraryScreen(store: store, client: client),
      ),
    );
    await _waitForTiles(tester);

    await tester.enterText(find.byType(TextField), needle);
    // 搜索框有 200ms 防抖，之后还要一次网络往返。
    await tester.pump(const Duration(milliseconds: 300));
    await _waitForTiles(tester);

    expect(
      expected.total,
      lessThan(all.total),
      reason: '关键词没有起到收窄作用，全量 ${all.total} 部、搜索结果也是 ${expected.total} 部',
    );

    // 界面上每一项都应当命中关键词。判断依据是渲染出来的条目，而不是列表
    // 长度：`ListView.builder` 只构建视口内的行，长度随窗口大小变。
    //
    // 命中范围是「标题或相对路径」，两者都要查：服务端把 `Avatar.2009.mkv`
    // 的标题解析成 `Avatar`，路径里却仍有 `2009`，搜 `20` 时它确实是命中项。
    final entries =
        tester.widgetList<LibraryTile>(find.byType(LibraryTile)).map((t) => t.entry).toList();
    logLine('test',
        '搜索「$needle」后界面显示 ${entries.length} 行：${entries.map((e) => e.displayTitle).join(" | ")}');
    expect(entries, isNotEmpty, reason: '搜索后列表不该是空的');
    final lowered = needle.toLowerCase();
    for (final entry in entries) {
      final hit = entry.displayTitle.toLowerCase().contains(lowered) ||
          entry.path.toLowerCase().contains(lowered);
      expect(
        hit,
        isTrue,
        reason: '「${entry.path}」的标题与路径都不含「$needle」，说明过滤没生效',
      );
    }
  });

  testWidgets('空关键词与清空按钮能回到全量', (tester) async {
    if (_host.isEmpty) {
      markTestSkipped('未提供 PAVL_TEST_HOST');
      return;
    }
    final store = await AppStore.load();
    final connection = ServerConnection(
      serverId: 'library-test',
      name: '片库测试',
      host: _host,
      port: _port,
      token: await _pairToken(),
    );
    final client = PavlClient(connection: connection);
    addTearDown(client.close);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildPavlTheme(),
        home: LibraryScreen(store: store, client: client),
      ),
    );
    await _waitForTiles(tester);

    // 输入一段肯定搜不到的文字，确认空态文案出现。
    await tester.enterText(find.byType(TextField), 'zznomatchzz');
    await tester.pump(const Duration(milliseconds: 300));
    await _waitForTiles(tester);
    expect(
      find.textContaining('没有匹配'),
      findsWidgets,
      reason: '搜不到时应当给出空态提示',
    );

    // 点清除按钮回到全量。
    final clear = find.byIcon(Icons.close);
    expect(clear.evaluate(), isNotEmpty, reason: '有搜索词时应当有清除按钮');
    await tester.tap(clear.first);
    await tester.pump(const Duration(milliseconds: 300));
    await _waitForTiles(tester);

    // 断言「回到全量」看两件事：空态消失、列表重新有内容。
    // 不去找底部的「共 N 部」——13 条列表超出视口，`ListView.builder` 不会
    // 构建屏幕外的状态行，那是个看不见的断言。
    expect(
      find.textContaining('没有匹配'),
      findsNothing,
      reason: '清空关键词后不该还是空态',
    );
    expect(
      find.byType(LibraryTile).evaluate(),
      isNotEmpty,
      reason: '清空关键词后列表应当重新有内容',
    );
  });
}
