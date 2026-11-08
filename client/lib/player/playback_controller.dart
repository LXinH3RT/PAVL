/// 播放器封装。
///
/// 把 media_kit 的 [Player] 包一层，职责是：
///   - 管理生命周期（创建、销毁）
///   - 播放进度节流上报（默认 15 秒一次，暂停/退出时立刻上报）
///   - 提供音轨字幕轨的选择与记忆
///   - 回写媒体信息（时长、分辨率、编码）到服务端，避免服务端依赖 ffprobe
library;

import 'dart:async';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../api/pavl_client.dart';
import '../store/app_store.dart';

/// 播放器封装。
class PlaybackController {
  PlaybackController({
    required this.client,
    required this.store,
    required this.mediaDetail,
  }) {
    _init();
  }

  final PavlClient client;
  final AppStore store;
  final MediaDetail mediaDetail;

  late final Player _player = Player(
    configuration: const PlayerConfiguration(
      // 局域网直连，不需要额外缓冲。过大的 cache 反而让 seek 变慢。
      bufferSize: 32 * 1024 * 1024,
      // 关键：默认 false 时字幕由 Flutter widget 渲染，只能显示纯文本，
      // ASS 的定位、字号、颜色、特效全部丢失。改成 true 走 libass 在
      // 解码侧直接绘制进画面，与 mpv/VLC 的观感一致。
      libass: true,
      // 只允许必要的协议，减少被恶意文件触发的风险面。
      protocolWhitelist: ['file', 'http', 'https', 'tcp', 'tls', 'crypto', 'data'],
    ),
  );

  late final VideoController videoController = VideoController(_player);

  Player get player => _player;

  /// 上报进度的定时器。
  Timer? _reportTimer;

  /// 上一次上报的位置，避免重复上报同一个值。
  double _lastReported = -1;

  /// 是否已经回写过媒体信息。
  bool _metaReported = false;

  /// 是否已经播放到结尾。
  ///
  /// 一旦置真就不再回落：播放结束时会先上报 `finished: true`，随后用户退回
  /// 列表触发 [dispose] 的强制上报，那次调用默认 `finished: false`，如果不
  /// 记住这个状态就会把「已看完」改回「没看完」。
  bool _finished = false;

  /// 当前播放位置，界面上直接读。
  Duration position = Duration.zero;
  Duration duration = Duration.zero;

  /// 最后一次拿到的非空轨道列表。
  ///
  /// libmpv 在 `keep-open=yes` 下播完会把 track-list 清成只有 auto/no 两条
  /// 伪轨道，此时 [Player.state] 里已经查不到真实的音轨与字幕轨。用户常在
  /// 播完后才想切换轨道，所以要留一份快照。
  Tracks _lastTracks = const Tracks();

  /// 可用的轨道列表；播放结束后回落到上一次的快照。
  Tracks get tracks {
    final live = _player.state.tracks;
    if (live.audio.length > 2 || live.subtitle.length > 2) return live;
    return _lastTracks;
  }

  /// 播放器事件订阅，销毁时统一取消。
  final List<StreamSubscription<dynamic>> _subscriptions = [];

  /// 播放结束回调。
  final _completedController = StreamController<void>.broadcast();
  Stream<void> get onCompleted => _completedController.stream;

  /// 出错回调。
  final _errorController = StreamController<String>.broadcast();
  Stream<String> get onError => _errorController.stream;

