/// PIN 配对对话框。
///
/// 六位数字，分格输入。配对成功后返回令牌，由调用方写进本地存储。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/pavl_client.dart';
import '../app.dart';
import '../util/platform_support.dart';

/// 配对对话框。
class PairDialog extends StatefulWidget {
  const PairDialog({
    super.key,
    required this.client,
    required this.serverName,
    required this.deviceId,
    required this.deviceName,
  });

  final PavlClient client;
  final String serverName;
  final String deviceId;
  final String deviceName;

  @override
  State<PairDialog> createState() => _PairDialogState();
}

class _PairDialogState extends State<PairDialog> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusNode.requestFocus());
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final pin = _controller.text.trim();
    if (pin.length != 6) {
      setState(() => _error = '请输入 6 位数字');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final token = await widget.client.pair(
        pin: pin,
        deviceId: widget.deviceId,
        deviceName: widget.deviceName,
        platform: platformTag,
      );
      if (!mounted) return;
      Navigator.of(context).pop(token);
    } on PavlApiError catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = switch (error.code) {
          'bad_pin' => 'PIN 不正确，请检查服务端托盘上显示的六位数字',
          'no_pin' => '服务端还没有设置 PIN',
          _ => error.message,
        };
      });
    } on PavlNetworkError catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = error.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: PavlColors.surface,
      title: const Text('配对设备', style: TextStyle(fontSize: 18)),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '在 ${widget.serverName} 的托盘菜单里查看 PIN，然后输入到这里。',
              style: const TextStyle(fontSize: 13, color: PavlColors.textDim),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _controller,
              focusNode: _focusNode,
              enabled: !_submitting,
              textAlign: TextAlign.center,
              maxLength: 6,
              style: const TextStyle(
                fontSize: 26,
                letterSpacing: 12,
                fontWeight: FontWeight.w600,
              ),
              decoration: InputDecoration(
                counterText: '',
                hintText: '••••••',
                hintStyle: TextStyle(
                  fontSize: 26,
                  letterSpacing: 12,
                  color: PavlColors.textDim.withValues(alpha: 0.3),
                ),
                border: const OutlineInputBorder(),
                errorText: _error,
              ),
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 8),
            const Text(
              '配对成功后，这台设备会出现在服务端的设备列表里，可单独吊销。',
              style: TextStyle(fontSize: 12, color: PavlColors.textDim),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('配对'),
        ),
      ],
    );
  }
}
