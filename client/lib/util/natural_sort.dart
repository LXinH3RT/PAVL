/// 自然排序：让 "第2集" 排在 "第10集" 前面，而不是字典序。
///
/// 服务端也有一份相同逻辑。客户端这份用于对本地拼接出来的列表做兜底排序，
/// 两边规则必须一致，否则同一目录在两处的顺序会不同。
library;

int naturalCompare(String a, String b) {
  final lowerA = a.toLowerCase();
  final lowerB = b.toLowerCase();
  var i = 0;
  var j = 0;
  while (i < lowerA.length && j < lowerB.length) {
    final charA = lowerA.codeUnitAt(i);
    final charB = lowerB.codeUnitAt(j);

    if (_isDigit(charA) && _isDigit(charB)) {
      // 找到两段数字的边界，按数值比。
      final startA = i;
      final startB = j;
      while (i < lowerA.length && _isDigit(lowerA.codeUnitAt(i))) {
        i++;
      }
      while (j < lowerB.length && _isDigit(lowerB.codeUnitAt(j))) {
        j++;
      }
      final numA = int.tryParse(lowerA.substring(startA, i));
      final numB = int.tryParse(lowerB.substring(startB, j));
      if (numA != null && numB != null && numA != numB) {
        return numA.compareTo(numB);
      }
      // 数值相同则继续比后续字符（例如 "01" 与 "1"）。
      continue;
    }

    if (charA != charB) return charA.compareTo(charB);
    i++;
    j++;
  }
  return a.length.compareTo(b.length);
}

bool _isDigit(int codeUnit) => codeUnit >= 0x30 && codeUnit <= 0x39;
