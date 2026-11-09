/// 排序与片库解析的检查脚本。
///
/// 项目没有测试框架依赖，这里用最直接的方式验证最容易出错的几件事：
/// 排序规则、文件名解析、分页边界。改这两块的代码后跑一遍。
library;

import 'package:pavl_server/media.dart';
import 'package:pavl_server/sort_key.dart';

void main() {
  _checkSort();
  _checkParse();
  print('\n全部检查通过');
}

void _expect(bool ok, String what) {
  if (!ok) {
    print('FAIL $what');
    throw StateError(what);
  }
}

void _checkSort() {
  print('== 排序 ==');
  final sorted = [
    '第10集', '第2集', '第1集', '阿凡达', '长安', '重庆', '电影',
    'Avatar', 'avatar', '2012', '007', 'Z', 'A', '中', '文',
    '第07集', '第7集', '10', '9', '100', 'TV版', 'tv版', 'TV版 第2季',
  ]..sort(compareNames);
  print(sorted.join(' | '));

  // 数字段按数值，不按字符串。
  _expect(compareNames('第2集', '第10集') < 0, '第2集 < 第10集');
  _expect(compareNames('9', '10') < 0, '9 < 10');
  // 数字段整体排在文字段之前。
  _expect(compareNames('2012', '阿凡达') < 0, '数字 < 汉字');
  _expect(compareNames('2012', 'Avatar') < 0, '数字 < 字母');
  // 字母排在汉字之前。
  _expect(compareNames('Z', '中') < 0, '字母 < 汉字');
  // 大小写不敏感：比较键相同，最终由原串比较分出先后，两个方向必须互为相反数。
  _expect(compareNames('Avatar', 'avatar') ==
      -compareNames('avatar', 'Avatar'), 'Avatar / avatar 反对称');
  _expect(compareNames('ABC', 'abc') == -compareNames('abc', 'ABC'),
      'ABC / abc 反对称');
  // 汉字按拼音，不按码位：码位上 重(0x91CD) > 长(0x957F)？实际 长 0x957F > 重 0x91CD，
  // 按码位 重 会在 长 前面；按拼音 chang < chong < dian，长 在 重 前面。
  _expect(compareNames('长安', '重庆') < 0, '长安 < 重庆（拼音序）');
  _expect(compareNames('重庆', '电影') < 0, '重庆 < 电影（chong < dian）');
  _expect(compareNames('阿凡达', '长安') < 0, '阿凡达 < 长安（a < chang）');
  // 词组读音：重庆 是 chong 不是 zhong。若按 zhong 排，它会跑到 中 后面。
  _expect(compareNames('重庆', '中') < 0, '重庆 < 中（chong < zhong）');
  // 全序：相等名称必须稳定。
  _expect(compareNames('同名', '同名') == 0, '自身相等');
}

void _checkParse() {
  print('\n== 文件名解析 ==');
  final cases = <String, (String, int?, int?)>{
    'Movie.2024.1080p': ('Movie', 2024, null),
    'Show.Name.S01E02.1080p': ('Show Name', null, 2),
    '某剧 第10集': ('某剧', null, 10),
    '某剧 第2季 第03集': ('某剧', null, 3),
  };
  cases.forEach((input, want) {
    final parsed = parseFileName(input);
    print('$input -> title="${parsed.title}" year=${parsed.year} '
        'season=${parsed.season} episode=${parsed.episode}');
    _expect(parsed.year == want.$2, '$input 年份');
    _expect(parsed.episode == want.$3, '$input 集数');
  });
}
