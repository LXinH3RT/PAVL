/// 主页：服务器连接状态 + 浏览入口。
///
/// 启动流程分三种情况：
///   1. 有缓存服务器 → 直接探测，通则立刻进入浏览
///   2. 缓存失效 → 自动广播一次，边收边展示
///   3. 都失败 → 引导手动输入 IP 或重试
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

enum _Phase { probing, discovering, ready, failed }

class _HomeScreenState extends State<HomeScreen> {
  _Phase _phase = _Phase.probing;
  String _statusText = '正在连接上次使用的服务器…';
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

  /// 启动流程：先试缓存地址，再广播。
  Future<void> _bootstrap() async {
    final last = widget.store.lastServer;
    if (last != null) {
      final probed = await probeHost(last.host, last.port);
      if (probed != null && mounted) {
        await _enterServer(probed);
        return;
      }
    }
    if (mounted) await _startDiscovery();
  }

  Future<void> _startDiscovery() async {
    _session?.dispose();
    setState(() {
      _phase = _Phase.discovering;
      _found.clear();
      _statusText = '正在局域网内搜索 PAVL 服务器…';
    });

    final session = DiscoverySession();
    _session = session;
    final results = await session.run(onFound: (server) {
      if (!mounted) return;
      setState(() {
        _found.add(server);
        _statusText = '发现 ${_found.length} 台服务器';
      });
    });

    if (!mounted) return;
    setState(() {
      if (results.isEmpty) {
        _phase = _Phase.failed;
        _statusText = '没有找到 PAVL 服务器';
      } else if (results.length == 1) {
        _phase = _Phase.ready;
        _statusText = '找到 ${results.first.name}';
      } else {
        _phase = _Phase.ready;
        _statusText = '找到 ${results.length} 台服务器，请选择';
      }
    });

    // 只有一台就自动进入。
    if (results.length == 1) {
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
    } else if (connection.host != server.host || connection.port != server.port) {
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
            phase: _phase.name,
            statusText: _statusText,
            servers: _found,
            savedServers: widget.store.servers,
            deviceId: widget.store.deviceId,
            deviceName: widget.store.deviceName,
            onDiscover: _startDiscovery,
            onConnected: _enterConnection,
            onPickSaved: _enterConnection,
            onForget: (serverId) async {
              await widget.store.removeServer(serverId);
              if (mounted) setState(() {});
            },
          ),
        ),
      ),
    );
  }
}
