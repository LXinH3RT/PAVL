/// 「检查更新」弹窗。
///
/// 从「关于」页点版本号进来：一进来就查 GitHub 的最新发布，查到就显示版本
/// 对比、更新说明与「下载更新」按钮。下载在弹窗里跑，关掉弹窗不会中断——
/// 下载器是独立的单例，重新打开还能看到进度。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../app.dart';
import '../core/update_download_manager.dart';
import '../core/update_install.dart';
import '../core/update_service.dart';
import '../util/app_exit.dart';
import '../util/app_log.dart';
import '../util/build_info.dart';

/// 打开「检查更新」弹窗。
Future<void> showUpdateDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const _UpdateDialog(),
  );
}

/// 弹窗内的几个状态。
enum _Phase { checking, ready, downloading, applying, done, failed }

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog();

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  final UpdateService _service = UpdateService();
  final UpdateDownloadManager _manager = UpdateDownloadManager.instance;

  _Phase _phase = _Phase.checking;
  ReleaseInfo? _release;
  ReleaseAsset? _asset;
  String? _error;
  String _note = "";

  @override
  void initState() {
    super.initState();
    _manager.addListener(_onManager);
    // 已经下好了就不要再查一遍，直接显示「安装并重启」。
    if (_manager.ready) {
      _phase = _Phase.ready;
    } else {
      unawaited(_check());
    }
  }

  @override
  void dispose() {
    _manager.removeListener(_onManager);
    _service.close();
    super.dispose();
  }

  void _onManager() {
    if (!mounted) return;
    setState(() {
      if (_manager.state == UpdateDownloadState.failed) {
        _phase = _Phase.failed;
        _error = _manager.error;
      } else if (_manager.running) {
        _phase = _Phase.downloading;
      } else if (_manager.ready) {
        _phase = _Phase.ready;
      }
    });
  }

  Future<void> _check() async {
    setState(() {
      _phase = _Phase.checking;
      _error = null;
      _note = "";
    });
    try {
      final release = await _service.fetchLatest();
      final asset = release.assetFor(currentPlatform);
      if (!mounted) return;
      setState(() {
        _release = release;
        _asset = asset;
        if (!isNewerVersion(release.version)) {
          _note = "已经是最新版本。";
        } else if (asset == null) {
          _note = "这个版本没有 ${currentPlatform == "macos" ? "macOS" : "Windows"} 的包，去发布页看看。";
        }
        _phase = _Phase.ready;
      });
      logLine("update", "查到最新版本 ${release.version}（当前 $appVersion）");
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.failed;
        _error = error is UpdateException ? error.message : "检查失败：$error";
      });
      logLine("update", "检查更新失败：$error");
    }
  }

  Future<void> _download() async {
    final release = _release;
    final asset = _asset;
    if (release == null || asset == null) return;
    setState(() {
      _phase = _Phase.downloading;
      _error = null;
    });
    try {
      await _manager.start(
        release: release,
        asset: asset,
        service: UpdateService(timeout: const Duration(seconds: 30)),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.failed;
        _error = error is UpdateException ? error.message : "下载失败：$error";
      });
    }
  }

  /// 铺文件并重启。
  ///
  /// 先把窗口关掉（不然新本体等不到旧进程退出），再登记待办、拉起新本体。
  Future<void> _install() async {
    final file = _manager.file;
    final release = _release;
    if (file == null) return;
    setState(() {
      _phase = _Phase.applying;
      _error = null;
    });
    try {
      await beginApply(
        zip: file,
        version: release?.version ?? "new",
      );
      logLine("update", "已交给新本体接管，退出当前进程");
      await _manager.clear();
      // 直接退出：新本体在等这个位置的句柄。
      exitApp();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.failed;
        _error = error is UpdateException ? error.message : "安装失败：$error";
      });
      logLine("update", "安装更新失败：$error");
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context).size;
    return Dialog(
      backgroundColor: PavlColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 620, maxHeight: media.height * 0.82),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(),
            const Divider(height: 1),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _versionRows(),
                    const SizedBox(height: 12),
                    _statusBlock(),
                    if (_release != null && _release!.body.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      const Text(
                        "更新内容",
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: PavlColors.textDim,
                          letterSpacing: 1.0,
                        ),
                      ),
                      const SizedBox(height: 6),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 180),
                        child: Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: PavlColors.surfaceHigh,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: PavlColors.border),
                          ),
                          child: SingleChildScrollView(
                            child: SelectableText(
                              _release!.body,
                              style: const TextStyle(fontSize: 12, height: 1.6),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            _buttons(),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
      child: Row(
        children: [
          const Expanded(
            child: Text(
              "检查更新",
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
            ),
          ),
          IconButton(
            tooltip: "关闭",
            icon: const Icon(Icons.close, size: 20),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Widget _versionRows() {
    final release = _release;
    final published = release?.publishedAt;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _kv("当前版本", appVersion),
        _kv("最新版本", release == null ? "查询中…" : release.version),
        if (published != null)
          _kv(
            "发布时间",
            "${published.toLocal().year}-${_two(published.toLocal().month)}-${_two(published.toLocal().day)}",
          ),
        if (_asset != null && isNewerVersion(release!.version))
          _kv("更新包", "${_asset!.name}（${_asset!.sizeText}）"),
      ],
    );
  }

  String _two(int value) => value < 10 ? "0$value" : "$value";

  Widget _kv(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            child: Text(
              label,
              style: const TextStyle(fontSize: 12.5, color: PavlColors.textDim),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: SelectableText(
              value,
              style: const TextStyle(fontSize: 12.5, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusBlock() {
    switch (_phase) {
      case _Phase.checking:
        return Row(
          children: const [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 10),
            Text("正在检查 GitHub 上的最新版本…", style: TextStyle(fontSize: 12.5)),
          ],
        );

      case _Phase.downloading:
        final progress = _manager.progress;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LinearProgressIndicator(value: progress.fraction),
            const SizedBox(height: 8),
            Text(
              progress.total <= 0
                  ? "正在下载…"
                  : "已下载 ${progress.receivedText} / ${progress.totalText}",
              style: const TextStyle(fontSize: 12.5, color: PavlColors.textDim),
            ),
          ],
        );

      case _Phase.applying:
        return const Row(
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                "正在替换文件，程序会自动重启…",
                style: TextStyle(fontSize: 12.5),
              ),
            ),
          ],
        );

      case _Phase.done:
        return Text(_note, style: const TextStyle(fontSize: 12.5));

      case _Phase.failed:
        return Text(
          _error ?? "出错了",
          style: const TextStyle(fontSize: 12.5, color: PavlColors.danger),
        );

      case _Phase.ready:
        if (_manager.ready) {
          return const Text(
            "新版本已经下载完成，点「安装并重启」即可换到新版本。",
            style: TextStyle(fontSize: 12.5),
          );
        }
        if (_note.isNotEmpty) {
          return Text(_note, style: const TextStyle(fontSize: 12.5));
        }
        return const Text(
          "下载完成后会先替换文件再自动重启，数据目录里的东西不受影响。",
          style: TextStyle(fontSize: 12.5, color: PavlColors.textDim, height: 1.5),
        );
    }
  }

  Widget _buttons() {
    final canDownload = _phase == _Phase.ready &&
        _release != null &&
        _asset != null &&
        isNewerVersion(_release!.version) &&
        !_manager.ready;
    final canInstall = _phase == _Phase.ready && _manager.ready;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      child: Row(
        children: [
          TextButton(
            onPressed: _phase == _Phase.checking ? null : _check,
            child: const Text("重新检查"),
          ),
          const Spacer(),
          TextButton(
            onPressed: () => openReleasesPage(),
            child: const Text("打开发布页"),
          ),
          const SizedBox(width: 8),
          if (canDownload)
            FilledButton(
              onPressed: _download,
              child: Text(_manager.savedBytes > 0 ? "接着下载" : "下载更新"),
            ),
          if (canInstall)
            FilledButton(
              onPressed: _install,
              child: const Text("安装并重启"),
            ),
          if (!canDownload && !canInstall)
            FilledButton(
              onPressed: _phase == _Phase.checking || _phase == _Phase.applying
                  ? null
                  : () => Navigator.of(context).pop(),
              child: const Text("关闭"),
            ),
        ],
      ),
    );
  }
}
