import '../api/music_api.dart';
import '../models/enums.dart';
import '../models/music_info.dart';
import '../models/music_url.dart';
import '../models/search_response.dart';
import '../music_sources/music_url_resolver.dart';
import '../../features/player/player_models.dart';
import 'speaker_url_probe.dart';
import 'takeover/speaker_relay.dart';
import 'takeover/speaker_resolver.dart';

/// 胖虎音源引擎 → topone 接缝的适配器。
///
/// 搜索走 [MusicApi.searchMusic]（source=all 聚合），候选按
/// hint（歌名/歌手）打分排序，逐个用 [MusicUrlResolver] 解析直链，
/// 只接受音箱可播的 MP3（[isSpeakerPlayableUrl]）；多音质里优先
/// 试 MP3 音质（k320/k192/k128），其余音质作兜底（个别源的直链
/// 本身就是 mp3）。队列项带 exactMusic 时精确解析同一首，不重搜。
///
/// 注意：直链解析依赖主 engine 上的 QuickJS 通道
/// （music_source_runtime 插件），本适配器只能在主 engine 里跑，
/// 这也是接管监听必须寄生主进程的原因。
class PanghuSpeakerSongResolver implements SpeakerSongResolver {
  PanghuSpeakerSongResolver({
    required MusicApi api,
    required MusicUrlResolver urlResolver,
    SpeakerUrlProbe? urlProbe,
    void Function(String message)? onLog,
    Duration resolveBudget = const Duration(seconds: 8),
    DateTime Function()? now,
  }) : _api = api,
       _urlResolver = urlResolver,
       _urlProbe = urlProbe ?? SpeakerUrlProbe(),
       _onLog = onLog,
       _resolveBudget = resolveBudget,
       _now = now ?? DateTime.now;

  final MusicApi _api;
  final MusicUrlResolver _urlResolver;
  final SpeakerUrlProbe _urlProbe;
  final void Function(String message)? _onLog;

  /// 一次解析（搜索+逐候选解析+探测）的总时间预算。首个通过探测
  /// 的候选立即返回（它就是已通过的最佳候选）；预算耗尽仍无候选
  /// 通过则如实未命中，不无限拖长接管的静音窗口。
  /// 注：TrackFerry 无此参数——它靠 Quiet 全程静音罩住决策期；
  /// 本预算是移动端防解析失控的自设上限，与静音罩并行生效。
  final Duration _resolveBudget;
  final DateTime Function() _now;

  /// 单个候选最多尝试的音质数（避免在坏源上无限试错）。
  static const _maxQualityAttempts = 6;

  /// 一次点歌最多尝试解析的搜索候选数。
  static const _maxCandidates = 5;

  @override
  Future<ResolvedSong?> resolveTopOne(SpeakerResolveRequest request) async {
    final deadline = _now().add(_resolveBudget);
    final exact = request.exactMusic;
    if (exact is MusicInfo) {
      return _resolveExact(exact, deadline);
    }

    var resolved = await _searchAndResolve(request.keyword, request, deadline);
    if (resolved != null) return resolved;

    // topone 规范的空白变体重试：ASR/曲库的空格差异会整批错过。
    final compact = request.keyword.replaceAll(RegExp(r'\s+'), '');
    if (compact.isNotEmpty && compact != request.keyword) {
      if (_now().isAfter(deadline)) return null;
      resolved = await _searchAndResolve(compact, request, deadline);
    }
    return resolved;
  }

