import 'package:flutter_test/flutter_test.dart';
import 'package:muyin_music/core/xiaomi/takeover/takeover_state.dart';

TakeoverRecord rec(int i) => TakeoverRecord(
      query: 'q$i',
      title: 't$i',
      artist: 'a',
      atMs: i,
      success: true,
    );

void main() {
  group('prependTakeoverRecord', () {
    test('连续 prepend 不丢旧记录', () {
      var records = <TakeoverRecord>[];
      for (var i = 0; i < 5; i++) {
        records = prependTakeoverRecord(records, rec(i));
      }
      expect(records, hasLength(5));
      expect(records.map((r) => r.title), ['t4', 't3', 't2', 't1', 't0']);
    });

    test('顺序新→旧', () {
      final records = prependTakeoverRecord([rec(1), rec(0)], rec(2));
      expect(records.map((r) => r.atMs), [2, 1, 0]);
    });

    test('超 10 条淘汰最旧', () {
      var records = <TakeoverRecord>[];
      for (var i = 0; i < 12; i++) {
        records = prependTakeoverRecord(records, rec(i));
      }
      expect(records, hasLength(kMaxTakeoverRecords));
      expect(records.first.title, 't11');
      expect(records.last.title, 't2'); // t0/t1 已被淘汰
    });

    test('不改入参且返回不可变列表', () {
      final current = [rec(0)];
      final next = prependTakeoverRecord(current, rec(1));
      expect(current, hasLength(1));
      expect(() => next.add(rec(2)), throwsUnsupportedError);
    });
  });
}
