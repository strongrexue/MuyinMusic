import 'lyric_parser.dart';

/// 标记「仅为测试可见」的注解。
///
/// 这里本地定义而不 import 'package:flutter/foundation.dart'，是为了让本文件保持
/// 纯 Dart：foundation 会间接依赖 dart:ui，在 `dart test`（非 flutter test）下
/// 无法编译。注解本身不影响运行期行为。
const visibleForTesting = _VisibleForTesting();

class _VisibleForTesting {
  const _VisibleForTesting();
}

/// 灵动岛歌词「分片 + 逐字翻帧」算法层。
///
/// 全部为纯静态函数，仅依赖 [KaraokeLyricLine] / [KaraokeWordTiming] 与 Dart
/// 核心库，不触碰 player_controller / audio_service / 任何 Flutter widget。
class LyricFrameAlgorithms {
  const LyricFrameAlgorithms._();

  /// 每帧最大字符数（最多一次显示 10 个字）：超过该长度智能截断拆帧，
  /// 避免焦点通知单侧文本被系统中间截断。每帧再对半分配到左右两侧。
  static const int _frameChars = 10;

  /// 实时通知（shortCriticalText）单侧最多显示 7 个字：超过则智能截断，
  /// 空格优先断点，取首帧作为灵动岛右侧歌词。
  // ignore: unused_field
  static const int _liveMaxChars = 7;

  /// 分隔符 rune 集合：空格、连字符、连接号、间隔号等。
  ///
  /// 拆帧时作为智能断点（避免把词从中间切开），且最终显示时被过滤掉
  /// （不留存在帧内），避免灵动岛/通知上出现孤立的空格或连字符。
  static const Set<int> _separators = {
    0x20, // 空格
    0x2D, // - 连字符
    0x2013, // – en dash
    0x2014, // — em dash
    0x00B7, // · 间隔号
    0x30FB, // ・ 片假名中黑点
    0x7E, // ~
    0xFF5E, // ～
  };

  static bool _isSeparator(int rune) => _separators.contains(rune);

  /// 核心决策：是否应向灵动岛推送歌词。
  @visibleForTesting
  static bool shouldShow({
    required bool enabled,
    required bool isPlaying,
    required String? lyricLine,
  }) {
    if (!enabled) return false;
    if (!isPlaying) return false;
    if (lyricLine == null || lyricLine.trim().isEmpty) return false;
    return true;
  }

  /// 歌词行是否值得更新（去重）：上一行与当前行不同则更新。
  @visibleForTesting
  static bool shouldUpdate({required String? previous, required String? next}) {
    if (next == null || next.trim().isEmpty) return false;
    return previous != next;
  }

  /// 分割结果：左侧放前半段，右侧放后半段，拼接成完整歌词。
  ///
  /// 优先在空格/词边界分割（避免把短语从中间切开），两侧均去掉首尾空格，
  /// 防止尾随空格导致系统侧滚动/错位。无空格时按字符数均分。
  @visibleForTesting
  static ({String left, String right}) splitLyricForIsland(String lyric) {
    final trimmed = lyric.trim();
    if (trimmed.isEmpty) return (left: '', right: '');
    final chars = trimmed.runes.toList();

    // 优先在空格处断：找中间段里最近的空格，避免切开短语
    var cut = (chars.length / 2).ceil();
    // 在 [cut/2, cut] 区间内找最后一个空格，使两侧更均衡
    for (var j = cut; j > 0; j--) {
      if (chars[j - 1] == 0x20) {
        cut = j;
        break;
      }
    }
    // 找不到空格则按字符均分
    if (cut <= 0 || cut >= chars.length) {
      cut = (chars.length / 2).ceil();
    }

    final left = String.fromCharCodes(chars.take(cut)).trim();
    final right = String.fromCharCodes(chars.skip(cut)).trim();
    // 若右侧为空但左侧有值（极端情况），把整行放右侧
    if (right.isEmpty && left.isNotEmpty) {
      return (left: '', right: trimmed);
    }
    return (left: left, right: right);
  }

