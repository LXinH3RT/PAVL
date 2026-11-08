/// 字幕与音轨选择面板。
///
/// 左右两栏：左边音轨，右边字幕。选择立即生效并记到本地偏好，
/// 下次打开同一部片自动恢复。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import '../../api/pavl_client.dart';
import '../../app.dart';
import '../../player/playback_controller.dart';

/// 字幕音轨面板。
class TrackMenuDialog extends StatefulWidget {
  const TrackMenuDialog({
    super.key,
    required this.controller,
    required this.detail,
  });

  final PlaybackController controller;
  final MediaDetail detail;

  @override
  State<TrackMenuDialog> createState() => _TrackMenuDialogState();
}

class _TrackMenuDialogState extends State<TrackMenuDialog> {
  Tracks _tracks = const Tracks();
  Track _current = const Track();

  StreamSubscription<Tracks>? _tracksSub;
  StreamSubscription<Track>? _trackSub;

  @override
  void initState() {
    super.initState();
    final player = widget.controller.player;
    // 用控制器的 tracks getter 而不是 player.state.tracks：播放结束后
    // libmpv 会清空轨道列表，控制器保留了一份快照。
    _tracks = widget.controller.tracks;
    _current = player.state.track;
    _tracksSub = player.stream.tracks.listen((tracks) {
      if (!mounted) return;
      // 播放结束时的空列表不覆盖界面上的快照，否则对话框会突然变空。
      if (tracks.audio.length <= 2 && tracks.subtitle.length <= 2) return;
      setState(() => _tracks = tracks);
    });
    _trackSub = player.stream.track.listen((track) {
      if (!mounted) return;
      setState(() => _current = track);
    });
  }

  @override
  void dispose() {
    _tracksSub?.cancel();
    _trackSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: PavlColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: SizedBox(
        width: 720,
        height: 460,
        child: Column(
          children: [
            _header(),
            const Divider(height: 1, color: PavlColors.border),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: _audioColumn()),
                  const VerticalDivider(width: 1, color: PavlColors.border),
                  Expanded(child: _subtitleColumn()),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 16),
      child: Row(
        children: [
          const Icon(Icons.tune, size: 18, color: PavlColors.textDim),
          const SizedBox(width: 10),
          const Text('音轨与字幕', style: TextStyle(fontSize: 16)),
          const Spacer(),
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close, size: 20),
            tooltip: '关闭',
          ),
        ],
      ),
    );
  }

  /// 真正的可选音轨。
  ///
  /// libmpv 会在列表最前面塞两条伪轨道 `auto` 和 `no`，它们不是文件里
  /// 真实存在的轨，如果不过滤，用户会看到「音轨 1 / 音轨 2」这种空条目
  /// 排在真正的「中文音轨 / English」前面。
  List<AudioTrack> get _realAudio =>
      _tracks.audio.where((t) => t.id != 'auto' && t.id != 'no').toList();

  /// 真正的内嵌字幕轨，同样过滤掉 auto / no。
  ///
  /// 「关闭字幕」由 UI 自己提供一行，不依赖伪轨道。
  List<SubtitleTrack> get _realSubtitle => _tracks.subtitle
      .where((t) => t.id != 'auto' && t.id != 'no')
      .toList();

  Widget _audioColumn() {
    final audio = _realAudio;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _columnTitle('音轨'),
        Expanded(
          child: audio.isEmpty
              ? _empty('这个文件没有可选音轨')
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  itemCount: audio.length,
                  itemBuilder: (_, index) {
                    final track = audio[index];
                    return _trackRow(
                      selected: _current.audio.id == track.id,
                      title: _trackLabel(track, index, '音轨'),
                      subtitle: _trackDetail(track),
                      onTap: () async {
                        await widget.controller.selectAudio(track);
                        if (mounted) setState(() {});
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _subtitleColumn() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _columnTitle('字幕'),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            children: [
              _trackRow(
                selected: _current.subtitle.id == 'no',
                title: '关闭字幕',
                onTap: () async {
                  await widget.controller.selectSubtitle(null);
                  if (mounted) setState(() {});
                },
              ),
              // 内嵌字幕轨。
              ..._realSubtitle.asMap().entries.map((entry) {
                final index = entry.key;
                final track = entry.value;
                return _trackRow(
                  selected: _current.subtitle.id == track.id,
                  title: _trackLabel(track, index, '字幕'),
                  subtitle: _trackDetail(track),
                  onTap: () async {
                    await widget.controller.selectSubtitle(track);
                    if (mounted) setState(() {});
                  },
                );
              }),
              // 外挂字幕：单独一节，和内部的风格区分开。
              if (widget.detail.subtitles.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 16, 12, 6),
                  child: Text(
                    widget.detail.subtitles.every((sub) => sub.sibling)
                        ? '外挂字幕（同目录，未按文件名匹配）'
                        : '外挂字幕',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: PavlColors.textDim,
                      letterSpacing: 0.8,
                    ),
                  ),
                ),
                ...widget.detail.subtitles.map(
                  (sub) => _trackRow(
                    selected: _current.subtitle.id ==
                        widget.controller.client
                            .subtitleUri(sub.path)
                            .toString(),
                    title: sub.name,
                    subtitle: _readableSize(sub.size),
                    onTap: () async {
                      await widget.controller.selectSubtitle(
                        SubtitleTrack.uri(
                          widget.controller.client
                              .subtitleUri(sub.path)
                              .toString(),
                        ),
                        sidecarPath: sub.path,
                      );
                      if (mounted) setState(() {});
                    },
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _columnTitle(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: PavlColors.textDim,
            letterSpacing: 0.8,
          ),
        ),
      );

  Widget _empty(String text) => Center(
        child: Text(
          text,
          style: const TextStyle(fontSize: 12, color: PavlColors.textDim),
        ),
      );

  Widget _trackRow({
    required bool selected,
    required String title,
    String? subtitle,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: selected ? PavlColors.accentDim.withValues(alpha: 0.35) : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 16,
                  color: selected ? PavlColors.accent : PavlColors.textDim,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight:
                              selected ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                      if (subtitle != null && subtitle.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11,
                            color: PavlColors.textDim,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 轨道标题。优先用文件里写的 title，没有就用语言 + 序号。
  String _trackLabel(dynamic track, int index, String kind) {
    final title = track.title as String?;
    if (title != null && title.isNotEmpty) return title;
    final language = track.language as String?;
    if (language != null && language.isNotEmpty && language != 'und') {
      return '$kind ${index + 1}（$language）';
    }
    return '$kind ${index + 1}';
  }

  /// 轨道细节：编码、声道、分辨率等，能读到什么写什么。
  String _trackDetail(dynamic track) {
    final parts = <String>[];
    final codec = track.codec as String?;
    if (codec != null && codec.isNotEmpty) parts.add(codec);
    final channels = track.channels as String?;
    if (channels != null && channels.isNotEmpty) {
      parts.add(channels);
    } else if (track.channelscount != null) {
      parts.add('${track.channelscount} 声道');
    }
    if (track.w != null && track.h != null) {
      parts.add('${track.w}×${track.h}');
    }
    if (track.bitrate != null && (track.bitrate as int) > 0) {
      parts.add('${((track.bitrate as int) / 1000).round()} kbps');
    }
    return parts.join('  ·  ');
  }

  static String _readableSize(int bytes) {
    if (bytes <= 0) return '';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / 1048576).toStringAsFixed(1)} MB';
  }
}
