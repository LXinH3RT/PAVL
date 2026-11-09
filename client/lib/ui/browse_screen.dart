/// 浏览页：目录树导航 + 视频列表 + 配对入口。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../api/pavl_client.dart';
import '../app.dart';
import '../store/app_store.dart';
import '../util/app_log.dart';
import '../util/natural_sort.dart';
import 'pair_dialog.dart';
import 'player_screen.dart';
import 'settings_dialog.dart';
import 'widgets/entry_tile.dart';

/// 浏览页。
class BrowseScreen extends StatefulWidget {
  const BrowseScreen({
    super.key,
    required this.store,
    required this.connection,
  });

  final AppStore store;
  final ServerConnection connection;

  @override
  State<BrowseScreen> createState() => _BrowseScreenState();
}

class _BrowseScreenState extends State<BrowseScreen> {
  late PavlClient _client;
  late ServerConnection _connection;

  /// 当前目录路径，空串表示根。
  String _currentPath = '';
  List<BrowseEntry> _entries = const [];
  bool _loading = true;
  String? _error;
  String? _errorCode;

  /// 面包屑导航栈。
  final List<({String path, String name})> _crumbs = [];

  @override
  void initState() {
    super.initState();
    _connection = widget.connection;
    _client = PavlClient(connection: _connection);
    unawaited(_load(''));
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }

  /// 载入某个目录的列表。
  ///
  /// [rescan] 为真时先让服务端作废目录缓存再重扫一遍，用于工具栏的刷新
  /// 按钮。日常的进出目录不重扫：服务端的探测缓存本来就有时效，每次点开
  /// 一个文件夹都全库扫描会把交互拖慢。
  Future<void> _load(String path, {bool rescan = false}) async {
    setState(() {
      _loading = true;
      _error = null;
      _errorCode = null;
    });
    try {
      if (rescan) {
        final count = await _client.refresh();
        logLine('browse', '已让服务端重扫，共 $count 部');
      }
      final entries = await _client.browse(path);
      if (!mounted) return;
      setState(() {
        _entries = _sortEntries(entries);
        _currentPath = path;
        _loading = false;
      });
      _syncCrumbs(path);
    } on PavlApiError catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.message;
        _errorCode = error.code;
      });
    } on PavlNetworkError catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.message;
      });
    }
  }

  /// 目录在前，内部再按自然序排。服务端已排序，这里再做一次是为了
  /// 应对「目录和文件混排」的情况，保证视觉上分组清晰。
  List<BrowseEntry> _sortEntries(List<BrowseEntry> entries) {
    final list = [...entries];
    list.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return naturalCompare(a.name, b.name);
    });
    return list;
  }

  void _syncCrumbs(String path) {
    _crumbs.clear();
    if (path.isEmpty) return;
    final parts = path.split('/');
    var acc = '';
    for (final part in parts) {
      acc = acc.isEmpty ? part : '$acc/$part';
      _crumbs.add((path: acc, name: part));
    }
  }

  /// 配对流程。
  Future<void> _pair() async {
    final result = await showDialog<String>(
      context: context,
      builder: (_) => PairDialog(
        client: _client,
        serverName: _connection.name,
        deviceId: widget.store.deviceId,
        deviceName: widget.store.deviceName,
      ),
    );
    if (result == null || !mounted) return;

    _connection = _connection.copyWith(token: result);
    await widget.store.upsertServer(_connection);
    _client.close();
    _client = PavlClient(connection: _connection);
    await _load(_currentPath);
  }

  /// 打开设置面板：进度模式与服务器信息。
  Future<void> _showSettings() async {
    await showDialog<void>(
      context: context,
      builder: (_) => SettingsDialog(store: widget.store, connection: _connection),
    );
    if (!mounted) return;
    setState(() {});
  }

  /// 打开一个视频。
  Future<void> _openVideo(BrowseEntry entry) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerScreen(
          store: widget.store,
          client: _client,
          path: entry.path,
          fallbackTitle: entry.name,
        ),
      ),
    );
    // 回到列表后刷新进度显示。
    if (mounted) await _load(_currentPath);
  }

  void _onTap(BrowseEntry entry) {
    if (entry.isDir) {
      unawaited(_load(entry.path));
      return;
    }
    if (entry.kind == 'video') {
      unawaited(_openVideo(entry));
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('暂不支持播放 ${entry.kind} 类型')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _titleRow(),
        backgroundColor: PavlColors.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        leading: _currentPath.isEmpty
            ? null
            : IconButton(
                icon: const Icon(Icons.arrow_back),
                tooltip: '上一级',
                onPressed: () {
                  final parent = _currentPath.contains('/')
                      ? _currentPath.substring(0, _currentPath.lastIndexOf('/'))
                      : '';
                  unawaited(_load(parent));
                },
              ),
        actions: [
          if (!_connection.paired)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton.tonalIcon(
                onPressed: _pair,
                icon: const Icon(Icons.key, size: 16),
                label: const Text('配对'),
              ),
            ),
          IconButton(
            tooltip: '设置',
            onPressed: _showSettings,
            icon: const Icon(Icons.settings_outlined),
          ),
          IconButton(
            tooltip: '刷新',
            onPressed: _loading ? null : () => _load(_currentPath, rescan: true),
            icon: const Icon(Icons.refresh),
          ),
          const SizedBox(width: 4),
        ],
        bottom: _crumbs.isEmpty
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(36),
                child: _breadcrumbBar(),
              ),
      ),
      body: _body(),
    );
  }

  Widget _titleRow() {
    return Row(
      children: [
        const Icon(Icons.dns_outlined, size: 18, color: PavlColors.textDim),
        const SizedBox(width: 8),
        Text(_connection.name, style: const TextStyle(fontSize: 16)),
      ],
    );
  }

  Widget _breadcrumbBar() {
    return Container(
      height: 36,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _crumbChip('根目录', '', isFirst: true),
            for (final crumb in _crumbs) ...[
              const Icon(Icons.chevron_right, size: 14, color: PavlColors.textDim),
              _crumbChip(crumb.name, crumb.path),
            ],
          ],
        ),
      ),
    );
  }

  Widget _crumbChip(String label, String path, {bool isFirst = false}) {
    final isCurrent = path == _currentPath;
    return InkWell(
      onTap: isCurrent ? null : () => _load(path),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: isCurrent ? PavlColors.text : PavlColors.textDim,
            fontWeight: isCurrent ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_errorCode == 'unauthorized' || _errorCode == 'invalid_token') {
      return _unauthorizedView();
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 40, color: PavlColors.textDim),
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: PavlColors.textDim)),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: () => _load(_currentPath),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    if (_entries.isEmpty) {
      return const Center(
        child: Text('这个文件夹是空的', style: TextStyle(color: PavlColors.textDim)),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: _entries.length,
      itemBuilder: (_, index) {
        final entry = _entries[index];
        return EntryTile(
          entry: entry,
          onTap: () => _onTap(entry),
        );
      },
    );
  }

  Widget _unauthorizedView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.lock_outline, size: 40, color: PavlColors.textDim),
          const SizedBox(height: 12),
          const Text('需要配对才能访问', style: TextStyle(color: PavlColors.textDim)),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _pair,
            icon: const Icon(Icons.key, size: 16),
            label: const Text('输入 PIN'),
          ),
        ],
      ),
    );
  }
}
