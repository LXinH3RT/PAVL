/// 冒烟测试：确保应用能构建出首页而不抛异常。
///
/// 这里不实例化 [PavlApp]，因为它会在 main 里依赖 window_manager 与
/// media_kit 的原生初始化，单元测试环境没有这些。改为只验证纯逻辑组件。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:pavl_client/util/natural_sort.dart';

void main() {
  group('naturalCompare', () {
    test('数字按数值排序，不是字典序', () {
      final items = ['第10集.mkv', '第2集.mkv', '第1集.mkv'];
      items.sort(naturalCompare);
      expect(items, ['第1集.mkv', '第2集.mkv', '第10集.mkv']);
    });

    test('季集编号跨位比较', () {
      final items = ['S01E10', 'S01E02', 'S01E01'];
      items.sort(naturalCompare);
      expect(items, ['S01E01', 'S01E02', 'S01E10']);
    });

    test('纯文本按字典序', () {
      expect(naturalCompare('apple', 'banana'), lessThan(0));
      expect(naturalCompare('banana', 'apple'), greaterThan(0));
      expect(naturalCompare('same', 'same'), 0);
    });

    test('前缀相同时短的在前', () {
      expect(naturalCompare('abc', 'abcd'), lessThan(0));
    });

    test('大小写不敏感', () {
      expect(naturalCompare('ABC', 'abc'), 0);
    });
  });
}
