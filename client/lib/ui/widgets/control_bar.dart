/// 播放控制条：进度条、播放暂停、时间、倍速、音量、字幕音轨、全屏。
///
/// 播放页在 [Video] 上显式传 `controls: NoVideoControls`（media_kit_video
/// 自带的常量，值就是 null）来关掉它默认那套自适应控制条 —— 默认控制条风格与
/// 本项目不一致，而且它自己会处理点击显隐，会和播放页的自动隐藏逻辑打架。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../app.dart';
import '../../player/playback_controller.dart';

/// 控制条。
class ControlBar extends StatefulWidget {
  const ControlBar({
    super.key,
    required this.controller,
    required this.fullscreen,
    required this.onToggleFullscreen,
    required this.onExit,
    required this.onSeekStart,
    required this.onSeekEnd,
    required this.onOpenTracks,
  });

  final PlaybackController controller;
  final bool fullscreen;
  final VoidCallback onToggleFullscreen;
  final VoidCallback onExit;

  /// 用户开始拖动进度条，暂停自动隐藏。
  final VoidCallback onSeekStart;

  /// 拖动结束，恢复自动隐藏计时。
  final VoidCallback onSeekEnd;
  final VoidCallback onOpenTracks;

  @override
  State<ControlBar> createState() => _ControlBarState();
}

class _ControlBarState extends State<ControlBar> {
  /// 拖动过程中的临时位置，拖完才真正 seek。
  Duration? _dragging;

