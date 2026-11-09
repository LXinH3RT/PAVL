/// 名称排序。
///
/// 全项目只有这一份排序规则，服务端把结果排好再发给客户端，客户端不再自己
/// 排。理由是多设备看到的顺序必须一致，而客户端只能对拿到的这一页排序，
/// 分页之后跨页的顺序就乱了。
///
/// 规则，按优先级：
///   1. 目录在文件之前（由调用方决定是否分组，本文件只管名称比较）
///   2. 数字段按数值比较，`第2集` 在 `第10集` 之前
///   3. 数字 < 拉丁字母 < 汉字
///   4. 汉字按其拼音比较，不按码位
///
/// 汉字按拼音是这里存在的唯一理由：码位序约等于部首笔画序，用户按名称找片
/// 时完全对不上。
library;

import 'package:lpinyin/lpinyin.dart';

/// 比较两个名称。
int compareNames(String a, String b) {
  if (identical(a, b)) return 0;
  final ta = _tokenize(a);
  final tb = _tokenize(b);
  final len = ta.length < tb.length ? ta.length : tb.length;
  for (var i = 0; i < len; i++) {
    final cmp = ta[i].compareTo(tb[i]);
    if (cmp != 0) return cmp;
  }
  if (ta.length != tb.length) return ta.length.compareTo(tb.length);
  // 分词结果等价时退回原串比较，保证比较是全序的（否则等价的名称会随
  // 输入顺序变化，用户看到列表每次刷新都可能换序）。
  return a.compareTo(b);
}

/// 排序用的词元。
///
/// 把名称切成「数字段」与「文字段」交替的序列，比较时逐段进行。文字段预
/// 先转成排序键：拉丁字母小写化后保留，汉字换成拼音，其余字符原样保留。
List<Comparable<Object>> _tokenize(String input) {
  final tokens = <Comparable<Object>>[];
  final digits = StringBuffer();
  final letters = StringBuffer();

  void flushDigits() {
    if (digits.isEmpty) return;
    // 用 (0, 数值) 让数字段排在所有文字段之前；长度相同的纯数字之间按数值
    // 已经能分出大小，这里补上类别前缀只为固定「数字 < 字母 < 汉字」。
    tokens.add(_NumberToken(int.parse(digits.toString())));
    digits.clear();
  }

  void flushLetters() {
    if (letters.isEmpty) return;
    tokens.add(_TextToken(_sortKeyOf(letters.toString())));
    letters.clear();
  }

  for (final rune in input.runes) {
    if (rune >= 0x30 && rune <= 0x39) {
      flushLetters();
      digits.writeCharCode(rune);
    } else {
      flushDigits();
      letters.writeCharCode(rune);
    }
  }
  flushDigits();
  flushLetters();
  return tokens;
}

/// 把一段文字转成用于比较的键。
///
/// 整串交给拼音库转换，而不是逐字转换：拼音库带词组识别，逐字处理会丢掉
/// 上下文——「重庆」按单字查是 zhong qing，整串才能得到正确的 chong qing。
///
/// 对齐方式是关键。拼音库对一个由 N 个 UTF-16 码元组成的字符串，会返回恰好
/// N 段（每个码元一段：汉字给拼音，其它字符原样回显）。因此用一个不会出现在
/// 文件名里的控制字符作分隔符切分，第 i 段就对应第 i 个码元。这个等式实测对
/// 中文、ASCII、标点、空白、全角符号、代理对都成立；万一某天不成立，退回逐
/// 字符转换——宁可失去词组读音，也不能让键错位。
///
/// 中文字符类别记为 2、拉丁字母记为 1、其它（标点、空白）记为 0，拼接在
/// 每个字符前面，从而让「数字 < 字母 < 汉字」在字符级别也成立。
String _sortKeyOf(String text) {
  if (text.isEmpty) return '';
  final pieces = _pinyinPieces(text);
  final out = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    final unit = text.codeUnitAt(i);
    final category = _categoryOf(unit);
    out.write(category);
    final piece = i < pieces.length ? pieces[i] : '';
    if (category == _kHan && _isPinyin(piece)) {
      out.write(piece.toLowerCase());
    } else {
      out.write(String.fromCharCode(unit).toLowerCase());
    }
  }
  return out.toString();
}

/// [text] 每个码元对应的拼音段。
List<String> _pinyinPieces(String text) {
  final joined = PinyinHelper.getPinyinE(
    text,
    separator: _separator,
    defPinyin: '',
    format: PinyinFormat.WITHOUT_TONE,
  );
  final pieces = joined.split(_separator);
  if (pieces.length == text.length) return pieces;
  // 段数与码元数对不上，退回逐字符转换，保证不会错位。
  return [
    for (var i = 0; i < text.length; i++) _singlePinyin(String.fromCharCode(text.codeUnitAt(i))),
  ];
}

/// 分隔符用控制字符：Windows 与 POSIX 都不允许它出现在文件名里。
const String _separator = '\u0001';

/// 单个码元的拼音，用于兜底路径。
String _singlePinyin(String ch) {
  try {
    return PinyinHelper.getPinyinE(
      ch,
      separator: '',
      defPinyin: '',
      format: PinyinFormat.WITHOUT_TONE,
    );
  } catch (_) {
    return '';
  }
}

/// 是否是纯拉丁字母组成的拼音。
///
/// 生僻字与代理对在字典里查不到，拼音库会回显原字符或替换符，不能当读音用。
bool _isPinyin(String piece) {
  if (piece.isEmpty) return false;
  for (var i = 0; i < piece.length; i++) {
    final unit = piece.codeUnitAt(i);
    final lower = unit | 0x20;
    if (lower < 0x61 || lower > 0x7A) return false;
  }
  return true;
}

const int _kOther = 0;
const int _kLatin = 1;
const int _kHan = 2;

int _categoryOf(int unit) {
  if ((unit >= 0x61 && unit <= 0x7A) || (unit >= 0x41 && unit <= 0x5A)) {
    return _kLatin;
  }
  if ((unit >= 0x4E00 && unit <= 0x9FFF) ||
      (unit >= 0x3400 && unit <= 0x4DBF) ||
      unit == 0x3007) {
    return _kHan;
  }
  return _kOther;
}

/// 数字段。单独一个类是为了让类别前缀参与比较，而不是把数值当字符串。
class _NumberToken implements Comparable<Object> {
  const _NumberToken(this.value);

  final int value;

  @override
  int compareTo(Object other) {
    if (other is _NumberToken) {
      // 数值相等的两个数字段（`第07集` 与 `第7集`）继续按后续词元比，这里
      // 返回 0 即可；剩下的部分由 compareNames 的循环处理。
      return value.compareTo(other.value);
    }
    // 数字段整体排在文字段之前。
    return -1;
  }
}

/// 文字段。
class _TextToken implements Comparable<Object> {
  const _TextToken(this.key);

  final String key;

  @override
  int compareTo(Object other) {
    if (other is _TextToken) return key.compareTo(other.key);
    // 文字段整体排在数字段之后。
    return 1;
  }
}
