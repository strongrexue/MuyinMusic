/// 语音指令意图（纯 Dart 规则解析）。
///
/// 关键词表与分流顺序以蓝本为准：miot `src/voicecmd/defaults.ts`
/// （指令集）、`dispatcher.ts`（固定控制指令最先）、xiaomusic
/// `config.py` / `command_handler.py`（先完全匹配再抓参数）。
/// V1 只做点歌与基础控制；歌单 / 歌手 / 序号类指令不识别，
/// 返回 null 交还音箱原生处理。
library;

/// 一条已识别的意图。
sealed class SpeakerIntent {
  const SpeakerIntent(this.raw);

  /// 归一化前的用户原话。
  final String raw;
}

/// 点歌：用胖虎音源解析 [keyword] 后推给音箱。
class PlaySongIntent extends SpeakerIntent {
  const PlaySongIntent(super.raw, {required this.keyword, this.title, this.artist});

  /// 搜索关键词（点歌前缀之后的完整文本，如「周杰伦晴天」）。
  final String keyword;

  /// 拆出的歌名提示（无法可靠拆分时与 keyword 相同或为 null）。
  final String? title;

  /// 拆出的歌手提示（仅「歌手 + 的 + 歌名」句式能可靠拆出）。
  final String? artist;
}

/// 停止播放（接管侧执行 pause→stop 并结束接力）。
class StopIntent extends SpeakerIntent {
  const StopIntent(super.raw);
}

/// 暂停播放。
class PauseIntent extends SpeakerIntent {
  const PauseIntent(super.raw);
}

/// 继续播放。
class ResumeIntent extends SpeakerIntent {
  const ResumeIntent(super.raw);
}

/// 下一首（接力会话内有效）。
class NextIntent extends SpeakerIntent {
  const NextIntent(super.raw);
}

/// 上一首（接力会话内有效）。
class PreviousIntent extends SpeakerIntent {
  const PreviousIntent(super.raw);
}

/// 音量设为绝对值（0–100，执行时再钳制）。
class SetVolumeIntent extends SpeakerIntent {
  const SetVolumeIntent(super.raw, this.value);

  final int value;
}

/// 音量步进（大声一点 / 小声一点）。
class VolumeStepIntent extends SpeakerIntent {
  const VolumeStepIntent(super.raw, {required this.up});

  final bool up;
}

// ===== 关键词表（蓝本 defaults.ts / config.py 节选，V1 子集）=====

const _pauseWords = {'暂停', '暂停播放', '暂停音乐', '停一下'};

const _stopWords = {'停止', '停止播放', '停止音乐', '关机', '关闭', '关掉音乐', '别播了'};

const _resumeWords = {'继续播放', '恢复播放', '继续', '接着播', '接着放', '播放'};

const _nextWords = {'下一首', '下一曲', '切歌', '换一首'};

const _previousWords = {'上一首', '上一曲'};

const _volumeUpWords = {'大声一点', '声音大一点', '音量大一点', '大声点', '音量大点'};

const _volumeDownWords = {'小声一点', '声音小一点', '音量小一点', '小声点', '音量小点'};

/// V1 不接管的点播类前缀：命中即交还原生（歌单/歌手/序号留待后续版本）。
const _unsupportedPlayPrefixes = [
  '播放歌单',
  '放歌单',
  '播放列表',
  '播放歌手',
  '搜索歌手',
  '播放第',
  '跳到第',
  '切到第',
];

/// 点歌前缀（长在前，先匹配长前缀）。
const _playSongPrefixes = [
  '播放歌曲',
  '放歌曲',
  '我想听',
  '来一首歌',
  '来一首',
  '点歌',
  '播放',
  '点唱',
  '唱',
  '放',
  '听',
];

const _volumePrefixes = ['设置音量', '音量调到', '音量设为', '声音调到', '音量', '声音'];

