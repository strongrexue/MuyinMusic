import 'package:flutter_test/flutter_test.dart';
import 'package:muyin_music/core/xiaomi/takeover/takeover_log.dart';

void main() {
  group('TakeoverLogBuffer', () {
    test('add 带 HH:mm:ss 时间戳前缀', () {
      final buffer = TakeoverLogBuffer(
        now: () => DateTime(2026, 11, 25, 16, 20, 5),
      );
      buffer.add('takeover mute failed');
      expect(buffer.entries, ['16:20:05 takeover mute failed']);
    });

    test('超过上限丢最旧（默认 100 条）', () {
      final buffer = TakeoverLogBuffer(
        now: () => DateTime(2026, 11, 25, 0, 0, 0),
      );
      for (var i = 1; i <= 105; i++) {
        buffer.add('line $i');
      }
      expect(buffer.entries, hasLength(100));
      expect(buffer.entries.first, endsWith('line 6'));
      expect(buffer.entries.last, endsWith('line 105'));
    });

    test('onChanged 收到截断后的全量快照（落盘钩子）', () {
      List<String>? persisted;
      final buffer = TakeoverLogBuffer(
        maxEntries: 3,
        now: () => DateTime(2026, 11, 25, 1, 2, 3),
        onChanged: (entries) => persisted = entries,
      );
      buffer.add('a');
      buffer.add('b');
      buffer.add('c');
      buffer.add('d');
      expect(persisted, buffer.entries);
      expect(persisted, hasLength(3));
      expect(persisted!.first, endsWith('b'));
    });

    test('initial 条目保留并参与截断', () {
      final buffer = TakeoverLogBuffer(
        initial: const ['old 1', 'old 2', 'old 3'],
        maxEntries: 3,
        now: () => DateTime(2026, 11, 25, 1, 2, 3),
      );
      buffer.add('new');
      expect(buffer.entries, hasLength(3));
      expect(buffer.entries.first, 'old 2');
      expect(buffer.entries.last, endsWith('new'));
    });
  });
}