  void _init() {
    _subscriptions.add(_player.stream.position.listen((value) {
      position = value;
    }));
    _subscriptions.add(_player.stream.duration.listen((value) {
      duration = value;
    }));
    _subscriptions.add(_player.stream.tracks.listen((value) {
      // libmpv 在文件播放结束（keep-open）后会把 track-list 清空，之后再问
      // 就没有音轨了。用户往往正是播完之后才想换音轨/字幕，所以记住最后一次
      // 非空的轨道列表，供界面对话框回退使用。
      if (value.audio.length > 2 || value.subtitle.length > 2) {
        _lastTracks = value;
      }
    }));
    _subscriptions.add(_player.stream.completed.listen((completed) {
      if (completed) {
        unawaited(_onPlaybackCompleted());
      }
    }));
    _subscriptions.add(_player.stream.error.listen((message) {
      _errorController.add(message);
    }));

    // 每 15 秒上报一次进度。太频繁会让服务端频繁写盘，太稀疏会在崩溃时丢进度。
    _reportTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      unawaited(_reportProgress());
    });
  }

  /// 打开媒体并从头或指定位置开始播放。
  Future<void> open({Duration? startAt}) async {
    final uri = client.streamUri(mediaDetail.path);
    await _player.open(
      Media(
        uri.toString(),
        httpHeaders: client.mediaHeaders,
      ),
      play: true,
    );

    if (startAt != null && startAt > Duration.zero) {
      await _player.seek(startAt);
    }

    // 恢复上次的音轨字幕选择。
    //
    // 不 await：切轨会让解码器重开一次，如果在 open 之后立刻切，画面会卡在
    // 黑屏（位置停在 0 不动）。让播放先真正跑起来再切。
    unawaited(_restoreTrackPreference());
  }

  /// 等到播放真正开始（有时长且轨道已就绪）。
  ///
  /// `Player.open()` 返回时只代表命令已经下发，libmpv 还没扫描出 track-list，
  /// 此时按 id 匹配轨道必然落空；而太早切轨又会把解码卡住。这里等到
  /// `duration > 0` 说明解封装已经完成，再动手切换。
  Future<Tracks> _waitForTracks(Duration timeout) async {
    final started = _player.state.duration > Duration.zero;
    if (started) return _player.state.tracks;

    final completer = Completer<void>();
    late final StreamSubscription<Duration> sub;
    late final Timer timer;
    sub = _player.stream.duration.listen((value) {
      if (!completer.isCompleted && value > Duration.zero) {
        completer.complete();
      }
    });
    timer = Timer(timeout, () {
      if (!completer.isCompleted) completer.complete();
    });
    try {
      await completer.future;
    } finally {
      await sub.cancel();
      timer.cancel();
    }

    // 再等一下轨道列表，个别文件时长先到、轨道后到。
    var tracks = _player.state.tracks;
    for (var i = 0; i < 20; i++) {
      if (tracks.audio.length > 2 || tracks.subtitle.length > 2) break;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      tracks = _player.state.tracks;
    }
    return tracks;
  }

  /// 恢复音轨与字幕选择。
  Future<void> _restoreTrackPreference() async {
    final pref = store.trackPreference(client.connection.serverId, mediaDetail.path);
    if (pref == null) return;

    // 等 libmpv 把轨道扫出来，否则下面的按 id 匹配一定落空。
    final tracks = await _waitForTracks(const Duration(seconds: 6));

    // 音轨。
    if (pref.audioId != null) {
      for (final track in tracks.audio) {
        if (track.id == pref.audioId) {
          await _player.setAudioTrack(track);
          break;
        }
      }
    }

    // 外挂字幕优先。
    if (pref.subtitlePath != null && pref.subtitlePath!.isNotEmpty) {
      await _loadExternalSubtitle(pref.subtitlePath!);
      return;
    }
    if (pref.subtitleId != null) {
      if (pref.subtitleId == 'no') {
        await _player.setSubtitleTrack(SubtitleTrack.no());
      } else {
        for (final track in tracks.subtitle) {
          if (track.id == pref.subtitleId) {
            await _player.setSubtitleTrack(track);
            break;
          }
        }
      }
    }
  }

  /// 挂载外挂字幕。
  Future<void> _loadExternalSubtitle(String path) async {
    final uri = client.subtitleUri(path);
    await _player.setSubtitleTrack(
      SubtitleTrack.uri(uri.toString()),
    );
  }

  /// 切换字幕轨。
  ///
  /// [track] 为 null 时关闭字幕。会记到本地偏好里，下次打开同一部片自动恢复。
  Future<void> selectSubtitle(SubtitleTrack? track, {String? sidecarPath}) async {
    await _player.setSubtitleTrack(track ?? SubtitleTrack.no());
    await store.setTrackPreference(
      client.connection.serverId,
      mediaDetail.path,
      TrackPreference(
        audioId: _player.state.track.audio.id,
        subtitleId: track?.id ?? 'no',
        subtitlePath: sidecarPath,
      ),
    );
  }

  /// 切换音轨。
  Future<void> selectAudio(AudioTrack track) async {
    await _player.setAudioTrack(track);
    final existing =
        store.trackPreference(client.connection.serverId, mediaDetail.path);
    await store.setTrackPreference(
      client.connection.serverId,
      mediaDetail.path,
      TrackPreference(
        audioId: track.id,
        subtitleId: existing?.subtitleId,
        subtitlePath: existing?.subtitlePath,
      ),
    );
  }

  /// 设置倍速。0.5~2.0。
  Future<void> setRate(double rate) =>
      _player.setRate(rate.clamp(0.5, 2.0));

  Future<void> play() => _player.play();
  Future<void> pause() => _player.pause();
  Future<void> togglePlay() => _player.playOrPause();
  Future<void> seek(Duration to) => _player.seek(to);
  Future<void> setVolume(double volume) => _player.setVolume(volume.clamp(0, 100));

  /// 播放结束：上报完成状态，并回写媒体信息。
  Future<void> _onPlaybackCompleted() async {
    // mpv 在 keep-open=yes 下会把 position 归零，直接用 0 上报会让记录看起来
    // 像是「从头开始看了一会儿」。既然已经确认播到结尾，就按总时长记账。
    if (duration > Duration.zero) {
      position = duration;
    }
    await _reportProgress(force: true, finished: true);
    _completedController.add(null);
  }

  /// 上报进度。位置没变就跳过，除非 [force]。
  Future<void> _reportProgress({bool force = false, bool finished = false}) async {
    final pos = position.inMilliseconds / 1000.0;
    final dur = duration.inMilliseconds / 1000.0;
    if (dur <= 0) return;
    // 播放过结尾是终态，后续的定时上报和退出上报都不能把它改回去。
    if (finished) _finished = true;
    // 刚打开就退出（或打开后没真正播起来）时位置还是 0，这时上报会把
    // 之前记下的进度冲掉，让用户下次从头开始。宁可不报也不能倒着写。
    if (pos < 1.0 && !_finished) return;
    if (!force && (pos - _lastReported).abs() < 1.0) return;
    _lastReported = pos;

    try {
      await client.putProgress(
        path: mediaDetail.path,
        position: pos,
        duration: dur,
        finished: _finished,
      );
      await _reportMetaIfNeeded();
    } on PavlApiError {
      // 进度上报失败不该打断播放，静默忽略。
    } on PavlNetworkError {
      // 网络抖动同理。
    }
  }

  /// 首次拿到时长后，把媒体信息回写给服务端。
  ///
  /// 服务端不装 ffprobe，这些信息只能由真正解码过文件的客户端提供。
  Future<void> _reportMetaIfNeeded() async {
    if (_metaReported) return;
    final state = _player.state;
    final video = state.tracks.video;
    if (video.isEmpty) return;
    final track = video.first;
    final meta = <String, Object?>{};
    if (state.duration > Duration.zero) {
      meta['duration'] = state.duration.inMilliseconds / 1000.0;
    }
    if (track.w != null) meta['width'] = track.w;
    if (track.h != null) meta['height'] = track.h;
    if (track.codec != null) meta['videoCodec'] = track.codec;
    if (track.fps != null) meta['fps'] = track.fps;
    final audio = state.tracks.audio;
    if (audio.isNotEmpty) {
      final a = audio.first;
      if (a.codec != null) meta['audioCodec'] = a.codec;
      if (a.channelscount != null) meta['audioChannels'] = a.channelscount;
    }
    if (meta.isEmpty) return;
    _metaReported = true;
    try {
      await client.putMeta(mediaDetail.path, meta);
    } on PavlApiError {
      _metaReported = false;
    } on PavlNetworkError {
      _metaReported = false;
    }
  }

  /// 退出前调用：停止定时器、最后一次上报、释放播放器。
  Future<void> dispose() async {
    _reportTimer?.cancel();
    _reportTimer = null;
    await _reportProgress(force: true);
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();
    await _completedController.close();
    await _errorController.close();
    await _player.dispose();
  }
}

/// 可用轨道列表的快照，供 UI 构建菜单。
class TrackOptions {
  TrackOptions({required this.audio, required this.subtitle});

  final List<AudioTrack> audio;
  final List<SubtitleTrack> subtitle;
}
