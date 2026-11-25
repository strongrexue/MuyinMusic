/// 专属口令过滤（纯逻辑，零 I/O 零 UI）。
///
/// 音箱硬件唤醒词改不了，只能在轮询到的对话文本层过滤：
/// 开启后，query 必须含口令词才归接管，喂给指令解析器前先剥除口令。
library;

/// 默认口令词。
const String kDefaultWakeWord = '胖虎';

final RegExp _punctOrSpace = RegExp(r'[\s\p{P}]', unicode: true);

class WakeWordFilter {
  const WakeWordFilter({required this.enabled, required this.word});

  const WakeWordFilter.disabled() : enabled = false, word = '';

  final bool enabled;
  final String word;

  /// 返回应喂给指令解析器的文本；放行给原生（未命中口令）返回 null。
  String? apply(String query) {
    final trimmedWord = word.trim();
    if (!enabled || trimmedWord.isEmpty) return query;

    final runes = query.runes.toList();
    final wordRunes = trimmedWord.runes.toList();
    final index = _indexOfRunes(runes, wordRunes);
    if (index < 0) return null;

    // 吃掉切口两侧相邻的标点/空白：左侧自口令前一 rune 起向左，
    // 右侧自口令后一 rune 起向右，连续命中即吞。
    var left = index;
    while (left > 0 && _isPunctOrSpace(runes[left - 1])) {
      left--;
    }
    var right = index + wordRunes.length;
    while (right < runes.length && _isPunctOrSpace(runes[right])) {
      right++;
    }
    final result = String.fromCharCodes([
      ...runes.sublist(0, left),
      ...runes.sublist(right),
    ]);
    return result.trim();
  }

  static bool _isPunctOrSpace(int rune) =>
      _punctOrSpace.hasMatch(String.fromCharCode(rune));

  static int _indexOfRunes(List<int> haystack, List<int> needle) {
    if (needle.isEmpty || needle.length > haystack.length) return -1;
    outer:
    for (var i = 0; i + needle.length <= haystack.length; i++) {
      for (var j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) continue outer;
      }
      return i;
    }
    return -1;
  }
}
