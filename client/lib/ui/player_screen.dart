/// 播放页。
///
/// 结构：全屏画面 + 叠在上面的控制层。控制层默认隐藏，鼠标移动或按键唤出，
/// 3 秒无操作自动淡出。全屏时隐藏标题栏。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';

import '../api/pavl_client.dart';
import '../app.dart';
import '../player/playback_controller.dart';
import '../store/app_store.dart';
import 'widgets/control_bar.dart';
import 'widgets/resume_prompt.dart';
import 'widgets/track_menu.dart';

/// 播放页。
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    required this.store,
    required this.client,
    required this.path,
    required this.fallbackTitle,
  });

  final AppStore store;
  final PavlClient client;
  final String path;

  /// 详情还没加载完时先显示的标题。
  final String fallbackTitle;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  MediaDetail? _detail;
  PlaybackController? _controller;
  String? _error;

  bool _controlsVisible = true;
  bool _fullscreen = false;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    final controller = _controller;
    _controller = null;
    // dispose 里要上报最后一次进度，不能 await，用 unawaited 让它跑完。
    if (controller != null) {
      unawaited(controller.dispose());
    }
    if (_fullscreen) {
      unawaited(windowManager.setFullScreen(false));
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final detail = await widget.client.media(widget.path);
      if (!mounted) return;

      final controller = PlaybackController(
        client: widget.client,
        store: widget.store,
        mediaDetail: detail,
      );
      controller.onCompleted.listen((_) {
        if (!mounted) return;
        // 播完自动退回列表。
        Navigator.of(context).maybePop();
      });
      controller.onError.listen((message) {
        if (!mounted) return;
        setState(() => _error = message);
      });

      setState(() {
        _detail = detail;
        _controller = controller;
      });

      // 询问是否从上次位置继续。
      final resume = await _resolveResumePosition(detail);
      if (!mounted) return;

      var startAt = Duration.zero;
      if (resume != null) {
        final choice = await showDialog<Duration?>(
          context: context,
          barrierDismissible: false,
          builder: (_) => ResumePromptDialog(
            record: resume,
            title: detail.title,
            crossDevice: widget.store.crossDeviceProgress,
          ),
        );
        if (!mounted) return;
        startAt = choice ?? Duration.zero;
      }

      await controller.open(startAt: startAt);
      _scheduleHide();
    } on PavlApiError catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
    } on PavlNetworkError catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
    }
  }

  /// 决定用哪条进度记录。
  ///
  /// 跨设备模式读服务端顶层 position（最近一次播放）；否则读本设备自己的记录。
  /// 服务端 /media 返回的 progress 是顶层那份，按设备的要单独查。
  Future<ProgressRecord?> _resolveResumePosition(MediaDetail detail) async {
    if (widget.store.crossDeviceProgress) {
      final record = detail.progress;
      if (record != null && record.worthResuming) return record;
      return null;
    }

    // 本地模式：本机记录优先。
    try {
      final own = await widget.client.getProgress(
        detail.path,
        deviceId: widget.store.deviceId,
      );
      if (own != null && own.worthResuming) return own;
    } on PavlApiError {
      // 查不到就当没有记录。
    } on PavlNetworkError {
      // 网络问题同样降级为从头播。
    }
    return null;
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      // 鼠标停在控制层上时不隐藏，避免想点按钮却消失了。
      setState(() => _controlsVisible = false);
    });
  }

  void _showControls() {
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _scheduleHide();
  }

  Future<void> _toggleFullscreen() async {
    _fullscreen = !_fullscreen;
    await windowManager.setFullScreen(_fullscreen);
    if (mounted) setState(() {});
  }

  Future<void> _exit() async {
    if (_fullscreen) {
      await windowManager.setFullScreen(false);
    }
    if (mounted) Navigator.of(context).maybePop();
  }

  /// 键盘快捷键。
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final controller = _controller;
    if (controller == null) return KeyEventResult.ignored;

    switch (event.logicalKey) {
      case LogicalKeyboardKey.space:
        unawaited(controller.togglePlay());
        _showControls();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowLeft:
        unawaited(controller.seek(
          controller.position - const Duration(seconds: 10),
        ));
        _showControls();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowRight:
        unawaited(controller.seek(
          controller.position + const Duration(seconds: 10),
        ));
        _showControls();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        unawaited(controller.setVolume(_controller!.player.state.volume + 5));
        _showControls();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowDown:
        unawaited(controller.setVolume(controller.player.state.volume - 5));
        _showControls();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyF:
        unawaited(_toggleFullscreen());
        return KeyEventResult.handled;
      case LogicalKeyboardKey.escape:
        if (_fullscreen) {
          unawaited(_toggleFullscreen());
        } else {
          unawaited(_exit());
        }
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        autofocus: true,
        onKeyEvent: _onKey,
        child: MouseRegion(
          onHover: (_) => _showControls(),
          child: Stack(
            fit: StackFit.expand,
            children: [
              _videoLayer(),
              // 控制层：用 IgnorePointer 让隐藏时鼠标事件穿透到画面。
              IgnorePointer(
                ignoring: !_controlsVisible,
                child: AnimatedOpacity(
                  opacity: _controlsVisible ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: _controlLayer(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _videoLayer() {
    if (_error != null) return _errorView();
    final controller = _controller;
    if (controller == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return Video(
      controller: controller.videoController,
      controls: NoVideoControls,
      fit: BoxFit.contain,
      // 字幕由 libass 直接画进画面，不需要 Flutter 侧再叠一层。
      subtitleViewConfiguration: const SubtitleViewConfiguration(visible: false),
    );
  }

  Widget _errorView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, size: 44, color: PavlColors.danger),
          const SizedBox(height: 14),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Text(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: PavlColors.textDim, fontSize: 13),
            ),
          ),
          const SizedBox(height: 20),
          OutlinedButton(
            onPressed: _exit,
            child: const Text('返回'),
          ),
        ],
      ),
    );
  }

  Widget _controlLayer() {
    final controller = _controller;
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0xCC000000),
            Color(0x00000000),
            Color(0x00000000),
            Color(0xE6000000),
          ],
          stops: [0.0, 0.22, 0.72, 1.0],
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            _topBar(),
            const Spacer(),
            if (controller != null)
              ControlBar(
                controller: controller,
                fullscreen: _fullscreen,
                onToggleFullscreen: _toggleFullscreen,
                onExit: _exit,
                onSeekStart: () => _hideTimer?.cancel(),
                onSeekEnd: _scheduleHide,
                onOpenTracks: () => _openTrackMenu(controller),
              ),
          ],
        ),
      ),
    );
  }

  Widget _topBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      child: Row(
        children: [
          IconButton(
            onPressed: _exit,
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            tooltip: '返回列表',
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _detail?.title.isNotEmpty == true
                  ? _detail!.title
                  : widget.fallbackTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 16,
                color: Colors.white,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openTrackMenu(PlaybackController controller) async {
    _hideTimer?.cancel();
    await showDialog<void>(
      context: context,
      builder: (_) => TrackMenuDialog(
        controller: controller,
        detail: _detail!,
      ),
    );
    _scheduleHide();
  }
}
