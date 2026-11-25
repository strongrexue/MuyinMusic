import 'package:flutter_test/flutter_test.dart';
import 'package:muyin_music/core/api/music_api.dart';
import 'package:muyin_music/core/models/enums.dart';
import 'package:muyin_music/core/models/music_info.dart';
import 'package:muyin_music/core/models/music_url.dart';
import 'package:muyin_music/core/models/search_response.dart';
import 'package:muyin_music/core/music_sources/music_url_resolver.dart';
import 'package:muyin_music/core/xiaomi/panghu_speaker_adapter.dart';
import 'package:muyin_music/core/xiaomi/speaker_url_probe.dart';
import 'package:muyin_music/core/xiaomi/takeover/speaker_resolver.dart';

MusicInfo fakeSong({String? interval}) => MusicInfo(
  id: '1',
  name: '晴天',
  singer: '周杰伦',
  source: MusicSource.tx,
  interval: interval,
  meta: const MusicMeta(
    songId: 'song-1',
    albumName: '叶惠美',
    qualitys: [QualityOption(type: Quality.k320)],
    raw: {},
  ),
  raw: const {},
);

class FakeMusicApi extends MusicApi {
  FakeMusicApi(this.candidates);

  final List<MusicInfo> candidates;

  @override
  Future<SearchResponse> searchMusic({
    required String keyword,
    required MusicSource source,
    int page = 1,
    int limit = 30,
  }) async {
    return SearchResponse(
      list: candidates,
      page: 1,
      limit: limit,
      allPage: 1,
      total: candidates.length,
      source: MusicSource.all,
    );
  }
}

class FakeUrlResolver implements MusicUrlResolver {
  @override
  Future<MusicUrl> resolve({
    required MusicInfo music,
    required Quality quality,
  }) async {
    return MusicUrl(url: 'http://example.com/${music.id}.mp3');
  }

  @override
  Future<Quality> highestQualityFor(MusicInfo music) async => Quality.k320;

  @override
  Future<MusicSourceFallbackResult<T>> useFirstAvailable<T>({
    required MusicInfo music,
    required Quality quality,
    required MusicSourceUrlConsumer<T> use,
    Set<String> excludedSourceIds = const <String>{},
    bool Function()? isCancelled,
    bool Function(Object error)? shouldFallbackOnConsumerError,
  }) {
    throw UnimplementedError();
  }
}

/// 探测通过且带实测时长估算的假探测器。
class EstimatingProbe extends SpeakerUrlProbe {
  EstimatingProbe(this.estimatedDurationMs);

  final int? estimatedDurationMs;

  @override
  Future<ProbeResult> probe(String url, {int? expectedDurationMs}) async {
    return ProbeResult(ok: true, estimatedDurationMs: estimatedDurationMs);
  }
}

void main() {
  group('ResolvedSong 时长链', () {
    Future<dynamic> resolve(MusicInfo song, int? estimated) async {
      final resolver = PanghuSpeakerSongResolver(
        api: FakeMusicApi([song]),
        urlResolver: FakeUrlResolver(),
        urlProbe: EstimatingProbe(estimated),
      );
      return resolver.resolveTopOne(
        const SpeakerResolveRequest(keyword: '周杰伦晴天'),
      );
    }

    test('候选 interval 缺失 → 用探测实测时长兜底', () async {
      final result = await resolve(fakeSong(interval: null), 300000);
      expect(result, isNotNull);
      expect(result!.durationMs, 300000);
    });

    test('候选 interval 有值 → 仍以 interval 为准', () async {
      final result = await resolve(fakeSong(interval: '04:29'), 300000);
      expect(result, isNotNull);
      expect(result!.durationMs, 269000);
    });

    test('interval 与实测皆无 → durationMs 为 null（判尾只能靠 restarted）', () async {
      final result = await resolve(fakeSong(interval: null), null);
      expect(result, isNotNull);
      expect(result!.durationMs, isNull);
    });
  });
}