  /// 音量面板是否展开。
  bool _volumeOpen = false;

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return StreamBuilder<Duration>(
      stream: controller.player.stream.position,
      builder: (context, _) {
        return StreamBuilder<bool>(
          stream: controller.player.stream.playing,
          builder: (context, playingSnapshot) {
            final playing = playingSnapshot.data ?? false;
            return StreamBuilder<Duration>(
              stream: controller.player.stream.duration,
              builder: (context, durationSnapshot) {
                final duration = durationSnapshot.data ?? Duration.zero;
                final position = _dragging ?? controller.position;
                return Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _progressRow(position, duration),
                      const SizedBox(height: 6),
                      _buttonRow(playing),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  /// 进度条 + 时间。
  Widget _progressRow(Duration position, Duration duration) {
    final total = duration.inMilliseconds.toDouble();
    final current = position.inMilliseconds.toDouble().clamp(0.0, total);
    return Row(
      children: [
        Text(
          formatDuration(position),
          style: const TextStyle(
            fontSize: 12,
            color: Colors.white70,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              activeTrackColor: PavlColors.accent,
              inactiveTrackColor: Colors.white24,
              thumbColor: PavlColors.accent,
            ),
            child: Slider(
              min: 0,
              max: total <= 0 ? 1 : total,
              value: total <= 0 ? 0 : current,
              onChangeStart: (_) => widget.onSeekStart(),
              onChanged: total <= 0
                  ? null
                  : (value) {
                      setState(() {
                        _dragging = Duration(milliseconds: value.round());
                      });
                    },
              onChangeEnd: total <= 0
                  ? null
                  : (value) {
                      final target = Duration(milliseconds: value.round());
                      setState(() => _dragging = null);
                      unawaited(widget.controller.seek(target));
                      widget.onSeekEnd();
                    },
            ),
          ),
        ),
        const SizedBox(width: 12),
        Text(
          formatDuration(duration),
          style: const TextStyle(
            fontSize: 12,
            color: Colors.white70,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }

  /// 按钮行。
  Widget _buttonRow(bool playing) {
    return Row(
      children: [
        _iconButton(
          icon: playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
          size: 30,
          tooltip: playing ? '暂停（空格）' : '播放（空格）',
          onPressed: () => unawaited(widget.controller.togglePlay()),
        ),
        _iconButton(
          icon: Icons.replay_10_rounded,
          tooltip: '后退 10 秒（←）',
          onPressed: () => unawaited(
            widget.controller.seek(
              widget.controller.position - const Duration(seconds: 10),
            ),
          ),
        ),
        _iconButton(
          icon: Icons.forward_10_rounded,
          tooltip: '前进 10 秒（→）',
          onPressed: () => unawaited(
            widget.controller.seek(
              widget.controller.position + const Duration(seconds: 10),
            ),
          ),
        ),
        const Spacer(),
        _rateButton(),
        const SizedBox(width: 4),
        _volumeButton(),
        const SizedBox(width: 4),
        _iconButton(
          icon: Icons.subtitles_outlined,
          tooltip: '字幕与音轨',
          size: 22,
          onPressed: widget.onOpenTracks,
        ),
        const SizedBox(width: 4),
        _iconButton(
          icon: widget.fullscreen
              ? Icons.fullscreen_exit_rounded
              : Icons.fullscreen_rounded,
          tooltip: widget.fullscreen ? '退出全屏（Esc）' : '全屏（F）',
          onPressed: widget.onToggleFullscreen,
        ),
      ],
    );
  }

  /// 倍速按钮，点开是 0.5~2.0 的档位。
  Widget _rateButton() {
    return StreamBuilder<double>(
      stream: widget.controller.player.stream.rate,
      // 这条流只在倍速变化时推事件。弹出菜单每次打开都会重新订阅，
      // 拿不到历史值就会落回 1.0，显示与真实倍速脱节。
      initialData: widget.controller.player.state.rate,
      builder: (context, snapshot) {
        final rate = snapshot.data ?? 1.0;
        return PopupMenuButton<double>(
          tooltip: '播放速度',
          initialValue: rate,
          onSelected: (value) => unawaited(widget.controller.setRate(value)),
          itemBuilder: (_) => const [
            PopupMenuItem(value: 0.5, child: Text('0.5x')),
            PopupMenuItem(value: 0.75, child: Text('0.75x')),
            PopupMenuItem(value: 1.0, child: Text('1.0x  正常')),
            PopupMenuItem(value: 1.25, child: Text('1.25x')),
            PopupMenuItem(value: 1.5, child: Text('1.5x')),
            PopupMenuItem(value: 1.75, child: Text('1.75x')),
            PopupMenuItem(value: 2.0, child: Text('2.0x')),
          ],
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white10,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              '${rate.toStringAsFixed(rate == rate.roundToDouble() ? 1 : 2)}x',
              style: const TextStyle(
                fontSize: 12,
                color: Colors.white,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        );
      },
    );
  }

  /// 音量：点开是一个竖向滑条。
  Widget _volumeButton() {
    return PopupMenuButton<void>(
      tooltip: '音量',
      onOpened: () => setState(() => _volumeOpen = true),
      onCanceled: () => setState(() => _volumeOpen = false),
      onSelected: (_) => setState(() => _volumeOpen = false),
      itemBuilder: (_) => [
        PopupMenuItem<void>(
          enabled: false,
          height: 140,
          child: _volumeSlider(),
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Icon(
          _volumeOpen ? Icons.volume_up : Icons.volume_up_outlined,
          size: 22,
          color: Colors.white,
        ),
      ),
    );
  }

  Widget _volumeSlider() {
    return SizedBox(
      width: 200,
      child: StreamBuilder<double>(
        stream: widget.controller.player.stream.volume,
        // 同上：广播流不重放历史值。不塞初值的话，每次点开音量面板都会
        // 显示成 100，用户以为音量被重置了，其实只是没读到当前值。
        initialData: widget.controller.player.state.volume,
        builder: (context, snapshot) {
          final volume = snapshot.data ?? 100;
          return Row(
            children: [
              const Icon(Icons.volume_mute, size: 18, color: Colors.white70),
              Expanded(
                child: Slider(
                  value: volume.clamp(0, 100),
                  max: 100,
                  onChanged: (value) =>
                      unawaited(widget.controller.setVolume(value)),
                ),
              ),
              SizedBox(
                width: 32,
                child: Text(
                  volume.round().toString(),
                  style: const TextStyle(fontSize: 12, color: Colors.white70),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _iconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
    double size = 24,
  }) {
    return IconButton(
      tooltip: tooltip,
      iconSize: size,
      color: Colors.white,
      onPressed: onPressed,
      icon: Icon(icon),
    );
  }
}

/// 把时长格式化成 `mm:ss` 或 `h:mm:ss`。
String formatDuration(Duration d) {
  final total = d.inSeconds;
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final seconds = total % 60;
  final mm = minutes.toString().padLeft(2, '0');
  final ss = seconds.toString().padLeft(2, '0');
  if (hours > 0) return '$hours:$mm:$ss';
  return '$mm:$ss';
}
