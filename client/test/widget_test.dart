/// 冒烟测试：跑一些不依赖原生插件的纯逻辑。
///
/// 这里不实例化 [PavlApp]，因为它会在 main 里依赖 window_manager 与
/// media_kit 的原生初始化，单元测试环境没有这些。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:pavl_client/api/pavl_client.dart';
import 'package:pavl_client/util/app_log.dart';

void main() {
  group('redactUri', () {
    test('令牌与 PIN 一律打码', () {
      final uri = Uri.parse(
        'http://192.0.2.10:8765/api/v1/stream?path=a.mkv&token=secret123&pin=246810',
      );
      final redacted = redactUri(uri);
      expect(redacted.contains('secret123'), isFalse);
      expect(redacted.contains('246810'), isFalse);
      // `*` 会被 Uri 编码成 %2A，所以要解码后再比对掩码本身。
      final params =
          Uri.parse(redacted).queryParameters.map((k, v) => MapEntry(k, v));
      expect(params['token'], '***');
      expect(params['pin'], '***');
      // 其它参数原样保留，否则日志看不出请求的是哪个文件。
      expect(redacted.contains('a.mkv'), isTrue);
    });

    test('空令牌不会变成 ***，保持可读', () {
      final redacted = redactUri(Uri.parse('http://host/api?token=&path=x'));
      expect(Uri.parse(redacted).queryParameters['token'], '');
      expect(redacted.contains('path=x'), isTrue);
    });
  });

  group('ProgressRecord', () {
    test('已看比例按位置除以时长', () {
      final record = ProgressRecord(position: 30, duration: 120);
      expect(record.ratio, closeTo(0.25, 1e-9));
    });

    test('时长未知时比例为 0，不能除零', () {
      final record = ProgressRecord(position: 30, duration: 0);
      expect(record.ratio, 0);
    });
  });
}
