/// 音源解析接缝（topone）：播控层只认这个接口，音源层实现它。
///
/// 规范出处：miot `src/voicecmd/online_searcher.ts` 的外部搜索源
/// topone 约定（keyword + hint{title, artist, duration} → 一首最佳
/// 匹配或未命中）。V1 的实现是胖虎现有音源引擎的适配器
/// （见 panghu_speaker_adapter.dart），核心层不感知其细节，
/// 搬到 headless 服务端时换实现即可。
library;

/// 一次解析请求。
class SpeakerResolveRequest {
  const SpeakerResolveRequest({
    required this.keyword,
    this.hintTitle,
    this.hintArtist,
    this.hintDurationMs,
    this.exactMusic,
  });

  /// 搜索关键词。
  final String keyword;

  /// 有把握时才给的提示（避免伪造 hint 限制候选，照 topone 规范）。
  final String? hintTitle;
  final String? hintArtist;
  final int? hintDurationMs;

  /// 队列接力专用：App 队列项携带的原始歌曲对象（对核心不透明，
  /// 由适配器解释——有它时可精确解析到同一首歌，不必重新搜索）。
  final Object? exactMusic;
}

/// 解析出的一首可推播歌曲。
class ResolvedSong {
  const ResolvedSong({
    required this.url,
    required this.title,
    required this.artist,
    this.durationMs,
    this.sourceName,
    this.qualityLabel,
  });

  /// 音箱可直接拉流的直链（适配器保证已通过 [isSpeakerPlayableUrl]）。
  final String url;
  final String title;
  final String artist;

  /// 命中的音源名（供接管记录展示）。
  final String? sourceName;

  /// 命中的音质（供接管记录展示）。
  final String? qualityLabel;

  /// 时长（毫秒）；未知为 null，接力会走 position 回零探测兜底。
  final int? durationMs;
}

/// topone 解析接口：返回最佳一首，未命中返回 null。
abstract interface class SpeakerSongResolver {
  Future<ResolvedSong?> resolveTopOne(SpeakerResolveRequest request);
}

/// 音箱可播 URL 判定（miot `OnlineSearcher.isSpeakerPlayableUrl` 原样移植）。
///
/// 判据：URL 的 mime 查询参数优先（audio/mpeg、audio/mp3 可播，
/// 其余 audio/* 一律不可），无 mime 时只认 .mp3 扩展名。
/// V1 不做转码，非 MP3 一律视为不可推播。
bool isSpeakerPlayableUrl(String rawUrl) {
  final Uri uri;
  try {
    uri = Uri.parse(rawUrl);
  } catch (_) {
    return false;
  }
  final mime = (uri.queryParameters['mime'] ?? '').toLowerCase();
  if (mime == 'audio/mpeg' || mime == 'audio/mp3') return true;
  if (mime.startsWith('audio/')) return false;
  final path = uri.path;
  final dot = path.lastIndexOf('.');
  if (dot < 0 || dot == path.length - 1) return false;
  return path.substring(dot + 1).toLowerCase() == 'mp3';
}
