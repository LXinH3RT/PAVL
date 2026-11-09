/// 播放偏好（音轨、字幕）的存取。
///
/// 存在哪一侧由服务端的存储形态决定：
///
///   - 便携版服务端：偏好存在客户端本地 `client.json`。便携版的程序文件夹
///     可能被整个拷给别人，把偏好存在那边等于把甲的选择带给乙。
///   - 安装版服务端：偏好存在服务端 `prefs.json`，按设备 id 隔离。换一台
///     机器看同一部片，各记各的，不跨设备同步。
///
/// 两种情况都保留一份本地副本：服务端拉取失败时用它顶上，至少不会因为一次
/// 网络抖动就丢掉用户刚选好的音轨。
library;

import 'package:media_kit/media_kit.dart';

import '../api/pavl_client.dart';
import '../store/app_store.dart';
import '../util/app_log.dart';

/// 语言标签归一化。
///
/// 同一个语言在不同容器里可能是 `zh`、`chi`、`zho`、`Chinese`，直接比字符串
/// 会认不出来。这里只处理常见的几种，认不出的原样返回——宁可比不出来，
/// 也不要错误地把两种语言当成一种。
String normalizeLanguage(String? raw) {
  final value = raw?.trim().toLowerCase();
  if (value == null || value.isEmpty) return '';
  const aliases = <String, String>{
    'zh': 'zho',
    'chi': 'zho',
    'zho': 'zho',
    'chinese': 'zho',
    '中文': 'zho',
    '汉语': 'zho',
    'cmn': 'zho',
    'zh-cn': 'zho',
    'zh-tw': 'zho',
    'zh-hk': 'zho',
    'zh-hans': 'zho',
    'zh-hant': 'zho',
    'yue': 'yue',
    'cantonese': 'yue',
    '粤语': 'yue',
    'en': 'eng',
    'eng': 'eng',
    'english': 'eng',
    '英语': 'eng',
    'ja': 'jpn',
    'jpn': 'jpn',
    'japanese': 'jpn',
    '日语': 'jpn',
    'ko': 'kor',
    'kor': 'kor',
    'korean': 'kor',
    '韩语': 'kor',
    'fr': 'fra',
    'fre': 'fra',
    'fra': 'fra',
    'french': 'fra',
    'de': 'deu',
    'ger': 'deu',
    'deu': 'deu',
    'es': 'spa',
    'spa': 'spa',
    'ru': 'rus',
    'rus': 'rus',
    'th': 'tha',
    'tha': 'tha',
  };
  return aliases[value] ?? value;
}

/// 在给定轨道里找出最符合偏好的一条。
///
/// 匹配顺序是有意设计的：id 是首选但最不稳，转个封装或换一集就可能变；
/// 语言次之，标题最后。宁可退到「同语言的第一条」，也比完全忽略用户的
/// 选择要好——用户上次选了国语，这一集多半也想听国语。
T? pickTrack<T>(
  List<T> tracks, {
  required String? preferredId,
  required String? preferredLang,
  required String? preferredTitle,
  required String Function(T) idOf,
  required String? Function(T) langOf,
  required String? Function(T) titleOf,
  required bool? Function(T) isDefaultOf,
}) {
  if (preferredId != null && preferredId.isNotEmpty) {
    for (final track in tracks) {
      if (idOf(track) == preferredId) return track;
    }
  }

  final wantLang = normalizeLanguage(preferredLang);
  final wantTitle = preferredTitle?.trim().toLowerCase() ?? '';

  bool sameLang(T track) =>
      wantLang.isNotEmpty && normalizeLanguage(langOf(track)) == wantLang;
  bool sameTitle(T track) =>
      wantTitle.isNotEmpty &&
      (titleOf(track)?.trim().toLowerCase() ?? '') == wantTitle;

  // 语言和标题都对上，这条几乎必然是同一路轨。
  if (wantLang.isNotEmpty || wantTitle.isNotEmpty) {
    for (final track in tracks) {
      if (sameLang(track) && sameTitle(track)) return track;
    }
    // 只有语言能对上时，优先带 default 标记的那条。
    final byLang = tracks.where(sameLang).toList();
    if (byLang.isNotEmpty) {
      for (final track in byLang) {
        if (isDefaultOf(track) ?? false) return track;
      }
      return byLang.first;
    }
    if (wantTitle.isNotEmpty) {
      for (final track in tracks) {
        if (sameTitle(track)) return track;
      }
    }
  }
  return null;
}

/// 一部片当前选中的轨道，用来写进偏好。
TrackPreference describeTracks({
  AudioTrack? audio,
  SubtitleTrack? subtitle,
  String? subtitlePath,
}) {
  final subtitleId = subtitlePath != null
      ? null
      : (subtitle == null ? 'no' : subtitle.id);
  return TrackPreference(
    audioId: audio?.id,
    audioLang: audio?.language,
    audioTitle: audio?.title,
    subtitleId: subtitleId,
    subtitleLang: subtitle?.language,
    subtitleTitle: subtitle?.title,
    subtitlePath: subtitlePath,
  );
}

/// 播放偏好的读写入口。
///
/// 界面拿它当唯一入口，不直接碰 [AppStore] 或 [PavlClient]——「存在哪一侧」
/// 这件事必须只在一个地方判断，否则迟早出现「设置里说存服务端、实际写了本地」
/// 这类对不上的情况。
class TrackPrefs {
  TrackPrefs({required this.client, required this.store});

  final PavlClient client;
  final AppStore store;

  /// 服务端全量偏好的一次性缓存。进片库时拉一次，之后每集都查内存。
  Map<String, TrackPreference>? _cache;
  bool _loaded = false;

  /// 偏好是否由服务端保管。
  bool get remote => client.connection.serverStoresPrefs;

  String get _serverId => client.connection.serverId;

  /// 读一部片的偏好。
  Future<TrackPreference?> get(String path) async {
    if (!remote) return store.trackPreference(_serverId, path);
    await _ensureLoaded();
    final remotePref = _cache?[path];
    if (remotePref != null) return remotePref;
    // 服务端没有这条记录，或者这次请求失败了：用本地副本顶上。
    return store.trackPreference(_serverId, path);
  }

  /// 写一部片的偏好。
  Future<void> put(String path, TrackPreference pref) async {
    // 本地永远留一份，读服务端失败时它兜底。
    await store.setTrackPreference(_serverId, path, pref);
    if (!remote) return;
    _cache?[path] = pref;
    try {
      await client.putTrackPrefs(path, pref);
    } catch (error) {
      // 写不进服务端不该影响播放，记一行日志就够了。
      logLine('prefs', '上传偏好失败：$error');
    }
  }

  /// 已记住的偏好条数。
  Future<int> count() async {
    if (!remote) return store.trackPreferenceCount(_serverId);
    await _ensureLoaded();
    // 拉不到服务端的就报本地那份：宁少不多，别把「读取失败」显示成「0 条」。
    final cache = _cache;
    if (cache == null) return store.trackPreferenceCount(_serverId);
    return cache.length;
  }

  /// 清空这台设备的偏好，返回清掉的条数。
  Future<int> clear() async {
    final local = await store.clearTrackPreferences(_serverId);
    if (!remote) return local;
    _cache = {};
    _loaded = true;
    try {
      return await client.clearTrackPrefs();
    } catch (error) {
      logLine('prefs', '清空服务端偏好失败：$error');
      return local;
    }
  }

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      _cache = await client.allTrackPrefs();
    } catch (error) {
      // 下次再试，这次先让本地副本兜底。
      _loaded = false;
      logLine('prefs', '拉取服务端偏好失败：$error');
    }
  }
}
