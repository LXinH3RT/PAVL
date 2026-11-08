/// HTTP Range 解析与文件流式发送。
///
/// 这是整个服务端最关键的一段：播放器 seek 依赖 Range，
/// 任何一处边界算错都会表现为「拖进度条卡住」或「播放花屏」。
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

/// 解析后的字节区间，闭区间。
class ByteRange {
  const ByteRange(this.start, this.end);

  final int start;
  final int end;

  /// 区间长度。
  int get length => end - start + 1;
}

/// Range 解析结果。
class RangeResult {
  RangeResult.ok(this.range);

  /// 请求不可满足，应当返回 416。
  RangeResult.unsatisfiable() : range = null;

  /// 没有 Range 头，应当返回 200 全文件。
  RangeResult.none() : range = null;

  final ByteRange? range;

  bool get isOk => range != null;
}

/// 解析 `Range: bytes=start-end`。
///
/// 只支持单区间，多区间按 RFC 7233 允许降级为整个文件。
/// 返回 null 表示应当返回 416。
RangeResult parseRange(String? header, int fileSize) {
  if (header == null || header.isEmpty) return RangeResult.none();
  final trimmed = header.trim();
  if (!trimmed.toLowerCase().startsWith('bytes=')) return RangeResult.none();
  final spec = trimmed.substring(6);
  // 多区间直接用全文件，避免 multipart/byteranges 的复杂度。
  if (spec.contains(',')) return RangeResult.none();

  final dash = spec.indexOf('-');
  if (dash < 0) return RangeResult.unsatisfiable();

  final startText = spec.substring(0, dash).trim();
  final endText = spec.substring(dash + 1).trim();

  int start;
  int end;

  if (startText.isEmpty) {
    // `bytes=-500` 表示最后 500 字节。
    final suffix = int.tryParse(endText);
    if (suffix == null || suffix <= 0) return RangeResult.unsatisfiable();
    if (fileSize <= 0) return RangeResult.unsatisfiable();
    start = suffix >= fileSize ? 0 : fileSize - suffix;
    end = fileSize - 1;
  } else {
    final parsedStart = int.tryParse(startText);
    if (parsedStart == null || parsedStart < 0) {
      return RangeResult.unsatisfiable();
    }
    start = parsedStart;
    if (endText.isEmpty) {
      end = fileSize - 1;
    } else {
      final parsedEnd = int.tryParse(endText);
      if (parsedEnd == null || parsedEnd < parsedStart) {
        return RangeResult.unsatisfiable();
      }
      end = parsedEnd;
    }
  }

  // 越界修正。
  if (start >= fileSize) return RangeResult.unsatisfiable();
  if (end >= fileSize) end = fileSize - 1;
  if (end < start) return RangeResult.unsatisfiable();

  return RangeResult.ok(ByteRange(start, end));
}

/// 根据扩展名给出 Content-Type。
String contentTypeOf(String fileName) {
  final idx = fileName.lastIndexOf('.');
  final ext = idx < 0 ? '' : fileName.substring(idx + 1).toLowerCase();
  switch (ext) {
    case 'mkv':
      return 'video/x-matroska';
    case 'mp4':
    case 'm4v':
      return 'video/mp4';
    case 'mov':
      return 'video/quicktime';
    case 'webm':
      return 'video/webm';
    case 'avi':
      return 'video/x-msvideo';
    case 'ts':
    case 'm2ts':
      return 'video/mp2t';
    case 'flv':
      return 'video/x-flv';
    case 'wmv':
      return 'video/x-ms-wmv';
    case 'mp3':
      return 'audio/mpeg';
    case 'flac':
      return 'audio/flac';
    case 'aac':
      return 'audio/aac';
    case 'm4a':
      return 'audio/mp4';
    case 'wav':
      return 'audio/wav';
    case 'ogg':
    case 'opus':
      return 'audio/ogg';
    case 'srt':
      return 'application/x-subrip; charset=utf-8';
    case 'ass':
    case 'ssa':
      return 'text/x-ssa; charset=utf-8';
    case 'vtt':
      return 'text/vtt; charset=utf-8';
    case 'sup':
      return 'application/octet-stream';
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'png':
      return 'image/png';
    case 'webp':
      return 'image/webp';
    default:
      return 'application/octet-stream';
  }
}

/// 把文件的一段写进 HTTP 响应。
///
/// 分块读取而不是一次性 `readAsBytes`，这样 4GB 的影片也不会吃满内存。
/// 默认块大小 1 MiB —— 与 LanPlayer 的顺序预读大小一致，
/// 在千兆网与 Wi-Fi 之间是折中值。
Future<void> streamFile(
  HttpResponse response,
  File file, {
  required int start,
  required int end,
  int chunkSize = 1024 * 1024,
  Future<bool> Function()? isAborted,
}) async {
  RandomAccessFile? raf;
  try {
    raf = await file.open();
    await raf.setPosition(start);
    var remaining = end - start + 1;
    while (remaining > 0) {
      if (isAborted != null && await isAborted()) break;
      final want = remaining < chunkSize ? remaining : chunkSize;
      final chunk = await raf.read(want);
      if (chunk.isEmpty) break;
      remaining -= chunk.length;
      response.add(chunk);
      // 每块之后 flush，让播放器尽早拿到首帧数据。
      await response.flush();
    }
  } on FileSystemException {
    // 文件在发送途中被删除或权限变化：连接已经被写坏，直接关掉。
  } finally {
    await raf?.close();
  }
}

/// 小工具：把可空字符串转成响应体安全的 JSON 值。
Object? orNull(String? value) => (value == null || value.isEmpty) ? null : value;

/// 生成 32 位十六进制随机 id。
String randomHex(int bytes, [Random? random]) {
  final rng = random ?? Random.secure();
  final buffer = StringBuffer();
  for (var i = 0; i < bytes; i++) {
    buffer.write(rng.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

/// 计算文件 ETag。
///
/// 用「大小 + 修改时间」做弱校验，足够用于缓存与 304，
/// 不需要真正读一遍文件算哈希。
String weakEtag(int size, int modifiedMs) => 'W/"${size.toRadixString(16)}-'
    '${modifiedMs.toRadixString(16)}"';
