import 'package:flutter_test/flutter_test.dart';
import 'package:muyin_music/core/xiaomi/mina_models.dart';
import 'package:muyin_music/core/xiaomi/takeover/conversation_monitor.dart';

import 'xiaomi_takeover_test_utils.dart';

ConversationRecord rec(int timeMs, String query, {String? requestId}) =>
    ConversationRecord(
      timeMs: timeMs,
      query: query,
      answers: const [],
      requestId: requestId,
    );

void main() {
  group('ConversationRecord.requestId 解析', () {
    test('fromJson 读 requestId，空串归一为 null，数字归一为字符串', () {
      final withId = ConversationRecord.fromJson({
        'time': 1000,
        'query': '播放a',
        'requestId': 'req-1',
      });
      expect(withId.requestId, 'req-1');

      final empty = ConversationRecord.fromJson({
        'time': 1000,
        'query': '播放a',
        'requestId': '',
      });
      expect(empty.requestId, isNull);

      final missing = ConversationRecord.fromJson({
        'time': 1000,
        'query': '播放a',
      });
      expect(missing.requestId, isNull);

      final numeric = ConversationRecord.fromJson({
        'time': 1000,
        'query': '播放a',
        'requestId': 42,
      });
      expect(numeric.requestId, '42');
    });
  });

  group('ConversationMonitor 基线与去重', () {
    test('首轮只建基线不投递', () async {
      final delivered = <String>[];
      final results = <ConversationFetchResult>[
        ConversationFetchSuccess([rec(1000, '播放a'), rec(2000, '播放b')]),
      ];
      final monitor = ConversationMonitor(
        fetcher: () async => results.removeAt(0),
        clock: FakeTakeoverClock(),
        onRecord: (r, seenMs) => delivered.add(r.query),
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
        onRecord: (r, seenMs) => delivered.add(r.query),
      );
      await monitor.pollOnce();
      expect(await monitor.pollOnce(), PollOutcome.delivered);
      expect(delivered, ['播放c']);
      expect(monitor.baselineMs, 3000);
    });

    test('同时间戳不同 query 不互相吞（兜底键 t<time>|<query>）', () async {
      final delivered = <String>[];
      final results = <ConversationFetchResult>[
        ConversationFetchSuccess([rec(2000, '播放b')]),
        ConversationFetchSuccess([rec(2000, '下一首')]),
      ];
      final monitor = ConversationMonitor(
        fetcher: () async => results.removeAt(0),
        clock: FakeTakeoverClock(),
        onRecord: (r, seenMs) => delivered.add(r.query),
      );
      await monitor.pollOnce();
      expect(await monitor.pollOnce(), PollOutcome.delivered);
      expect(delivered, ['下一首']);
    });

    test('同时间戳同 query 不同 requestId 不互相吞', () async {
      final delivered = <String>[];
      final results = <ConversationFetchResult>[
        ConversationFetchSuccess([rec(2000, '播放b', requestId: 'r1')]),
        ConversationFetchSuccess([rec(2000, '播放b', requestId: 'r2')]),
      ];
      final monitor = ConversationMonitor(
        fetcher: () async => results.removeAt(0),
        clock: FakeTakeoverClock(),
        onRecord: (r, seenMs) => delivered.add(r.requestId!),
      );
      await monitor.pollOnce();
      expect(await monitor.pollOnce(), PollOutcome.delivered);
      expect(delivered, ['r2']);
    });

    test('同 requestId 重复投递只交一次（同轮重复与跨轮重现）', () async {
      final delivered = <String>[];
      final results = <ConversationFetchResult>[
        ConversationFetchSuccess([rec(2000, '播放b', requestId: 'r1')]),
        // 同一轮里同 requestId 出现两次。
        ConversationFetchSuccess([
          rec(3000, '播放c', requestId: 'r2'),
          rec(3000, '播放c', requestId: 'r2'),
        ]),
        // 下一轮同 requestId 再次出现（仍在拉取窗口内）。
        ConversationFetchSuccess([rec(3000, '播放c', requestId: 'r2')]),
      ];
      final monitor = ConversationMonitor(
        fetcher: () async => results.removeAt(0),
        clock: FakeTakeoverClock(),
        onRecord: (r, seenMs) => delivered.add(r.requestId!),
      );
      await monitor.pollOnce();
      expect(await monitor.pollOnce(), PollOutcome.delivered);
      expect(delivered, ['r2']);
      expect(await monitor.pollOnce(), PollOutcome.idle);
      expect(delivered, ['r2']);
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
        onRecord: (r, seenMs) => delivered.add(r.query),
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
        onRecord: (r, seenMs) => delivered.add(r.query),
      );
      await monitor.pollOnce();
      expect(await monitor.pollOnce(), PollOutcome.failed);
      expect(monitor.baselineMs, 2000);
      expect(await monitor.pollOnce(), PollOutcome.delivered);
      expect(delivered, ['播放c']);
    });

    test('默认轮询间隔为 500ms（TrackFerry 实证值）', () {
      final monitor = ConversationMonitor(
        fetcher: () async => const ConversationFetchSuccess([]),
        clock: FakeTakeoverClock(),
        onRecord: (r, seenMs) {},
      );
      expect(monitor.pollInterval, const Duration(milliseconds: 500));
    });
  });

  group('ConversationMonitor seenMs 与 stale', () {
    test('seenMs 为本轮 poll 开始时刻，同轮每条相同；stale 记录照常投递', () async {
      final delivered = <(String, int)>[];
      final clock = FakeTakeoverClock(500000);
      final results = <ConversationFetchResult>[
        ConversationFetchSuccess([rec(1000, '播放a')]),
        // timeMs=2000，seenMs=500000，lag=498s > staleAfter(2min)：
        // stale 只标记不丢弃，monitor 照常投递，分发层决定不执行。
        ConversationFetchSuccess([rec(2000, '播放b'), rec(3000, '播放c')]),
      ];
      final monitor = ConversationMonitor(
        fetcher: () async => results.removeAt(0),
        clock: clock,
        onRecord: (r, seenMs) => delivered.add((r.query, seenMs)),
      );
      await monitor.pollOnce();
      expect(await monitor.pollOnce(), PollOutcome.delivered);
      expect(delivered, [('播放b', 500000), ('播放c', 500000)]);
      expect(ConversationMonitor.staleAfterMs, 120000);
    });

    test('seenMs 随每轮 poll 开始时刻变化', () async {
      final seen = <int>[];
      final clock = FakeTakeoverClock(10000);
      final results = <ConversationFetchResult>[
        ConversationFetchSuccess([rec(1000, '播放a')]),
        ConversationFetchSuccess([rec(2000, '播放b')]),
        ConversationFetchSuccess([rec(3000, '播放c')]),
      ];
      final monitor = ConversationMonitor(
        fetcher: () async => results.removeAt(0),
        clock: clock,
        onRecord: (r, seenMs) => seen.add(seenMs),
      );
      await monitor.pollOnce();
      clock.advance(const Duration(milliseconds: 700));
      await monitor.pollOnce();
      clock.advance(const Duration(milliseconds: 1300));
      await monitor.pollOnce();
      expect(seen, [10700, 12000]);
    });
  });

  // 退避公式（蓝本 internal/observe/observe.go poll 失败分支）：
  // backoff = (pollInterval×2) << min(streak, 5)，基数 1s 与蓝本
  // interval=1s 对齐；网络类封顶 maxOffline=5s；被拒类 streak>3 时
  // 按蓝本被拒分支 (基数 << min(streak, 10)) 封顶 maxRefused=5min；
  // 其余不封顶（公式上限 32s）。旧期望「封顶 30s」已按此重算废弃。
  group('ConversationMonitor 失败退避（蓝本公式）', () {
    ConversationMonitor failingMonitor(String reason) => ConversationMonitor(
      fetcher: () async => ConversationFetchFailure(reason),
      clock: FakeTakeoverClock(),
      onRecord: (r, seenMs) {},
    );

    test('普通（非网络非被拒，如 protocol）：公式递增，上限 32s 不封顶', () async {
      final monitor = failingMonitor('protocol: unreadable');
      await monitor.pollOnce();
      expect(monitor.currentBackoff, const Duration(seconds: 2)); // 1s<<1
      await monitor.pollOnce();
      expect(monitor.currentBackoff, const Duration(seconds: 4)); // 1s<<2
      await monitor.pollOnce();
      expect(monitor.currentBackoff, const Duration(seconds: 8)); // 1s<<3
      await monitor.pollOnce();
      expect(monitor.currentBackoff, const Duration(seconds: 16)); // 1s<<4
      await monitor.pollOnce();
      expect(monitor.currentBackoff, const Duration(seconds: 32)); // 1s<<5
      await monitor.pollOnce();
      expect(monitor.currentBackoff, const Duration(seconds: 32)); // 移位封顶 5
    });

    test('网络类：封顶 5s（蓝本 maxOffline）', () async {
      final monitor = failingMonitor('transport: connection reset');
      await monitor.pollOnce();
      expect(monitor.currentBackoff, const Duration(seconds: 2));
      await monitor.pollOnce();
      expect(monitor.currentBackoff, const Duration(seconds: 4));
      await monitor.pollOnce();
      // 1s<<3=8s → 封顶 5s。
      expect(monitor.currentBackoff, const Duration(seconds: 5));
      await monitor.pollOnce();
      await monitor.pollOnce();
      expect(monitor.currentBackoff, const Duration(seconds: 5));
    });

    test('拿不准的原因按网络类（蓝本 KindOf 默认 network）', () async {
      final monitor = failingMonitor('x');
      await monitor.pollOnce();
      await monitor.pollOnce();
      await monitor.pollOnce();
      expect(monitor.currentBackoff, const Duration(seconds: 5));
    });

    test('被拒类（unauthorized）：streak>3 后按被拒分支递增，封顶 5 分钟', () async {
      final monitor = failingMonitor('unauthorized: serviceToken rejected');
      await monitor.pollOnce();
      expect(monitor.currentBackoff, const Duration(seconds: 2)); // streak≤3 走公式
      await monitor.pollOnce();
      await monitor.pollOnce();
      expect(monitor.currentBackoff, const Duration(seconds: 8)); // 1s<<3
      await monitor.pollOnce();
      expect(monitor.currentBackoff, const Duration(seconds: 16)); // 1s<<4
      await monitor.pollOnce();
      await monitor.pollOnce();
      await monitor.pollOnce();
      await monitor.pollOnce();
      expect(monitor.currentBackoff, const Duration(seconds: 256)); // 1s<<8
      await monitor.pollOnce();
      // 1s<<9=512s → 封顶 maxRefused=5min。
      expect(monitor.currentBackoff, const Duration(minutes: 5));
      await monitor.pollOnce();
      expect(monitor.currentBackoff, const Duration(minutes: 5));
    });

    test('成功后退避归零', () async {
      var fail = true;
      final monitor = ConversationMonitor(
        fetcher: () async => fail
            ? const ConversationFetchFailure('transport: down')
            : const ConversationFetchSuccess([]),
        clock: FakeTakeoverClock(),
        onRecord: (r, seenMs) {},
      );
      await monitor.pollOnce();
      expect(monitor.currentBackoff, const Duration(seconds: 2));
      fail = false;
      await monitor.pollOnce();
      expect(monitor.currentBackoff, Duration.zero);
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
        onRecord: (r, seenMs) {},
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

    test('节奏：本轮耗时 200ms 时只睡 300ms，下一轮在开始后 500ms 触发', () async {
      var fetchCount = 0;
      final clock = FakeTakeoverClock();
      final monitor = ConversationMonitor(
        fetcher: () async {
          fetchCount++;
          // 模拟本轮拉取耗时 200ms（蓝本 ticker 语义：周期从轮开始算）。
          clock.advance(const Duration(milliseconds: 200));
          return const ConversationFetchSuccess([]);
        },
        clock: clock,
        onRecord: (r, seenMs) {},
      );
      monitor.start();
      await pumpMicrotasks();
      expect(fetchCount, 1);
      expect(clock.sleepRequests.last, const Duration(milliseconds: 300));
      clock.advance(const Duration(milliseconds: 300));
      await pumpMicrotasks();
      // 第二轮在第一轮开始后 500ms（而非结束后 500ms）触发。
      expect(fetchCount, 2);
      expect(clock.nowMs(), 700); // 500（周期）+ 200（第二轮耗时）
      monitor.stop();
    });

    test('节奏：本轮超时（耗时 700ms > 500ms）下一轮立即开始', () async {
      var fetchCount = 0;
      final clock = FakeTakeoverClock();
      final monitor = ConversationMonitor(
        fetcher: () async {
          fetchCount++;
          clock.advance(const Duration(milliseconds: 700));
          return const ConversationFetchSuccess([]);
        },
        clock: clock,
        onRecord: (r, seenMs) {},
      );
      monitor.start();
      await pumpMicrotasks();
      expect(fetchCount, 1);
      expect(clock.sleepRequests.last, Duration.zero);
      clock.advance(Duration.zero);
      await pumpMicrotasks();
      expect(fetchCount, 2);
      monitor.stop();
    });
  });
}
