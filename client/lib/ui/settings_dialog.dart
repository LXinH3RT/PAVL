/// 设置面板。
///
/// 目前只有一项真正会影响行为的开关：进度模式。两套模式的差别对用户并不
/// 直观，所以文案要讲清楚「记录存在哪、别的设备看不看得见」。
library;

import 'package:flutter/material.dart';

import '../api/pavl_client.dart';
import '../app.dart';
import '../store/app_store.dart';

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
