/// 设置面板。
///
/// 目前只有一项真正会影响行为的开关：进度模式。两套模式的差别对用户并不
/// 直观，所以文案要讲清楚「记录存在哪、别的设备看不看得见」。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/pavl_client.dart';
import '../app.dart';
import '../store/app_store.dart';
import '../util/app_log.dart';

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({
    super.key,
    required this.store,
    required this.connection,
  });

  final AppStore store;
  final ServerConnection connection;

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  late bool _crossDevice = widget.store.crossDeviceProgress;

  Future<void> _toggle(bool value) async {
    setState(() => _crossDevice = value);
    widget.store.crossDeviceProgress = value;
    await widget.store.save();
  }

  Future<void> _copyLogPath() async {
    await Clipboard.setData(ClipboardData(text: logFile().path));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('日志路径已复制')),
      );
    }
  }

  /// 在资源管理器里打开日志文件所在的目录。
  ///
  /// 目录可能还不存在（从没播放过），先建出来。explorer 不接受 `file:` URI，
  /// 必须给 Windows 原生路径。某些机器上 explorer 本身起不来（退出码
  /// 0xC0000142，环境块异常），所以这里等一小会儿看它是不是直接死掉，死了就
  /// 退回「把路径复制到剪贴板」，而不是弹一个用户看不懂的系统错误框。
  Future<void> _openLogFolder() async {
    final dir = logFile().parent;
    try {
      await dir.create(recursive: true);
    } catch (_) {
      // 目录建不出来时仍然试一下打开，explorer 自己会报错。
    }

    var opened = false;
    try {
      final process = await Process.start('explorer.exe', [dir.path]);
      final code = await process.exitCode
          .timeout(const Duration(seconds: 2), onTimeout: () => 0);
      // explorer 打开成功时的退出码是 0 或 1；0xC0000142 之类说明它没起来。
      opened = code == 0 || code == 1;
      if (!opened) logLine('ui', '打开日志目录失败，explorer 退出码 $code');
    } catch (error) {
      logLine('ui', '打开日志目录异常：$error');
    }

    if (opened || !mounted) return;
    await Clipboard.setData(ClipboardData(text: dir.path));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('系统打不开资源管理器，路径已复制：${dir.path}'),
        duration: const Duration(seconds: 6),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: PavlColors.surface,
      title: const Text('设置', style: TextStyle(fontSize: 18)),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionTitle('播放进度'),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _crossDevice,
              onChanged: (value) => _toggle(value),
              title: const Text('跨设备同步进度', style: TextStyle(fontSize: 15)),
              subtitle: const Text(
                '关闭时只看本机自己的记录；打开后使用服务端保存的最近一次位置，'
                '任何设备播过都会在这里继续。',
                style: TextStyle(fontSize: 12.5),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _crossDevice
                  ? '当前模式：跨设备。打开视频时提示的是最近一次播放位置（可能来自别的设备）。'
                  : '当前模式：仅本机。打开视频时提示的只有这台设备自己的上次位置。',
              style: const TextStyle(
                fontSize: 12.5,
                color: PavlColors.textDim,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 20),
            _sectionTitle('排查'),
            Text(
              '播放出问题时，日志里会记下失败原因。点下面的按钮复制路径，'
              '把 client.log 发过来即可定位。',
              style: const TextStyle(
                fontSize: 12.5,
                color: PavlColors.textDim,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                OutlinedButton(
                  onPressed: _copyLogPath,
                  child: const Text('复制日志路径'),
                ),
                const SizedBox(width: 10),
                OutlinedButton(
                  onPressed: _openLogFolder,
                  child: const Text('打开日志目录'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '${logFile().path}'
              '${File(logFile().path).existsSync() ? '' : '（还没有生成，播一次就会出现）'}',
              style: const TextStyle(fontSize: 11, color: PavlColors.textDim),
            ),
            const SizedBox(height: 20),
            _sectionTitle('本机与服务器'),
            _kv('设备名', widget.store.deviceName),
            _kv('设备 ID', widget.store.deviceId),
            _kv('服务器', '${widget.connection.name} (${widget.connection.host}:${widget.connection.port})'),
            _kv('状态', widget.connection.token == null ? '未配对' : '已配对'),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 13,
            color: PavlColors.textDim,
            fontWeight: FontWeight.w600,
          ),
        ),
      );

  Widget _kv(String key, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 76,
              child: Text(
                key,
                style: const TextStyle(fontSize: 13, color: PavlColors.textDim),
              ),
            ),
            Expanded(
              child: SelectableText(
                value,
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ],
        ),
      );
}
