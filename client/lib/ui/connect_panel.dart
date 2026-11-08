/// 连接面板：发现进度、服务器列表、地址与 PIN 一步连上。
///
/// 早期版本是「选服务器 → 下一页再输 PIN」两段式，实际用起来很别扭：
/// PIN 就在服务端托盘上摆着，却要先跳一层才让填。这里把地址和 PIN 并排放
/// 在主界面，点发现的服务器只负责把地址填进输入框，用户补齐 PIN 后一次连接
/// 完成配对，全程不换页。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/discovery.dart';
import '../api/pavl_client.dart';
import '../app.dart';

/// 连接面板。
class ConnectPanel extends StatefulWidget {
  const ConnectPanel({
    super.key,
    required this.phase,
    required this.statusText,
    required this.servers,
    required this.savedServers,
    required this.deviceId,
    required this.deviceName,
    required this.onDiscover,
    required this.onConnected,
    required this.onPickSaved,
    required this.onForget,
  });

  /// 当前阶段名，与 HomeScreen 的 _Phase 对应。
  final String phase;
  final String statusText;
  final List<DiscoveredServer> servers;

  /// 已经配对过的服务器，带令牌，点一下就能直接进。
  final List<ServerConnection> savedServers;

  final String deviceId;
  final String deviceName;

  final VoidCallback onDiscover;

  /// 地址与 PIN 都验证通过后回调，参数是带令牌的连接。
  final ValueChanged<ServerConnection> onConnected;

  /// 点已保存服务器的回调（令牌仍然有效时）。
  final ValueChanged<ServerConnection> onPickSaved;

  final ValueChanged<String> onForget;

  @override
  State<ConnectPanel> createState() => _ConnectPanelState();
}

