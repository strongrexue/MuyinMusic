import 'package:flutter_test/flutter_test.dart';
import 'package:muyin_music/core/xiaomi/mina_models.dart';
import 'package:muyin_music/core/xiaomi/takeover/conversation_monitor.dart';

import 'xiaomi_takeover_test_utils.dart';

ConversationRecord rec(int timeMs, String query) =>
    ConversationRecord(timeMs: timeMs, query: query, answers: const []);

void main() {
  group('ConversationMonitor 基线与去重', () {
    test('首轮只建基线不投递', () async {
      final delivered = <String>[];
      final results = <ConversationFetchResult>[
        ConversationFetchSuccess([rec(1000, '播放a'), rec(2000, '播放b')]),
      ];
      final monitor = ConversationMonitor(
        fetcher: () async => results.removeAt(0),
        clock: FakeTakeoverClock(),
        onRecord: (r) => delivered.add(r.query),
      );
      expect(await monitor.pollOnce(), PollOutcome.primed);
      expect(delivered, isEmpty);
      expect(monitor.baselineMs, 2000);
    });

    test('只投递基线之后的新指令', () async {
      final delivered = <String>[];
      final results = <ConversationFetchResult>[
        ConversationFetchSuccess([rec(2000, '播放b')]),
        ConversationFetchSuccess([rec(2000, '播放b'), rec(3000, '播放c')]),
      ];
      final monitor = ConversationMonitor(
        fetcher: () async => results.removeAt(0),
        clock: FakeTakeoverClock(),
        onRecord: (r) => delivered.add(r.query),
      );
      await monitor.pollOnce();
      expect(await monitor.pollOnce(), PollOutcome.delivered);
      expect(delivered, ['播放c']);
      expect(monitor.baselineMs, 3000);
    });

    test('同时间戳不同 query 不互相吞', () async {
      final delivered = <String>[];
      final results = <ConversationFetchResult>[
        ConversationFetchSuccess([rec(2000, '播放b')]),
        ConversationFetchSuccess([rec(2000, '下一首')]),
      ];
      final monitor = ConversationMonitor(
        fetcher: () async => results.removeAt(0),
        clock: FakeTakeoverClock(),
        onRecord: (r) => delivered.add(r.query),
      );
      await monitor.pollOnce();
      expect(await monitor.pollOnce(), PollOutcome.delivered);
      expect(delivered, ['下一首']);
    });

    test('失败不建基线：恢复后首轮仍只建基线', () async {
      final delivered = <String>[];
      final results = <ConversationFetchResult>[
        const ConversationFetchFailure('network'),
        ConversationFetchSuccess([rec(1000, '播放a')]),
      ];
      final monitor = ConversationMonitor(
        fetcher: () async => results.removeAt(0),
        clock: FakeTakeoverClock(),
        onRecord: (r) => delivered.add(r.query),
      );
      expect(await monitor.pollOnce(), PollOutcome.failed);
      expect(monitor.isPrimed, isFalse);
      expect(await monitor.pollOnce(), PollOutcome.primed);
      expect(delivered, isEmpty);
    });

    test('失败不推进基线：恢复后新指令照常投递', () async {
      final delivered = <String>[];
      final results = <ConversationFetchResult>[
        ConversationFetchSuccess([rec(2000, '播放b')]),
        const ConversationFetchFailure('timeout'),
        ConversationFetchSuccess([rec(2500, '播放c')]),
      ];
      final monitor = ConversationMonitor(
        fetcher: () async => results.removeAt(0),
        clock: FakeTakeoverClock(),
        onRecord: (r) => delivered.add(r.query),
      );
      await monitor.pollOnce();
      expect(await monitor.pollOnce(), PollOutcome.failed);
      expect(monitor.baselineMs, 2000);
      expect(await monitor.pollOnce(), PollOutcome.delivered);
      expect(delivered, ['播放c']);
    });

    test('失败退避递增并封顶 30s', () async {
      final monitor = ConversationMonitor(
        fetcher: () async => const ConversationFetchFailure('x'),
        clock: FakeTakeoverClock(),
        onRecord: (_) {},
      );
      await monitor.pollOnce();
      expect(monitor.currentBackoff, const Duration(seconds: 1));
      await monitor.pollOnce();
      expect(monitor.currentBackoff, const Duration(seconds: 2));
      await monitor.pollOnce();
      await monitor.pollOnce();
      await monitor.pollOnce();
      await monitor.pollOnce();
      await monitor.pollOnce();
      expect(monitor.currentBackoff, const Duration(seconds: 30));
    });

    test('默认轮询间隔为 500ms（TrackFerry 实证值）', () {
      final monitor = ConversationMonitor(
        fetcher: () async => const ConversationFetchSuccess([]),
        clock: FakeTakeoverClock(),
        onRecord: (_) {},
      );
      expect(monitor.pollInterval, const Duration(milliseconds: 500));
    });
  });

  group('ConversationMonitor 启停循环', () {
    test('start 后立即轮询一轮，间隔 500ms 再轮，stop 后不再轮询', () async {
      var fetchCount = 0;
      final clock = FakeTakeoverClock();
      final monitor = ConversationMonitor(
        fetcher: () async {
          fetchCount++;
          return const ConversationFetchSuccess([]);
        },
        clock: clock,
        onRecord: (_) {},
      );
      monitor.start();
      await pumpMicrotasks();
      expect(fetchCount, 1);
      clock.advance(const Duration(milliseconds: 500));
      await pumpMicrotasks();
      expect(fetchCount, 2);
      monitor.stop();
      clock.advance(const Duration(seconds: 10));
      await pumpMicrotasks();
      expect(fetchCount, 2);
    });
  });
}