/// 解析一条小爱对话 query 为意图；不认识返回 null（交还原生）。
SpeakerIntent? parseSpeakerIntent(String rawQuery) {
  final raw = rawQuery.trim();
  if (raw.isEmpty) return null;
  final text = _normalize(raw);
  if (text.isEmpty) return null;

  // 不接管的点播类指令先排除，避免被通用「播放」前缀误吞。
  for (final prefix in _unsupportedPlayPrefixes) {
    if (text.startsWith(prefix)) return null;
  }

  // 固定控制指令：完全匹配最先（dispatcher 顺序）。
  if (_pauseWords.contains(text)) return PauseIntent(raw);
  if (_stopWords.contains(text)) return StopIntent(raw);
  if (_resumeWords.contains(text)) return ResumeIntent(raw);
  if (_nextWords.contains(text)) return NextIntent(raw);
  if (_previousWords.contains(text)) return PreviousIntent(raw);
  if (_volumeUpWords.contains(text)) return VolumeStepIntent(raw, up: true);
  if (_volumeDownWords.contains(text)) {
    return VolumeStepIntent(raw, up: false);
  }

  // 音量绝对值：前缀 + 数字（阿拉伯或中文数字）。
  for (final prefix in _volumePrefixes) {
    if (text.startsWith(prefix) && text.length > prefix.length) {
      final rest = text.substring(prefix.length);
      final value = _parseVolumeNumber(rest);
      if (value != null) return SetVolumeIntent(raw, value);
    }
  }

  // 点歌：前缀 + 歌名部分。
  for (final prefix in _playSongPrefixes) {
    if (!text.startsWith(prefix)) continue;
    var rest = text.substring(prefix.length).trim();
    if (rest.isEmpty) return null;
    // 「播放下一首」这类是控制指令，不是点歌。
    if (_nextWords.contains(rest)) return NextIntent(raw);
    if (_previousWords.contains(rest)) return PreviousIntent(raw);
    if (_pauseWords.contains(rest)) return PauseIntent(raw);
    if (_stopWords.contains(rest)) return StopIntent(raw);
    // 剥量词：「一首晴天」→「晴天」。
    if (rest.startsWith('一首歌')) {
      rest = rest.substring(3).trim();
    } else if (rest.startsWith('一首')) {
      rest = rest.substring(2).trim();
    } else if (rest.startsWith('歌曲')) {
      rest = rest.substring(2).trim();
    }
    if (rest.isEmpty) return null;
    return _buildPlaySong(raw, rest);
  }

  return null;
}

PlaySongIntent _buildPlaySong(String raw, String keyword) {
  var text = keyword;
  // 句尾语气词不进歌名。
  if (text.endsWith('吧') || text.endsWith('呀')) {
    text = text.substring(0, text.length - 1).trim();
  }
  // 「歌手的歌名」句式可可靠拆分；其余整体作 keyword，
  // 歌手/歌名拆分交给音源侧按 hint 打分（TrackFerry 实测同理）。
  final deIndex = text.indexOf('的');
  if (deIndex > 0 && deIndex < text.length - 1) {
    final artist = text.substring(0, deIndex).trim();
    final title = text.substring(deIndex + 1).trim();
    if (artist.isNotEmpty && title.isNotEmpty) {
      return PlaySongIntent(raw, keyword: text, title: title, artist: artist);
    }
  }
  return PlaySongIntent(raw, keyword: text, title: text);
}

/// 归一化：去首尾空白与句尾标点（ASR 文本常见尾随句号）。
String _normalize(String text) {
  var t = text.trim();
  while (t.isNotEmpty && '。！？!?.,，、；;：:~～… '.contains(t[t.length - 1])) {
    t = t.substring(0, t.length - 1).trimRight();
  }
  return t;
}

/// 从音量前缀后的文本里解析数字：支持阿拉伯数字与中文数字（0–100）。
int? _parseVolumeNumber(String rest) {
  final cleaned = rest.replaceAll(RegExp(r'[^0-9零一二三四五六七八九十百两]'), '');
  if (cleaned.isEmpty) return null;
  final arabic = RegExp(r'^\d+$').hasMatch(cleaned);
  if (arabic) return int.tryParse(cleaned);
  return _parseChineseNumber(cleaned);
}

int? _parseChineseNumber(String text) {
  const digits = {
    '零': 0,
    '一': 1,
    '二': 2,
    '两': 2,
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '七': 7,
    '八': 8,
    '九': 9,
  };
  if (text == '百') return 100;
  final hundredIndex = text.indexOf('百');
  if (hundredIndex >= 0) {
    final head = hundredIndex == 0 ? 1 : digits[text[hundredIndex - 1]];
    if (head == null) return null;
    final tail = text.substring(hundredIndex + 1);
    if (tail.isEmpty) return head * 100;
    final tailValue = _parseChineseNumber(tail);
    return tailValue == null ? null : head * 100 + tailValue;
  }
  final tenIndex = text.indexOf('十');
  if (tenIndex >= 0) {
    final head = tenIndex == 0 ? 1 : digits[text[tenIndex - 1]];
    if (head == null) return null;
    var value = head * 10;
    if (tenIndex + 1 < text.length) {
      final ones = digits[text[tenIndex + 1]];
      if (ones == null) return null;
      value += ones;
    }
    return value;
  }
  if (text.length == 1) return digits[text];
  return null;
}
