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
import '../util/app_log.dart';

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
      // 默认只收 error 级。拉流失败时 libmpv 往往先在 warn/info 里说清原因
      // （HTTP 状态码、解封装失败），单靠 error 级几乎抓不到现场。
      logLevel: MPVLogLevel.info,
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

  /// 是否已经销毁。异步的监视任务用它提前退出，避免碰已释放的播放器。
  bool _disposed = false;

  /// 渲染/解码侧的失败原因，由日志流捕获，供超时提示使用。
  String? _renderError;

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
      logLine('mpv', 'error: $message');
      _errorController.add(message);
    }));

    // libmpv 的原始日志。级别提到 info 后，拉流失败的原因（HTTP 状态码、
    // 解封装错误、解码器初始化失败）都会出现在这里；单靠 stream.error
    // 抓不到——media_kit 只转发少量的 error 前缀。
    _subscriptions.add(_player.stream.log.listen((entry) {
      if (entry.level != 'error' && entry.level != 'warn') return;
      logLine('mpv', '${entry.level}/${entry.prefix}: ${entry.text}');

      // 渲染侧的错误不走 media_kit 的转发白名单（file/ffmpeg/vd/ad/cplayer
      // /stream 之外的都被丢掉），用户只能看到黑屏。单独记下来，超时提示
      // 里带上，至少能判断是解码失败还是画不出来。
      if (entry.prefix.startsWith('libmpv_render') ||
          entry.text.contains('EGL surface') ||
          entry.text.contains('Failed to create')) {
        _renderError ??= entry.text;
      }
    }));

    logLine('play', '打开 ${mediaDetail.path}（${mediaDetail.title}）');

    // 每 15 秒上报一次进度。太频繁会让服务端频繁写盘，太稀疏会在崩溃时丢进度。
    _reportTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      unawaited(_reportProgress());
    });
  }

  /// 打开媒体并从头或指定位置开始播放。
  Future<void> open({Duration? startAt}) async {
    final uri = client.streamUri(mediaDetail.path);
    logLine('play', '拉流 ${redactUri(uri)} 起点=$startAt');
    final stopwatch = Stopwatch()..start();
    try {
      await _player.open(
        Media(
          uri.toString(),
          httpHeaders: client.mediaHeaders,
        ),
        play: true,
      );
    } catch (error) {
      logLine('play', 'open 失败：$error');
      rethrow;
    }

    if (startAt != null && startAt > Duration.zero) {
      await _player.seek(startAt);
    }

    // 恢复上次的音轨字幕选择。
    //
    // 不 await：切轨会让解码器重开一次，如果在 open 之后立刻切，画面会卡在
    // 黑屏（位置停在 0 不动）。让播放先真正跑起来再切。
    unawaited(_restoreTrackPreference());

    // 10 秒还拿不到时长，说明解封装没有完成。此时画面是全黑的，用户除了
    // 「打不开」什么也说不出，直接把现场写进日志，并把提示送到界面。
    unawaited(_watchFirstFrame(stopwatch));
  }

  /// 超时监视：解封装成功后，再确认视频帧是否真的解码出来了。
  ///
  /// 与之相对，[VideoParams] 在一帧解出来之前是空的。显卡驱动异常时，
  /// 时长与轨道都正常，画面却一直是黑的——这种情况用户完全说不出原因，
  /// 只能靠这里的判定把话讲清楚。
  Future<void> _watchFirstPicture(Stopwatch stopwatch) async {
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (_disposed) return;
      final params = _player.state.videoParams;
      if (params.w != null && params.w! > 0) {
        logLine(
          'play',
          '首帧就绪，用时 ${stopwatch.elapsedMilliseconds} ms，'
              '${params.w}x${params.h} ${params.pixelformat ?? ''}',
        );
        return;
      }
    }
    if (_disposed) return;
    final render = _renderError;
    logLine(
      'play',
      '解封装成功但 10 秒内没有解出画面'
          '${render == null ? '' : '（$render）'}',
    );
    _errorController.add(
      render == null
          ? '视频已读取，但画面始终没有出来。这通常是显卡驱动或渲染初始化的问题，'
              '详细原因已写入日志。'
          : '视频已读取，但画面渲染失败：「$render」。'
              '这通常是显卡驱动或硬件解码的问题，详细原因已写入日志。',
    );
  }

  /// 超时监视：确认 libmpv 是否真的开始了解封装。
  ///
  /// 判超时不能只看时间：局域网慢或文件很大时，libmpv 会先缓冲一段再解析，
  /// 固定 10 秒会把「还在加载」误判成「加载失败」。这里先等 10 秒，若期间
  /// 观察到任何进展（有缓冲、位置在走、状态是播放中），就宽限到 30 秒。
  Future<void> _watchFirstFrame(Stopwatch stopwatch) async {
    const softTimeout = Duration(seconds: 10);
    const hardTimeout = Duration(seconds: 30);
    var waited = Duration.zero;
    var extended = false;

    while (waited < hardTimeout) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      waited += const Duration(milliseconds: 250);
      if (_disposed) return;

      final state = _player.state;
      if (state.duration > Duration.zero) {
        logLine(
          'play',
          '解封装完成，用时 ${stopwatch.elapsedMilliseconds} ms，'
              '时长 ${state.duration}，'
              '视频轨 ${state.tracks.video.length}，'
              '音频轨 ${state.tracks.audio.length}',
        );
        // 解封装成功不等于画得出来：显卡侧创建渲染表面失败时，时长、轨道
        // 都正常，画面却始终是黑的。再等一小会儿看视频参数有没有填上。
        unawaited(_watchFirstPicture(stopwatch));
        return;
      }

      // 缓冲位置在推进才是真的「还在加载」；playing 在命令下发就是真，
      // 用它当进度会退化成无条件放宽到 30 秒。缓冲位置在推进说明数据
      // 确实在进来，把时限放宽，避免慢速网络被当成故障。
      if (!extended && waited >= softTimeout && state.buffer > Duration.zero) {
        extended = true;
        logLine(
          'play',
          '10 秒内还没解析出时长，但数据仍在进来'
              '（已缓冲 ${state.buffer}，缓冲中=${state.buffering}），'
              '继续等到 30 秒',
        );
      }
      if (!extended && waited >= softTimeout) break;
    }

    if (_disposed) return;
    final state = _player.state;
    final detail = '时长=${state.duration} / 缓冲=${state.buffer} / '
        '播放中=${state.playing} / 缓冲中=${state.buffering}';
    logLine('play', '${waited.inSeconds} 秒内未拿到时长，放弃等待（$detail）');
    final render = _renderError;
    _errorController.add(
      render == null
          ? '无法开始播放：服务端在 ${waited.inSeconds} 秒内没有返回可解析的媒体数据。'
              '请确认服务端仍在运行、防火墙没有拦住端口，'
              '详细原因已写入日志。'
          : '无法开始播放：解码器报告「$render」。'
              '这通常是显卡驱动或硬件解码初始化失败，'
              '详细原因已写入日志。',
    );
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
    _disposed = true;
    logLine('play', '关闭播放器，停在 $position / $duration');
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
