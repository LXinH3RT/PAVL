/// 运行日志。
///
/// 客户端平时不写盘，只在出问题时留证据：播放失败时如果连 libmpv 的报错
/// 都看不到，用户只能描述成「全黑」，无从排查。这里把关键事件按行追加到
/// 可执行文件同级 `PAVL-data/client.log`，出问题时让用户把文件发过来即可。
///
/// 放在便携目录而不是 %APPDATA%，是为了「整个文件夹拷走就能带走现场」，
/// 也避开某些机器上用户配置目录不可写的情况。
///
/// 约束：
///   - 不引第三方依赖，只用 dart:io。
///   - 写日志绝不能影响播放：所有 IO 异常吞掉。
///   - 文件超过 [maxBytes] 后整体截断重来，避免无限增长。
library;

import 'dart:io';

import '../store/app_store.dart';

/// 日志文件路径：与应用数据放在一起（便携目录）。
File logFile() =>
    File('${appDataDir().path}${Platform.pathSeparator}client.log');

/// 单文件上限，超过就清空重写。
const int maxBytes = 512 * 1024;

/// 写入是否已经失败，失败后不再重试，避免每行日志都抛一次异常。
bool _broken = false;

/// 日志是否因为 IO 问题不可用。
bool get logUnavailable => _broken;

/// 追加一行日志。
///
/// [tag] 是短标签（play / mpv / http），用来快速定位是哪个子系统。
void logLine(String tag, String message) {
  if (_broken) return;
  try {
    final file = logFile();
    file.parent.createSync(recursive: true);
    if (file.existsSync() && file.lengthSync() > maxBytes) {
      file.writeAsStringSync('', flush: false);
    }
    final now = DateTime.now();
    final stamp = '${now.year}-${_two(now.month)}-${_two(now.day)} '
        '${_two(now.hour)}:${_two(now.minute)}:${_two(now.second)}'
        '.${now.millisecond.toString().padLeft(3, '0')}';
    // 单行化：libmpv 的日志里偶尔带换行，会把一行拆成多条。
    final line = message.replaceAll('\r', ' ').replaceAll('\n', ' ');
    file.writeAsStringSync(
      '$stamp [$tag] $line\n',
      mode: FileMode.append,
      flush: false,
    );
  } catch (_) {
    // 磁盘只读、权限不足都不该影响播放，记一次失败后不再重试。
    _broken = true;
  }
}

/// 脱敏：令牌与 PIN 绝不能进日志文件。
String redactUri(Uri uri) {
  final params = <String, String>{};
  uri.queryParameters.forEach((key, value) {
    params[key] = key == 'token' || key == 'pin'
        ? (value.isEmpty ? '' : '***')
        : value;
  });
  return uri.replace(queryParameters: params).toString();
}

String _two(int value) => value.toString().padLeft(2, '0');
