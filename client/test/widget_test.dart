/// 冒烟测试：跑一些不依赖原生插件的纯逻辑。
///
/// 这里不实例化 [PavlApp]，因为它会在 main 里依赖 window_manager 与
/// media_kit 的原生初始化，单元测试环境没有这些。
library;

import 'dart:io';

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

  // 「关于 → 许可」读的是随包分发的 assets/LICENSE.txt，而不是安装目录里
  // 的 LICENSE.txt。两份必须逐字相同：一旦有人只改了其中一份，客户端里
  // 展示的条款就和包外那份对不上了。scripts/package.py 打包前也会比一遍。
  group('许可证', () {
    test('assets 里的副本与仓库根 LICENSE 逐字一致', () {
      final repoLicense = File('../LICENSE');
      final assetLicense = File('assets/LICENSE.txt');

      expect(repoLicense.existsSync(), isTrue,
          reason: '找不到仓库根的 LICENSE，工作目录应当在 client/ 下');
      expect(assetLicense.existsSync(), isTrue,
          reason: '找不到 assets/LICENSE.txt，pubspec.yaml 里要登记它');

      final expected = repoLicense.readAsBytesSync();
      final actual = assetLicense.readAsBytesSync();
      expect(actual.length, expected.length,
          reason: '两份许可证长度不同');
      expect(actual, equals(expected), reason: '两份许可证内容不同');
    });
  });
}
