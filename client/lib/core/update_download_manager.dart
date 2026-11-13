/// 后台下载器。
///
/// 下载不能活在弹窗里：用户关掉弹窗去干别的，下载还得继续；再点开版本号也要
/// 能看到进度。所以做成一个全局单例，弹窗只是它的一个观察者。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../util/app_log.dart';
import 'update_service.dart';

enum UpdateDownloadState { idle, running, ready, failed }

/// 下载任务的状态。界面监听它，关窗不影响进度。
class UpdateDownloadManager extends ChangeNotifier {
  UpdateDownloadManager({UpdateService? service, bool singleton = true})
    : _service = service,
      _isSingleton = singleton {
    if (_isSingleton) _instance = this;
  }

  static UpdateDownloadManager? _instance;

  /// 全局单例。第一次访问时创建。
  static UpdateDownloadManager get instance =>
      _instance ?? UpdateDownloadManager();

  /// 测试里要一个干净的实例。
  factory UpdateDownloadManager.forTesting({UpdateService? service}) =>
      UpdateDownloadManager(service: service ?? UpdateService(), singleton: false);

  final bool _isSingleton;
  UpdateService? _service;
  UpdateService get _resolved => _service ??= UpdateService();

  UpdateDownloadState _state = UpdateDownloadState.idle;
  String? _tag;
  ReleaseAsset? _asset;
  int _received = 0;
  int _total = 0;
  File? _file;
  String? _error;
  DownloadCancellation? _cancellation;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);

  UpdateDownloadState get state => _state;
  String? get tag => _tag;
  ReleaseAsset? get asset => _asset;
  File? get file => _file;
  String? get error => _error;

  bool get running => _state == UpdateDownloadState.running;
  bool get ready => _state == UpdateDownloadState.ready;

  /// 已有半成品时，界面上「接着下载」要知道已存多少。
  int get savedBytes => _received;

  DownloadProgress get progress =>
      DownloadProgress(received: _received, total: _total);

  /// 开始下载。不重入：已经在跑就直接返回。
  Future<void> start({
    required ReleaseInfo release,
    required ReleaseAsset asset,
    UpdateService? service,
  }) async {
    if (running) return;
    if (_service != null) _service!.close();
    _service = service ?? _resolved;

    _state = UpdateDownloadState.running;
    _tag = release.tag;
    _asset = asset;
    _error = null;
    _file = null;
    _received = 0;
    _total = asset.size;
    _cancellation = DownloadCancellation();
    _notify(force: true);

    try {
      final file = await _resolved.download(
        asset,
        onProgress: (progress) {
          _received = progress.received;
          _total = progress.total;
          _notify();
        },
        cancellation: _cancellation,
      );
      _file = file;
      _received = await file.length();
      _total = _received;
      _state = UpdateDownloadState.ready;
      logLine("update", "下载完成：${file.path}（$_received 字节）");
    } catch (error) {
      if (error is UpdateException && error.code == "cancelled") {
        _state = UpdateDownloadState.idle;
      } else {
        _state = UpdateDownloadState.failed;
        _error = error is UpdateException ? error.message : "下载失败：$error";
        logLine("update", "下载失败：$error");
      }
    } finally {
      _cancellation = null;
      _notify(force: true);
    }
  }

  /// 丢掉已下的部分。
  Future<void> discard() async {
    final asset = _asset;
    try {
      if (asset != null) await _resolved.discardPartial(asset);
    } catch (error) {
      logLine("update", "清理半成品失败：$error");
    }
    _state = UpdateDownloadState.idle;
    _received = 0;
    _total = 0;
    _file = null;
    _error = null;
    _notify(force: true);
  }

  /// 安装完就没必要再留这个包了。
  Future<void> clear() async {
    await discard();
  }

  void cancel() {
    _cancellation?.cancel();
  }

  /// 进度回调很密（每块每读一次都会来），压到 120ms 一次，别把界面刷爆。
  void _notify({bool force = false}) {
    if (!force) {
      final now = DateTime.now();
      if (now.difference(_lastNotify).inMilliseconds < 120) return;
      _lastNotify = now;
    } else {
      _lastNotify = DateTime.now();
    }
    if (_isSingleton || !_disposed) notifyListeners();
  }

  bool _disposed = false;

  @override
  void dispose() {
    // 单例跟着进程活，不主动 dispose。
    if (!_isSingleton) {
      _disposed = true;
      _service?.close();
      super.dispose();
    }
  }

  /// 浏览器打开 release 页，用户想自己下就用这条路。
  Future<void> openReleases() async {
    try {
      if (Platform.isWindows) {
        await Process.start("cmd", ["/c", "start", "", kReleasesPageUrl],
            mode: ProcessStartMode.detached);
      } else if (Platform.isMacOS) {
        await Process.start("open", [kReleasesPageUrl],
            mode: ProcessStartMode.detached);
      } else {
        await Process.start("xdg-open", [kReleasesPageUrl],
            mode: ProcessStartMode.detached);
      }
    } catch (error) {
      logLine("update", "打开发布页失败：$error");
    }
  }
}

/// 打开 release 页。
Future<void> openReleasesPage() => UpdateDownloadManager.instance.openReleases();
