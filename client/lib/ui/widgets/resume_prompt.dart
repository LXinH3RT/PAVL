/// 「上次看到 12:31」提示框。
///
/// 两种模式的文案不同：
///   - 本地模式：只提本机记录的位置
///   - 跨设备模式：说明这是最近一次任一设备的进度，并显示是哪台设备
library;

import 'package:flutter/material.dart';

import '../../api/pavl_client.dart';
import '../../app.dart';
import 'control_bar.dart' show formatDuration;

/// 继续观看提示框。
///
/// 返回值：
///   - 非 null：从该位置继续
///   - null（点「从头开始」或关闭）：从头播放
class ResumePromptDialog extends StatelessWidget {
  const ResumePromptDialog({
    super.key,
    required this.record,
    required this.title,
    required this.crossDevice,
  });

  final ProgressRecord record;
  final String title;

  /// true 表示这条记录来自服务端跨设备同步。
  final bool crossDevice;

  @override
  Widget build(BuildContext context) {
    final position = Duration(seconds: record.position.round());
    final total = Duration(seconds: record.duration.round());
    return AlertDialog(
      backgroundColor: PavlColors.surface,
      title: const Text('继续观看', style: TextStyle(fontSize: 18)),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 15),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: PavlColors.surfaceHigh,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.history,
                          size: 16, color: PavlColors.accent),
                      const SizedBox(width: 8),
                      Text(
                        '上次看到 ${formatDuration(position)} / ${formatDuration(total)}',
                        style: const TextStyle(fontSize: 14),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: record.ratio,
                      minHeight: 4,
                      backgroundColor: Colors.white12,
                      valueColor: const AlwaysStoppedAnimation(PavlColors.accent),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Text(
              crossDevice
                  ? '这是最近一次播放的位置，来自${record.deviceName.isEmpty ? '其他设备' : record.deviceName}。'
                  : '这是本机上次的播放位置。',
              style: const TextStyle(fontSize: 12, color: PavlColors.textDim),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('从头开始'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(position),
          child: const Text('继续播放'),
        ),
      ],
    );
  }
}
