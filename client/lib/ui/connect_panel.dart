/// 连接面板：发现到的服务器、地址与 PIN 一步连上。
///
/// 早期版本是「选服务器 → 下一页再输 PIN」两段式，实际用起来很别扭：
/// PIN 就在服务端托盘上摆着，却要先跳一层才让填。这里把地址和 PIN 并排放
/// 在主界面，点发现的服务器只负责把地址填进输入框，用户补齐 PIN 后一次连接
/// 完成配对，全程不换页。
///
/// 界面上只留「能直接操作的东西」：发现结果、地址、PIN、连接按钮。局域网
/// 搜索是启动时自动做的，不需要一个「重新搜索」按钮去提示用户点。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/discovery.dart';
import '../api/pavl_client.dart';
import '../app.dart';
import '../util/app_log.dart';
import '../util/platform_support.dart';

/// 连接面板。
class ConnectPanel extends StatefulWidget {
  const ConnectPanel({
    super.key,
    required this.servers,
    required this.savedServers,
    required this.deviceId,
    required this.deviceName,
    required this.onConnected,
    required this.onPickSaved,
  });

  /// 局域网里发现到的服务器。
  final List<DiscoveredServer> servers;

  /// 已经配对过的服务器，带令牌，点一下就能直接进。
  final List<ServerConnection> savedServers;

  final String deviceId;
  final String deviceName;

  /// 地址与 PIN 都验证通过后回调，参数是带令牌的连接。
  final ValueChanged<ServerConnection> onConnected;

  /// 点已保存服务器的回调（令牌仍然有效时）。
  final ValueChanged<ServerConnection> onPickSaved;

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

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 48),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(),
          const SizedBox(height: 32),
          if (widget.servers.isNotEmpty) ...[
            _sectionTitle('局域网里发现的服务器'),
            const SizedBox(height: 8),
            ...widget.servers.map(_serverTile),
            const SizedBox(height: 24),
          ],
          _sectionTitle('连接服务器'),
          const SizedBox(height: 8),
          _connectForm(),
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
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(12)),
          clipBehavior: Clip.antiAlias,
          child: Image.asset('assets/branding/logo_mark.png',
              fit: BoxFit.cover, filterQuality: FilterQuality.high),
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
                  hintText: '留空则在局域网里自动找',
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
          _error ?? '地址可以留空，此时只在局域网里找；PIN 在服务端托盘菜单里。',
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
      if (found.length == 1) return found.first;
      if (found.isNotEmpty) {
        setState(() => _error = '找到 ${found.length} 台，请先点一台填好地址');
        return null;
      }
      // 广播没应答不等于连不上：设了固定地址的服务端不会出现在发现列表里，
      // 换过网段的机器也可能收不到广播。已经配对过的那几台挨个探一遍，
      // 通了就不用让用户翻出去查 IP。
      final saved = await _probeSavedServers();
      if (!mounted) return null;
      if (saved.length == 1) return saved.first;
      if (saved.isNotEmpty) {
        setState(() => _error = '找到 ${saved.length} 台，请先点一台填好地址');
        return null;
      }
      setState(() => _error = _discoveryFailedHint);
      return null;
    }
    setState(() => _error = '找到 ${widget.servers.length} 台，请先点一台填好地址');
    return null;
  }

  /// 挨个探一遍已经配对过的服务器，留下还连得上的。
  ///
  /// 地址可能已经变了（换了路由器、改成动态分配），所以以探通的真实结果
  /// 为准，而不是直接信任本地存的那条记录。
  Future<List<DiscoveredServer>> _probeSavedServers() async {
    final results = <DiscoveredServer>[];
    for (final saved in widget.savedServers) {
      final probed = await probeHost(saved.host, saved.port);
      if (probed != null) results.add(probed);
    }
    return results;
  }

  /// 广播一轮但一台都没应答时的提示。
  ///
  /// macOS 上最常见的失败原因不是网络不通，而是用户上次点了「不允许」：
  /// 系统对本地网络的拒绝是静默的，广播包发得出去、收不到任何回应，
  /// 从应用侧看不出和「局域网里确实没有服务器」的区别。所以这里点出
  /// 该去哪里检查，而不是让用户去猜。
  String get _discoveryFailedHint {
    if (Platform.isMacOS) {
      return '没找到服务器。若服务端确实在同一局域网内，请到「系统设置 → 隐私与安全性 → '
          '本地网络」确认 PAVL 已勾选；也可以在上面直接填地址。';
    }
    return '没找到服务器，请在上面填上地址';
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
          storage: server.storage,
        ),
        deviceId: widget.deviceId,
      );
      try {
        final token = await client.pair(
          pin: pin,
          deviceId: widget.deviceId,
          deviceName: widget.deviceName,
          platform: platformTag,
        );
        logLine('net', '配对成功 ${server.host}:${server.port}');
        if (!mounted) return;
        widget.onConnected(
          ServerConnection(
            serverId: server.serverId,
            name: server.name,
            host: server.host,
            port: server.port,
            token: token,
            storage: server.storage,
          ),
        );
      } finally {
        client.close();
      }
    } on PavlApiError catch (error) {
      logLine('net', '配对被拒绝：${error.code} ${error.message}');
      if (!mounted) return;
      setState(() {
        _error = switch (error.code) {
          'bad_pin' => 'PIN 不正确',
          'no_pin' => '服务端还没有设置 PIN',
          _ => error.message,
        };
      });
    } on PavlNetworkError catch (error) {
      logLine('net', '配对网络错误：${error.message}');
      if (!mounted) return;
      setState(() => _error = error.message);
    } catch (error) {
      logLine('net', '配对异常：$error');
      if (!mounted) return;
      setState(() => _error = '连接失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