class _ConnectPanelState extends State<ConnectPanel> {
  final _hostController = TextEditingController();
  final _portController = TextEditingController(text: '8765');
  final _pinController = TextEditingController();
  final _pinFocus = FocusNode();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _pinController.dispose();
    _pinFocus.dispose();
    super.dispose();
  }

  bool get _searching =>
      widget.phase == 'probing' || widget.phase == 'discovering';

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 48),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(),
          const SizedBox(height: 28),
          _status(),
          const SizedBox(height: 24),
          if (widget.servers.isNotEmpty) ...[
            _sectionTitle('局域网里发现的服务器'),
            const SizedBox(height: 8),
            ...widget.servers.map(_serverTile),
            const SizedBox(height: 24),
          ],
          _sectionTitle('连接服务器'),
          const SizedBox(height: 8),
          _connectForm(),
          const SizedBox(height: 28),
          _savedList(),
        ],
      ),
    );
  }

  Widget _header() {
    return Row(
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: PavlColors.accent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Icon(Icons.play_arrow_rounded,
              color: Colors.white, size: 32),
        ),
        const SizedBox(width: 16),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'PAVL',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.5,
              ),
            ),
            Text(
              'Play All Videos in Lan',
              style: TextStyle(
                fontSize: 13,
                color: PavlColors.textDim,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _status() {
    final failed = widget.phase == 'failed';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: PavlColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: failed
              ? PavlColors.danger.withValues(alpha: 0.4)
              : PavlColors.border,
        ),
      ),
      child: Row(
        children: [
          if (_searching)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Icon(
              failed ? Icons.error_outline : Icons.wifi_tethering,
              size: 18,
              color: failed ? PavlColors.danger : PavlColors.success,
            ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              widget.statusText,
              style: const TextStyle(fontSize: 14),
            ),
          ),
          if (!_searching)
            TextButton.icon(
              onPressed: widget.onDiscover,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('重新搜索'),
            ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.only(left: 2),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: PavlColors.textDim,
            letterSpacing: 1.0,
          ),
        ),
      );

  /// 点一下把地址填进下面的输入框，PIN 让用户接着填。
  Widget _serverTile(DiscoveredServer server) {
    final saved = widget.savedServers
        .where((e) => e.serverId == server.serverId)
        .firstOrNull;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: PavlColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: PavlColors.border),
      ),
      child: ListTile(
        leading: const Icon(Icons.dns_outlined, size: 20),
        title: Text(server.name),
        subtitle: Text(
          '${server.host}:${server.port}  ·  v${server.version}'
          '${saved?.hasToken == true ? '  ·  已配对' : '  ·  需要 PIN'}',
          style: const TextStyle(fontSize: 12, color: PavlColors.textDim),
        ),
        trailing: saved?.hasToken == true
            ? FilledButton.tonal(
                onPressed: () => widget.onPickSaved(saved!),
                child: const Text('直接进入'),
              )
            : const Icon(Icons.arrow_downward, size: 18),
        onTap: () {
          _hostController.text = server.host;
          _portController.text = '${server.port}';
          setState(() => _error = null);
          _pinFocus.requestFocus();
        },
      ),
    );
  }

  Widget _connectForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              flex: 4,
              child: TextField(
                controller: _hostController,
                enabled: !_busy,
                decoration: const InputDecoration(
                  labelText: '服务器地址',
                  hintText: '留空则在局域网里自动搜索',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => _pinFocus.requestFocus(),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 96,
              child: TextField(
                controller: _portController,
                enabled: !_busy,
                decoration: const InputDecoration(
                  labelText: '端口',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.number,
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 150,
              child: TextField(
                controller: _pinController,
                focusNode: _pinFocus,
                enabled: !_busy,
                obscureText: true,
                maxLength: 6,
                decoration: const InputDecoration(
                  labelText: 'PIN',
                  hintText: '六位数字',
                  counterText: '',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                onSubmitted: (_) => _submit(),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              height: 48,
              child: FilledButton(
                onPressed: _busy ? null : _submit,
                child: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('连接'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          _error ??
              '地址可以留空（端口会忽略），此时只在局域网里找；PIN 在服务端托盘菜单里。',
          style: TextStyle(
            fontSize: 12,
            color: _error != null ? PavlColors.danger : PavlColors.textDim,
          ),
        ),
      ],
    );
  }

  /// 地址留空时，用发现到的服务器补齐；多台就要求用户点一下。
  Future<DiscoveredServer?> _resolveServer() async {
    final typed = _hostController.text.trim();
    if (typed.isNotEmpty) {
      final port = int.tryParse(_portController.text.trim()) ?? 8765;
      if (port <= 0 || port > 65535) {
        setState(() => _error = '端口要在 1 到 65535 之间');
        return null;
      }
      final probed = await probeHost(typed, port);
      if (probed == null) {
        setState(() => _error = '连不上 $typed:$port，检查服务端是否在运行、防火墙是否放行');
      }
      return probed;
    }

    if (widget.servers.length == 1) return widget.servers.first;
    if (widget.servers.isEmpty) {
      // 没有手动地址也没有发现结果：现场广播一轮，给用户一次机会。
      setState(() => _error = '正在局域网里找服务器…');
      final found = await DiscoverySession().run();
      if (!mounted) return null;
      if (found.isEmpty) {
        setState(() => _error = '没找到服务器，请在上面填上地址');
        return null;
      }
      if (found.length == 1) return found.first;
      setState(() => _error = '找到 ${found.length} 台，请先点一台填好地址');
      return null;
    }
    setState(() => _error = '找到 ${widget.servers.length} 台，请先点一台填好地址');
    return null;
  }

  Future<void> _submit() async {
    final pin = _pinController.text.trim();
    if (pin.length != 6) {
      setState(() => _error = 'PIN 是服务端上的六位数字');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final server = await _resolveServer();
      if (!mounted) return;
      if (server == null) {
        setState(() => _busy = false);
        return;
      }

      final client = PavlClient(
        connection: ServerConnection(
          serverId: server.serverId,
          name: server.name,
          host: server.host,
          port: server.port,
        ),
      );
      try {
        final token = await client.pair(
          pin: pin,
          deviceId: widget.deviceId,
          deviceName: widget.deviceName,
          platform: 'windows',
        );
        if (!mounted) return;
        widget.onConnected(
          ServerConnection(
            serverId: server.serverId,
            name: server.name,
            host: server.host,
            port: server.port,
            token: token,
          ),
        );
      } finally {
        client.close();
      }
    } on PavlApiError catch (error) {
      if (!mounted) return;
      setState(() {
        _error = switch (error.code) {
          'bad_pin' => 'PIN 不正确',
          'no_pin' => '服务端还没有设置 PIN',
          _ => error.message,
        };
      });
    } on PavlNetworkError catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _savedList() {
    if (widget.savedServers.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('已保存的服务器'),
        const SizedBox(height: 8),
        ...widget.savedServers.map(
          (conn) => Container(
            margin: const EdgeInsets.only(bottom: 6),
            decoration: BoxDecoration(
              color: PavlColors.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: PavlColors.border),
            ),
            child: ListTile(
              dense: true,
              leading: const Icon(Icons.history, size: 18),
              title: Text(conn.name, style: const TextStyle(fontSize: 14)),
              subtitle: Text(
                '${conn.host}:${conn.port}'
                '${conn.hasToken ? '' : '  ·  未配对'}',
                style:
                    const TextStyle(fontSize: 12, color: PavlColors.textDim),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(
                    onPressed: () => widget.onPickSaved(conn),
                    child: Text(conn.hasToken ? '进入' : '连接'),
                  ),
                  IconButton(
                    tooltip: '忘记此服务器',
                    iconSize: 16,
                    onPressed: () => widget.onForget(conn.serverId),
                    icon: const Icon(Icons.close, color: PavlColors.textDim),
                  ),
                ],
              ),
              onTap: () => widget.onPickSaved(conn),
            ),
          ),
        ),
      ],
    );
  }
}
