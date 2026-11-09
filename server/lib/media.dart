/// 媒体文件类型判定与文件名解析。
///
/// 这一层不读取视频内容，只看扩展名与文件名——服务端刻意不依赖 ffmpeg。
library;

/// 媒体种类。
enum MediaKind { video, audio, subtitle, image, other }

/// 扩展名 → 种类。全部小写，不含点。
const Map<String, MediaKind> _extensions = {
  // 视频容器
  'mkv': MediaKind.video,
  'mp4': MediaKind.video,
  'm4v': MediaKind.video,
  'mov': MediaKind.video,
  'avi': MediaKind.video,
  'wmv': MediaKind.video,
  'flv': MediaKind.video,
  'webm': MediaKind.video,
  'ts': MediaKind.video,
  'm2ts': MediaKind.video,
  'mpg': MediaKind.video,
  'mpeg': MediaKind.video,
  'rmvb': MediaKind.video,
  'rm': MediaKind.video,
  '3gp': MediaKind.video,
  'vob': MediaKind.video,
  'iso': MediaKind.video,
  'ogv': MediaKind.video,
  // 音频
  'mp3': MediaKind.audio,
  'flac': MediaKind.audio,
  'aac': MediaKind.audio,
  'm4a': MediaKind.audio,
  'wav': MediaKind.audio,
  'ogg': MediaKind.audio,
  'opus': MediaKind.audio,
  'wma': MediaKind.audio,
  'ape': MediaKind.audio,
  'dsf': MediaKind.audio,
  // 字幕
  'srt': MediaKind.subtitle,
  'ass': MediaKind.subtitle,
  'ssa': MediaKind.subtitle,
  'vtt': MediaKind.subtitle,
  'sup': MediaKind.subtitle,
  'sub': MediaKind.subtitle,
  'idx': MediaKind.subtitle,
  // 图片
  'jpg': MediaKind.image,
  'jpeg': MediaKind.image,
  'png': MediaKind.image,
  'webp': MediaKind.image,
  'bmp': MediaKind.image,
};

/// 取小写扩展名，不含点；无扩展名返回空串。
String extensionOf(String fileName) {
  final idx = fileName.lastIndexOf('.');
  if (idx <= 0 || idx == fileName.length - 1) return '';
  return fileName.substring(idx + 1).toLowerCase();
}

/// 按扩展名判定种类。
MediaKind kindOf(String fileName) =>
    _extensions[extensionOf(fileName)] ?? MediaKind.other;

/// 是否是可播放的视频。
bool isVideo(String fileName) => kindOf(fileName) == MediaKind.video;

/// 是否是字幕文件。
bool isSubtitle(String fileName) => kindOf(fileName) == MediaKind.subtitle;

/// 从文件名解析出的候选标题信息。
///
/// 只做字符串层面的拆解，不联网、不猜剧情，输出是「候选」而非「答案」，
/// 最终展示名由客户端决定并回写。
class ParsedName {
  const ParsedName({
    required this.title,
    this.year,
    this.season,
    this.episode,
  });

  /// 清洗后的标题。
  final String title;

  /// 年份，无则 null。
  final int? year;

  /// 季号，无则 null。
  final int? season;

  /// 集号，无则 null。
  final int? episode;

  /// 是否像剧集。
  bool get isEpisode => season != null || episode != null;

  Map<String, Object?> toJson() => {
        'title': title,
        if (year != null) 'year': year,
        if (season != null) 'season': season,
        if (episode != null) 'episode': episode,
      };
}

final RegExp _yearPattern = RegExp(r'(?:^|[^0-9])((?:19|20)\d{2})(?:[^0-9]|$)');
final RegExp _seasonEpisode = RegExp(
  r'[Ss](\d{1,2})[\s._-]*[Ee](\d{1,4})',
  caseSensitive: false,
);
final RegExp _chineseEpisode =
    RegExp(r'第\s*(\d{1,4})\s*[集话話]');
final RegExp _cnSeason = RegExp(r'第\s*([0-9一二三四五六七八九十]{1,2})\s*季');
final RegExp _bracketGroup = RegExp(r'[\[\(【（][^\]\)】）]*[\]\)】）]');
final RegExp _releaseTags = RegExp(
  r'\b(2160p|1080p|720p|480p|4k|uhd|hdr|dv|dolby|vision|atmos|dts|'
  r'dts-?hd|truehd|bluray|blu-ray|bdrip|brrip|webrip|web-dl|webdl|hdtv|'
  r'dvdrip|remux|x264|x265|h264|h265|hevc|avc|10bit|8bit|hq|60fps|'
  r'aac|ac3|eac3|flac|commentary|proper|repack|extended|uncut)\b',
  caseSensitive: false,
);

/// 解析文件名（不含扩展名）为候选标题信息。
ParsedName parseFileName(String baseName) {
  var work = baseName;

  // 先摘出年份，避免年份被后面的清洗吃掉。
  int? year;
  final yearMatch = _yearPattern.firstMatch(work);
  if (yearMatch != null) {
    final parsed = int.tryParse(yearMatch.group(1)!);
    if (parsed != null) {
      year = parsed;
      work = work.replaceRange(yearMatch.start, yearMatch.end, ' ');
    }
  }

  // 季集：优先 SxxExx，其次中文「第 N 集」。
  int? season;
  int? episode;
  final seMatch = _seasonEpisode.firstMatch(work);
  if (seMatch != null) {
    season = int.tryParse(seMatch.group(1)!);
    episode = int.tryParse(seMatch.group(2)!);
    work = work.replaceRange(seMatch.start, seMatch.end, ' ');
  } else {
    final cnSeason = _cnSeason.firstMatch(work);
    if (cnSeason != null) {
      season = _parseChineseNumber(cnSeason.group(1)!);
      work = work.replaceRange(cnSeason.start, cnSeason.end, ' ');
    }
    final cnEp = _chineseEpisode.firstMatch(work);
    if (cnEp != null) {
      episode = int.tryParse(cnEp.group(1)!);
      work = work.replaceRange(cnEp.start, cnEp.end, ' ');
    }
  }

  // 去掉方括号/圆括号内的分组，通常是发布组或压制信息。
  work = work.replaceAll(_bracketGroup, ' ');
  // 去掉圆点、下划线、连字符等分隔符，统一成空格。
  work = work.replaceAll(RegExp(r'[._]+'), ' ');
  // 去掉发布标记词。
  work = work.replaceAll(_releaseTags, ' ');
  // 折叠空白。
  work = work.replaceAll(RegExp(r'\s+'), ' ').trim();
  // 去掉首尾的连字符与分隔符。
  work = work.replaceAll(RegExp(r'^[-–—~\s]+|[-–—~\s]+$'), '');

  if (work.isEmpty) work = baseName.trim();
  return ParsedName(title: work, year: year, season: season, episode: episode);
}

/// 解析一到十的中文数字，失败返回 null。
int? _parseChineseNumber(String text) {
  const table = {
    '一': 1,
    '二': 2,
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '七': 7,
    '八': 8,
    '九': 9,
    '十': 10,
  };
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  if (trimmed == '十') return 10;
  if (trimmed.startsWith('十')) {
    final rest = table[trimmed.substring(1)];
    return rest == null ? null : 10 + rest;
  }
  if (trimmed.length == 1) return table[trimmed];
  final digits = int.tryParse(trimmed);
  if (digits != null) return digits;
  final tens = trimmed.split('十');
  if (tens.length == 2) {
    final high = table[tens[0]] ?? 0;
    final low = tens[1].isEmpty ? 0 : (table[tens[1]] ?? 0);
    return high * 10 + low;
  }
  return null;
}
