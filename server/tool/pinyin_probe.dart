import 'package:lpinyin/lpinyin.dart';

/// 检查「整串转换后按分隔符切分」的段数是否恒等于 UTF-16 码元数。
///
/// 如果这个等式成立，就可以用整串转换（自带词组识别，`重庆` 读 chong）
/// 再按码元位置对齐，而不必逐字转换（逐字失去词组上下文，`重` 会读 zhong）。
void main() {
  const sep = '\u0001';
  const samples = [
    '重庆森林', '重庆', '银行行长', '一丁点儿', '中华人民共和国',
    '第10集', '你好，世界', '阿凡达', '电影Z', 'ab电影', 'Avatar 2009',
    '第2集 中文', '𠀀', '㐀', 'a,b', '  空格  ', '①壹②', 'x', '',
    'The.Matrix.1999.1080p.BluRay.x264-GROUP',
    'S01E02 某剧名', '50%_off', 'Ω≈ç√',
  ];
  var bad = 0;
  for (final s in samples) {
    final joined = PinyinHelper.getPinyinE(s,
        separator: sep, defPinyin: '', format: PinyinFormat.WITHOUT_TONE);
    final parts = joined.split(sep);
    final units = s.length;
    final ok = parts.length == units;
    if (!ok) bad++;
    print('${ok ? "OK " : "BAD"} "$s" 段=${parts.length} 码元=$units -> $parts');
  }
  print('不一致 $bad / ${samples.length}');
}
