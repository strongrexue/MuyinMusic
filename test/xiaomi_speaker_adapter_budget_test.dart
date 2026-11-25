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

MusicInfo fakeSong(String id, [MusicSource source = MusicSource.tx]) =>
    MusicInfo(
  id: id,
  name: '晴天',
  singer: '周杰伦',
  source: source,
  interval: '04:29',
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
  var searchCalls = 0;

  @override
  Future<SearchResponse> searchMusic({
    required String keyword,
    required MusicSource source,
    int page = 1,
    int limit = 30,
  }) async {
    searchCalls++;
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
  var resolveCalls = 0;

  @override
  Future<MusicUrl> resolve({
    required MusicInfo music,
    required Quality quality,
  }) async {
    resolveCalls++;
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

/// 探测一律淘汰的假探测器（让解析只能靠预算/候选上限收场）。
class RejectingProbe extends SpeakerUrlProbe {
  var probeCalls = 0;

  @override
  Future<ProbeResult> probe(String url, {int? expectedDurationMs}) async {
    probeCalls++;
    return const ProbeResult(ok: false, rejectReason: 'not-mp3');
  }
}

/// 探测一律放行的假探测器。
class AcceptingProbe extends SpeakerUrlProbe {
  @override
  Future<ProbeResult> probe(String url, {int? expectedDurationMs}) async {
    return const ProbeResult(ok: true, estimatedDurationMs: 269000);
  }
}

void main() {
  group('PanghuSpeakerSongResolver 解析预算', () {
    test('预算耗尽后不再试新候选，如实未命中', () async {
      final api = FakeMusicApi([fakeSong('1'), fakeSong('2'), fakeSong('3')]);
      final urlResolver = FakeUrlResolver();
      final probe = RejectingProbe();
      final t0 = DateTime(2026, 1, 1, 12);
      var nowCalls = 0;
      // 每次读时钟前进 4s：候选 1 尝试时还在预算内，
      // 候选 2 之前已越过 8s 预算线。
      DateTime tickingNow() {
        nowCalls++;
        return t0.add(Duration(seconds: nowCalls * 4));
      }

      final resolver = PanghuSpeakerSongResolver(
        api: api,
        urlResolver: urlResolver,
        urlProbe: probe,
        resolveBudget: const Duration(seconds: 8),
        now: tickingNow,
      );
      final result = await resolver.resolveTopOne(
        const SpeakerResolveRequest(keyword: '周杰伦晴天'),
      );
      expect(result, isNull);
      expect(urlResolver.resolveCalls, 1); // 只试了候选 1
    });

    test('预算充足时逐个候选试满（对照组）', () async {
      final api = FakeMusicApi([fakeSong('1'), fakeSong('2'), fakeSong('3')]);
      final urlResolver = FakeUrlResolver();
      final probe = RejectingProbe();
      final t0 = DateTime(2026, 1, 1, 12);
      final resolver = PanghuSpeakerSongResolver(
        api: api,
        urlResolver: urlResolver,
        urlProbe: probe,
        resolveBudget: const Duration(seconds: 8),
        now: () => t0,
      );
      final result = await resolver.resolveTopOne(
        const SpeakerResolveRequest(keyword: '周杰伦晴天'),
      );
      expect(result, isNull);
      expect(urlResolver.resolveCalls, 3);
      expect(probe.probeCalls, 3);
    });

    test('同分候选优先酷我（与 TrackFerry 洛雪路由对齐）', () async {
      // 同名同歌手同分：QQ 在搜索原序靠前，仍应先试酷我并命中。
      final api = FakeMusicApi([
        fakeSong('tx-1', MusicSource.tx),
        fakeSong('kw-1', MusicSource.kw),
      ]);
      final urlResolver = FakeUrlResolver();
      final resolver = PanghuSpeakerSongResolver(
        api: api,
        urlResolver: urlResolver,
        urlProbe: AcceptingProbe(),
        resolveBudget: const Duration(seconds: 8),
        now: () => DateTime(2026, 1, 1, 12),
      );
      final result = await resolver.resolveTopOne(
        const SpeakerResolveRequest(keyword: '周杰伦晴天'),
      );
      expect(result, isNotNull);
      expect(result!.url, 'http://example.com/kw-1.mp3');
      expect(urlResolver.resolveCalls, 1); // 酷我一次命中，没轮到 QQ
    });
  });
}
