/// 主页：启动探测 + 连接面板。
///
/// 启动流程只有两步：
///   1. 有上次用的服务器 → 直接探活，通则立刻进浏览页
///   2. 探不通或没有记录 → 后台广播一轮，把结果填进面板；只有一台且已配对
///      时直接进去，多台就交给用户点
///
/// 界面上不出现「正在搜索」「找到 N 台」这类过程文案：局域网搜索是后台自己
/// 做的事，用户只需要看见能点的服务器和输入框。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../api/discovery.dart';
import '../api/pavl_client.dart';
import '../store/app_store.dart';
import 'browse_screen.dart';
import 'connect_panel.dart';

/// 主页。
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.store});

  final AppStore store;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final List<DiscoveredServer> _found = [];
  DiscoverySession? _session;

  @override
  void initState() {
    super.initState();
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    _session?.dispose();
    super.dispose();
  }

  /// 先试上次的地址，再静默广播。
  Future<void> _bootstrap() async {
    final last = widget.store.lastServer;
    if (last != null) {
      final probed = await probeHost(last.host, last.port);
      if (probed != null && mounted) {
        // 有令牌就一步到位，没有就让用户在面板里补 PIN。
        if (last.hasToken) {
          await _enterConnection(last);
          return;
        }
        await _enterServer(probed);
        return;
      }
    }
    if (mounted) await _startDiscovery();
  }

  Future<void> _startDiscovery() async {
    _session?.dispose();
    final session = DiscoverySession();
    _session = session;
    final results = await session.run(onFound: (server) {
      if (!mounted) return;
      setState(() => _found.add(server));
    });
    if (!mounted) return;

    // 只发现一台且已经配对过，就不必让用户再点一次。
    if (results.length == 1 && widget.store.serverById(results.first.serverId)?.hasToken == true) {
      await _enterServer(results.first);
    }
  }

  /// 已经拿到带令牌的连接，直接进浏览页。
  Future<void> _enterConnection(ServerConnection connection) async {
    await widget.store.upsertServer(connection);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BrowseScreen(
          store: widget.store,
          connection: connection,
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  /// 拿到服务器后进入浏览页；未配对先走配对。
  Future<void> _enterServer(DiscoveredServer server) async {
    var connection = widget.store.serverById(server.serverId);
    if (connection == null) {
      connection = ServerConnection(
        serverId: server.serverId,
        name: server.name,
        host: server.host,
        port: server.port,
      );
      await widget.store.upsertServer(connection);
    } else if (connection.host != server.host ||
        connection.port != server.port) {
      // 服务器换了 IP（DHCP 续租常见），更新地址但保留令牌。
      connection = connection.copyWith(host: server.host, port: server.port);
      await widget.store.upsertServer(connection);
    }

    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BrowseScreen(
          store: widget.store,
          connection: connection!,
        ),
      ),
    );
    // 从浏览页返回后刷新一次状态，对应用户可能改了配对。
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ConnectPanel(
            servers: _found,
            savedServers: widget.store.servers,
            deviceId: widget.store.deviceId,
            deviceName: widget.store.deviceName,
            onConnected: _enterConnection,
            onPickSaved: _enterConnection,
          ),
        ),
      ),
    );
  }
}