  /// 是否应发送/更新封面（纯函数）。
  ///
  /// 仅在切歌或封面 id 变化时返回 true，避免同一首歌反复下载封面。
  /// 无封面 id 的歌曲恒返回 false（不发封面）。
  @visibleForTesting
  static bool shouldSendCover({
    required String? prevSongId,
    required String? prevCoverId,
    required String? newSongId,
    required String? newCoverId,
  }) {
    if (newCoverId == null || newCoverId.isEmpty) return false;
    if (prevSongId == newSongId && prevCoverId == newCoverId) return false;
    return true;
  }

  /// 超长歌词智能拆帧（纯函数）。
  ///
  /// 按 [frameChars] 字符数拆帧，每帧不超过该容量。优先在空格/词边界断，
  /// 避免把中文短语或短英文单词从中间切开；单个超长 ASCII 单词本身必须被切
  /// 时仍切成多帧（每帧不超容量）。短歌词单帧，空歌词无帧。所有帧拼接 =
  /// 完整歌词（无丢失）。
  ///
  /// 分隔符（空格、连字符、间隔号等 [_separators]）作为断点使用，并在帧内
  /// 被过滤：帧首尾和帧中的分隔符都不保留，避免灵动岛/通知上出现孤立
  /// 分隔符。所有帧去掉分隔符后拼接 = 原歌词去掉分隔符（无内容丢失）。
  ///
  /// 用途：焦点通知单侧文本超宽会被系统中间截断（隐藏中间字），拆帧后每帧
  /// 用满左右两侧、按行节奏切换，避免截断。
  @visibleForTesting
  static List<String> chunkLyric(String lyric, {required int frameChars}) {
    if (lyric.isEmpty) return const [];
    final chars = lyric.runes.toList();

    final buildFrame = (int start, int end) {
      // 过滤帧内的分隔符后返回文本；全是分隔符时返回空
      final buf = StringBuffer();
      for (var k = start; k < end; k++) {
        if (!_isSeparator(chars[k])) {
          buf.writeCharCode(chars[k]);
        }
      }
      return buf.toString();
    };

    if (chars.length <= frameChars) {
      final text = buildFrame(0, chars.length);
      return text.isEmpty ? const [] : [text];
    }

    final frames = <String>[];
    var i = 0;
    while (i < chars.length) {
      var end = (i + frameChars).clamp(0, chars.length);
      // 智能断点：优先在最近的分隔符/词边界断，避免把词从中间切开
      if (end < chars.length) {
        var boundary = -1;
        for (var j = end; j > i; j--) {
          if (_isSeparator(chars[j - 1])) {
            boundary = j;
            break;
          }
        }
        if (boundary > i && boundary < end) {
          end = boundary;
        }
      }
      // 跳过段首分隔符（分隔符作为断点，不留在帧首）
      var start = i;
      while (start < end && _isSeparator(chars[start])) {
        start++;
      }
      // 跳过段尾分隔符（不留在帧尾，避免系统侧滚动/错位）
      while (end > start && _isSeparator(chars[end - 1])) {
        end--;
      }

      if (end > start) {
        final text = buildFrame(start, end);
        if (text.isNotEmpty) {
          frames.add(text);
        }
      }
      i = end > i ? end : i + 1;
    }
    return frames;
  }

  /// 当前播放位置对应的帧索引（纯函数）。
  ///
  /// 在行时间窗口 [start, end] 内按 [frameCount] 等分，位置落在哪一段就返回
  /// 哪一帧；位置在行开始前返回 0，行结束后返回最后一帧。[lineEndMs] 为 null
  /// 或 [frameCount]≤1 时恒返回 0。
  @visibleForTesting
  static int frameIndexForPosition({
    required int frameCount,
    required int lineStartMs,
    required int? lineEndMs,
    required int positionMs,
  }) {
    if (lineEndMs == null || frameCount <= 1) return 0;
    if (positionMs <= lineStartMs) return 0;
    if (positionMs >= lineEndMs) return frameCount - 1;
    final window = lineEndMs - lineStartMs;
    final ratio = (positionMs - lineStartMs) / window;
    final index = (ratio * frameCount).floor();
    return index.clamp(0, frameCount - 1);
  }