  Future<ResolvedSong?> _searchAndResolve(
    String keyword,
    SpeakerResolveRequest request,
    DateTime deadline,
  ) async {
    final SearchResponse response;
    try {
      response = await _api.searchMusic(
        keyword: keyword,
        source: MusicSource.all,
        limit: 30,
      );
    } catch (_) {
      return null;
    }
    final candidates = [...response.list];
    if (candidates.isEmpty) return null;
    // 按 hint 打分排序（稳定排序，同分保持搜索原序）。
    final scored = [
      for (var i = 0; i < candidates.length; i++)
        (index: i, info: candidates[i], score: _score(candidates[i], request)),
    ]..sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      return byScore != 0 ? byScore : a.index.compareTo(b.index);
    });

    var tried = 0;
    for (final entry in scored) {
      if (tried >= _maxCandidates) break;
      if (_now().isAfter(deadline)) {
        _onLog?.call('speaker resolve budget exhausted');
        return null;
      }
      tried++;
      final resolved = await _resolveExact(entry.info, deadline);
      if (resolved != null) return resolved;
    }
    return null;
  }

  Future<ResolvedSong?> _resolveExact(MusicInfo music, DateTime deadline) async {
    final qualities = <Quality>[];
    final seen = <Quality>{};
    // 先 MP3 音质（按原排序），再其余音质兜底。
    for (final pass in [true, false]) {
      for (final option in music.sortedQualities) {
        final quality = option.type;
        if ((quality.extension == 'mp3') != pass) continue;
        if (seen.add(quality)) qualities.add(quality);
      }
    }
    var attempts = 0;
    for (final quality in qualities) {
      if (attempts >= _maxQualityAttempts) break;
      if (_now().isAfter(deadline)) {
        _onLog?.call('speaker resolve budget exhausted');
        return null;
      }
      attempts++;
      final MusicUrl result;
      try {
        result = await _urlResolver.resolve(music: music, quality: quality);
      } catch (_) {
        continue;
      }
      final url = result.url.trim();
      if (url.isEmpty) continue;
      if (!isSpeakerPlayableUrl(url)) continue;
      try {
        final probe = await _urlProbe.probe(
          url,
          expectedDurationMs: parseMusicIntervalMs(music.interval),
        );
        if (!probe.ok) {
          _onLog?.call('speaker probe rejected ${probe.rejectReason}');
          continue;
        }
      } catch (e) {
        _onLog?.call('speaker probe rejected error: $e');
        continue;
      }
      return ResolvedSong(
        url: url,
        title: music.name,
        artist: music.singer,
        durationMs: parseMusicIntervalMs(music.interval),
        sourceName: music.source.label,
        qualityLabel: quality.code,
      );
    }
    return null;
  }

  int _score(MusicInfo info, SpeakerResolveRequest request) {
    final name = _normText(info.name);
    final singer = _normText(info.singer);
    final hintTitle = _normText(request.hintTitle ?? request.keyword);
    final hintArtist = _normText(request.hintArtist ?? '');
    var score = 0;
    if (hintTitle.isNotEmpty) {
      if (name == hintTitle) {
        score += 100;
      } else if (name.contains(hintTitle) || hintTitle.contains(name)) {
        score += 50;
      }
    }
    if (hintArtist.isNotEmpty && singer.isNotEmpty) {
      if (singer == hintArtist) {
        score += 60;
      } else if (singer.contains(hintArtist) || hintArtist.contains(singer)) {
        score += 40;
      }
    }
    return score;
  }

  static String _normText(String text) =>
      text.toLowerCase().replaceAll(RegExp(r'[\s\p{P}]+', unicode: true), '');
}

/// 「该歌之后」的音箱队列：按歌名/歌手在 App 当前队列里定位
/// [song]，取其后的部分。定位不到（语音点的歌不在队列里）返回
/// 空列表——只播这一首，不硬凑接力。
List<SpeakerQueueItem> buildSpeakerQueueTail(
  PlayerState playerState,
  ResolvedSong song,
) {
  final queue = playerState.queue;
  if (queue.isEmpty) return const [];
  final title = _normForMatch(song.title);
  final artist = _normForMatch(song.artist);
  var anchor = -1;
  // 优先从当前播放位置开始找（同一首歌在队列里出现多次时，
  // 用户多半指的是正在播的那个位置）。
  for (var i = playerState.queueIndex; i < queue.length; i++) {
    if (i < 0) continue;
    final entry = queue[i];
    if (_normForMatch(entry.name) == title &&
        (artist.isEmpty || _normForMatch(entry.singer) == artist)) {
      anchor = i;
      break;
    }
  }
  if (anchor < 0) return const [];
  return [
    for (var i = anchor + 1; i < queue.length; i++)
      SpeakerQueueItem(
        title: queue[i].name,
        artist: queue[i].singer,
        durationMs: parseMusicIntervalMs(queue[i].musicInfo?.interval),
        exactMusic: queue[i].musicInfo,
      ),
  ];
}

String _normForMatch(String text) =>
    text.toLowerCase().replaceAll(RegExp(r'[\s\p{P}]+', unicode: true), '');

/// 解析 MusicInfo.interval 时长文本（"mm:ss" / "hh:mm:ss" / 纯秒数）。
int? parseMusicIntervalMs(String? interval) {
  if (interval == null) return null;
  final text = interval.trim();
  if (text.isEmpty) return null;
  if (text.contains(':')) {
    var totalSeconds = 0;
    for (final part in text.split(':')) {
      final value = int.tryParse(part.trim());
      if (value == null) return null;
      totalSeconds = totalSeconds * 60 + value;
    }
    return totalSeconds * 1000;
  }
  final seconds = int.tryParse(text);
  return seconds == null ? null : seconds * 1000;
}
