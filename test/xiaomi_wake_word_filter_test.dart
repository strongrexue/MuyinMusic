import 'package:flutter_test/flutter_test.dart';

import 'package:muyin_music/core/xiaomi/takeover/speaker_intent.dart';
import 'package:muyin_music/core/xiaomi/takeover/wake_word_filter.dart';

void main() {
  group('WakeWordFilter 关闭/直通', () {
    test('disabled 时点歌文本原样直通', () {
      const filter = WakeWordFilter.disabled();
      expect(filter.apply('播放周杰伦的晴天'), '播放周杰伦的晴天');
    });

    test('disabled 时控制指令文本原样直通', () {
      const filter = WakeWordFilter.disabled();
      expect(filter.apply('下一首'), '下一首');
    });

    test('enabled=false 且带词时仍直通', () {
      const filter = WakeWordFilter(enabled: false, word: '胖虎');
      expect(filter.apply('播放晴天'), '播放晴天');
    });

    test('word 为空白时直通', () {
      const filter = WakeWordFilter(enabled: true, word: '   ');
      expect(filter.apply('播放晴天'), '播放晴天');
      expect(filter.apply('下一首'), '下一首');
    });
  });

  group('WakeWordFilter 开启未命中 → null（放行原生）', () {
    const filter = WakeWordFilter(enabled: true, word: kDefaultWakeWord);

    test('点歌指令不含口令 → null', () {
      expect(filter.apply('播放周杰伦的晴天'), isNull);
    });

    test('控制指令不含口令 → null', () {
      expect(filter.apply('下一首'), isNull);
    });
  });

  group('WakeWordFilter 剥除口令', () {
    const filter = WakeWordFilter(enabled: true, word: kDefaultWakeWord);

    test('「胖虎，播放周杰伦的晴天」→「播放周杰伦的晴天」', () {
      expect(filter.apply('胖虎，播放周杰伦的晴天'), '播放周杰伦的晴天');
    });

    test('「胖虎播放晴天」→「播放晴天」', () {
      expect(filter.apply('胖虎播放晴天'), '播放晴天');
    });

    test('「胖虎 播放晴天」→「播放晴天」', () {
      expect(filter.apply('胖虎 播放晴天'), '播放晴天');
    });

    test('「请胖虎播放晴天」→「请播放晴天」', () {
      expect(filter.apply('请胖虎播放晴天'), '请播放晴天');
    });

    test('「胖虎，下一首」→「下一首」', () {
      expect(filter.apply('胖虎，下一首'), '下一首');
    });

    test('只有口令无指令 → 空串', () {
      expect(filter.apply('胖虎'), '');
    });
  });

  group('WakeWordFilter × parseSpeakerIntent', () {
    const filter = WakeWordFilter(enabled: true, word: kDefaultWakeWord);

    test('「胖虎，播放周杰伦的晴天」→ PlaySongIntent 且 raw 为剥除后文本', () {
      final query = filter.apply('胖虎，播放周杰伦的晴天');
      final intent = parseSpeakerIntent(query!);
      expect(intent, isA<PlaySongIntent>());
      expect(intent!.raw, '播放周杰伦的晴天');
    });

    test('「胖虎，下一首」→ NextIntent', () {
      final query = filter.apply('胖虎，下一首');
      expect(parseSpeakerIntent(query!), isA<NextIntent>());
    });

    test('未命中口令时不进解析器（apply 返回 null）', () {
      expect(filter.apply('播放周杰伦的晴天'), isNull);
    });
  });

  group('WakeWordFilter 自定义口令词', () {
    const filter = WakeWordFilter(enabled: true, word: '阿虎');

    test('自定义词命中并剥除', () {
      expect(filter.apply('阿虎，播放晴天'), '播放晴天');
    });

    test('默认词不再命中', () {
      expect(filter.apply('胖虎，播放晴天'), isNull);
    });
  });
}