  /// 基于逐字时间戳的帧索引（纯函数）。
  ///
  /// 逐字歌词每字有精确 [KaraokeWordTiming.startMs] 时间戳。当前播放位置
  /// 落在哪个字，就把该字对应到 [frames]（按字符切好的帧）里的哪一帧。
  ///
  /// 相比按行窗口等分的 [frameIndexForPosition]，字级时间戳能精确同步
  /// 演唱进度——不会出现"等分错位导致唱完了才翻帧"的问题。
  ///
  /// 无逐字时间戳 / 单帧时退回 [frameIndexForPosition] 的等分逻辑。
  @visibleForTesting
  static int frameIndexForPositionWithWords({
    required List<String> frames,
    required List<KaraokeWordTiming>? words,
    required int lineStartMs,
    required int? lineEndMs,
    required int positionMs,
  }) {
    if (frames.length <= 1) return 0;
    if (words == null || words.isEmpty) {
      return frameIndexForPosition(
        frameCount: frames.length,
        lineStartMs: lineStartMs,
        lineEndMs: lineEndMs,
        positionMs: positionMs,
      );
    }

    // 当前播放位置对应的字下标：最后一个 start ≤ positionMs 的字。
    var currentWord = -1;
    for (var i = 0; i < words.length; i++) {
      if (words[i].startMs <= positionMs) {
        currentWord = i;
      } else {
        break;
      }
    }
    if (currentWord < 0) return 0;
    if (currentWord >= words.length - 1) return frames.length - 1;

    // 把字词文本拼接，用其累积字符长度映射到 frames 的字符边界。
    // 帧按字符切：累计到当前字的字符数占总字符数的比例 → 帧索引。
    final totalChars = words.fold<int>(0, (sum, w) => sum + w.text.runes.length);
    if (totalChars <= 0) {
      return frameIndexForPosition(
        frameCount: frames.length,
        lineStartMs: lineStartMs,
        lineEndMs: lineEndMs,
        positionMs: positionMs,
      );
    }
    var charsBefore = 0;
    for (var i = 0; i <= currentWord; i++) {
      charsBefore += words[i].text.runes.length;
    }
    final ratio = charsBefore / totalChars;
    final index = (ratio * frames.length).floor();
    return index.clamp(0, frames.length - 1);
  }

  /// 高层便捷 API：把「当前行 + 播放位置」直接转成灵动岛可显示的帧。
  ///
  /// 依次完成拆帧 → 按位置/逐字确定帧索引 → 取当前帧文本 → 左右胶囊分割，
  /// 调用方一行即可拿到当前该显示的歌词帧及其左右文本。
  @visibleForTesting
  static LyricFrame frameForLine(
    KaraokeLyricLine line,
    int positionMs, {
    int frameChars = _frameChars,
  }) {
    final frames = chunkLyric(line.text, frameChars: frameChars);
    final index = frameIndexForPositionWithWords(
      frames: frames,
      words: line.hasWordTiming ? line.words : null,
      lineStartMs: line.startMs,
      lineEndMs: line.endMs,
      positionMs: positionMs,
    );
    final text = frames.isEmpty ? '' : frames[index];
    final parts = splitLyricForIsland(text);
    return LyricFrame(
      text: text,
      left: parts.left,
      right: parts.right,
      frameIndex: index,
      frameCount: frames.length,
    );
  }
}

/// 一帧灵动岛歌词：当前帧文本 [text] 及其左右胶囊文本 [left]/[right]，
/// 并附带帧索引 [frameIndex] 与总帧数 [frameCount]。
class LyricFrame {
  const LyricFrame({
    required this.text,
    required this.left,
    required this.right,
    required this.frameIndex,
    required this.frameCount,
  });

  final String text;
  final String left;
  final String right;
  final int frameIndex;
  final int frameCount;

  @override
  String toString() =>
      'LyricFrame(text: $text, left: $left, right: $right, '
      'frameIndex: $frameIndex, frameCount: $frameCount)';
}
