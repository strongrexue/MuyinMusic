import 'package:test/test.dart';

import 'package:muyin_music/features/player/lyric_frame.dart';
import 'package:muyin_music/features/player/lyric_parser.dart';

void main() {
  group('LyricFrameAlgorithms.shouldShow', () {
    test('开关关闭时不显示', () {
      expect(
        LyricFrameAlgorithms.shouldShow(
          enabled: false,
          isPlaying: true,
          lyricLine: '歌词行',
        ),
        false,
      );
    });

    test('未在播放时不显示', () {
      expect(
        LyricFrameAlgorithms.shouldShow(
          enabled: true,
          isPlaying: false,
          lyricLine: '歌词行',
        ),
        false,
      );
    });

    test('无歌词行时不显示', () {
      expect(
        LyricFrameAlgorithms.shouldShow(
          enabled: true,
          isPlaying: true,
          lyricLine: null,
        ),
        false,
      );
    });

    test('播放中且有歌词时显示', () {
      expect(
        LyricFrameAlgorithms.shouldShow(
          enabled: true,
          isPlaying: true,
          lyricLine: '歌词行',
        ),
        true,
      );
    });
  });

  group('LyricFrameAlgorithms.shouldUpdate', () {
    test('首行歌词（上一行为空）更新', () {
      expect(
        LyricFrameAlgorithms.shouldUpdate(previous: null, next: '第一行'),
        true,
      );
    });

    test('歌词行变化时更新', () {
      expect(
        LyricFrameAlgorithms.shouldUpdate(previous: '第一行', next: '第二行'),
        true,
      );
    });

    test('歌词行未变化时不更新（去重）', () {
      expect(
        LyricFrameAlgorithms.shouldUpdate(previous: '同一行', next: '同一行'),
        false,
      );
    });
  });

  group('LyricFrameAlgorithms.splitLyricForIsland', () {
    test('短歌词也左右拼接：两侧非空且拼成完整歌词', () {
      const lyric = '短歌词';
      final r = LyricFrameAlgorithms.splitLyricForIsland(lyric);
      expect(r.left, isNotEmpty, reason: '短歌词左侧也应有内容');
      expect(r.right, isNotEmpty, reason: '短歌词右侧也应有内容');
      expect('${r.left}${r.right}', lyric, reason: '左右拼接等于完整歌词');
    });

    test('短歌词均分：两侧字符数差不超过 1', () {
      const lyric = '短歌词';
      final r = LyricFrameAlgorithms.splitLyricForIsland(lyric);
      expect((r.left.length - r.right.length).abs(), lessThanOrEqualTo(1),
          reason: '短歌词应按字符均分，两侧接近等长');
    });

    test('2字帧：左右各 1 字（不整段只放一侧）', () {
      const lyric = 'XX';
      final r = LyricFrameAlgorithms.splitLyricForIsland(lyric);
      expect(r.left, 'X', reason: '2字帧左侧应恰好 1 字');
      expect(r.right, 'X', reason: '2字帧右侧应恰好 1 字');
    });

    test('空格分隔的短语：在空格处断，两侧不带头尾空格', () {
      const lyric = '聆听山语 回荡不清';
      final r = LyricFrameAlgorithms.splitLyricForIsland(lyric);
      expect(r.left, '聆听山语', reason: '左半应在空格处断，不带空格');
      expect(r.right, '回荡不清', reason: '右半应在空格处断，不带空格');
      expect(r.left.trim(), r.left, reason: '左侧不带头尾空格');
      expect(r.right.trim(), r.right, reason: '右侧不带头尾空格');
    });

    test('奇数帧：右侧多 1 字（ceil 均分，左侧多 1）', () {
      const lyric = '三字词';
      final r = LyricFrameAlgorithms.splitLyricForIsland(lyric);
      expect(r.left.runes.length, 2, reason: '3字帧左侧 2 字');
      expect(r.right.runes.length, 1, reason: '3字帧右侧 1 字');
      expect('${r.left}${r.right}', lyric, reason: '左右拼回原串');
    });

    test('长歌词：按长度对半分割，左右衔接拼成完整歌词', () {
      const lyric = '这是一段比较长的歌词用来测试左右分割衔接的效果';
      final r = LyricFrameAlgorithms.splitLyricForIsland(lyric);
      expect(r.left, isNotEmpty);
      expect(r.right, isNotEmpty);
      expect('${r.left}${r.right}', lyric);
    });

    test('空歌词：两侧皆空', () {
      final r = LyricFrameAlgorithms.splitLyricForIsland('');
      expect(r.left, isEmpty);
      expect(r.right, isEmpty);
    });

    test('超长歌词：同样左右拼接，两侧同时非空', () {
      const lyric = '这是一行特别长的歌词用来测试滚动接力效果的显示方式';
      final r = LyricFrameAlgorithms.splitLyricForIsland(lyric);
      expect(r.left, isNotEmpty, reason: '超长歌词左侧也应有内容');
      expect(r.right, isNotEmpty, reason: '超长歌词右侧也应有内容');
      expect('${r.left}${r.right}', lyric, reason: '超长歌词也应左右拼接成完整歌词');
    });
  });

  group('LyricFrameAlgorithms.shouldSendCover', () {
    test('同一首歌同一封面：不需要重发封面', () {
      expect(
        LyricFrameAlgorithms.shouldSendCover(
          prevSongId: 's1',
          prevCoverId: 'c1',
          newSongId: 's1',
          newCoverId: 'c1',
        ),
        false,
      );
    });

    test('切歌到新封面：需要发封面', () {
      expect(
        LyricFrameAlgorithms.shouldSendCover(
          prevSongId: 's1',
          prevCoverId: 'c1',
          newSongId: 's2',
          newCoverId: 'c2',
        ),
        true,
      );
    });

    test('同一首歌封面变化（updatedAt 刷新）：需要发封面', () {
      expect(
        LyricFrameAlgorithms.shouldSendCover(
          prevSongId: 's1',
          prevCoverId: 'c1',
          newSongId: 's1',
          newCoverId: 'c2',
        ),
        true,
      );
    });

    test('无封面 id：不发封面', () {
      expect(
        LyricFrameAlgorithms.shouldSendCover(
          prevSongId: 's1',
          prevCoverId: null,
          newSongId: 's2',
          newCoverId: null,
        ),
        false,
      );
    });
  });

  group('LyricFrameAlgorithms.chunkLyric', () {
    test('短歌词（≤10字）：单帧（整行）', () {
      const lyric = '短歌词';
      final frames = LyricFrameAlgorithms.chunkLyric(lyric, frameChars: 10);
      expect(frames.length, 1);
      expect(frames.single, lyric);
    });

    test('超长歌词：拆成多帧，每帧不超过 frameChars', () {
      const lyric = '这是一行特别长的歌词用来测试滚动接力效果的显示方式';
      final frames = LyricFrameAlgorithms.chunkLyric(lyric, frameChars: 10);
      expect(frames.length, greaterThan(1));
      for (final frame in frames) {
        expect(frame.runes.length, lessThanOrEqualTo(10),
            reason: '每帧应不超过单帧容量');
      }
      expect(frames.join(), lyric);
    });

    test('智能截断：优先在空格词边界断，短词不被切散', () {
      const lyric = '今天天气很好 我们去爬山 明天再出发';
      final frames = LyricFrameAlgorithms.chunkLyric(lyric, frameChars: 10);
      expect(frames.join(' ').contains('今天天气很好'), isTrue);
      expect(frames.join(' ').contains('我们去爬山'), isTrue);
      expect(frames.join(' ').contains('明天再出发'), isTrue);
      for (final frame in frames) {
        expect(frame.contains(' '), isFalse, reason: '帧内不应含空格');
        expect(frame.trim(), frame, reason: '帧不应含首尾空格');
      }
    });

    test('智能截断：超长 ASCII 单词本身必须被切（无法整词保留）', () {
      const lyric = 'Supercalifragilistic';
      final frames = LyricFrameAlgorithms.chunkLyric(lyric, frameChars: 10);
      expect(frames.length, greaterThan(1), reason: '超长单词应被切成多帧');
      for (final frame in frames) {
        expect(frame.runes.length, lessThanOrEqualTo(10),
            reason: '即使切单词，每帧也不超过 10 字');
      }
      expect(frames.join(), lyric, reason: '拼接等于完整单词');
    });

    test('恰好 10 字：单帧', () {
      const lyric = '一二三四五六七八九十';
      final frames = LyricFrameAlgorithms.chunkLyric(lyric, frameChars: 10);
      expect(frames.length, 1);
      expect(frames.single, lyric);
    });

    test('实时通知 7 字截断：空格优先断点，首帧不超 7 字', () {
      const lyric = '今天天气很好 我们去爬山';
      final frames = LyricFrameAlgorithms.chunkLyric(lyric, frameChars: 7);
      expect(frames.length, greaterThan(1), reason: '超长行应拆多帧');
      expect(frames.first, '今天天气很好', reason: '首帧应取空格前的完整词');
      for (final frame in frames) {
        expect(frame.runes.length, lessThanOrEqualTo(7),
            reason: '每帧不超过 7 字');
      }
      const noSpace = '这是一首超长的歌没有空格';
      final nf = LyricFrameAlgorithms.chunkLyric(noSpace, frameChars: 7);
      expect(nf.first, '这是一首超长的', reason: '无空格时首帧取前 7 字');
    });

    test('拆帧过滤分隔符：空格、连字符、间隔号不留在帧内', () {
      const hyphen = '旧梦前尘-一去不回';
      final hf = LyricFrameAlgorithms.chunkLyric(hyphen, frameChars: 7);
      expect(hf.length, greaterThan(1), reason: '连字符分隔的超长行应拆多帧');
      expect(hf.first, '旧梦前尘', reason: '首帧应为连字符前的完整词，且不含连字符');
      expect(hf.any((f) => f.contains('-')), isFalse, reason: '帧内不应含连字符');

      const middot = '半山听雨·夜雨声烦';
      final mf = LyricFrameAlgorithms.chunkLyric(middot, frameChars: 7);
      expect(mf.any((f) => f.contains('·')), isFalse, reason: '帧内不应含间隔号');
      expect(mf.join(), '半山听雨夜雨声烦',
          reason: '去掉间隔号后拼接等于过滤后的完整歌词');
    });

    test('拆帧不含尾随空格（避免空格留在帧尾导致滚动）', () {
      const lyric = '聆听山语 回荡不清 若即若离';
      final frames = LyricFrameAlgorithms.chunkLyric(lyric, frameChars: 10);
      for (final frame in frames) {
        expect(frame.trim(), frame, reason: '帧不应含首尾空格');
      }
      final joined = frames.map((f) => f.trim()).join();
      expect(joined.replaceAll(' ', ''), '聆听山语回荡不清若即若离');
    });

    test('空歌词：无帧', () {
      final frames = LyricFrameAlgorithms.chunkLyric('', frameChars: 10);
      expect(frames, isEmpty);
    });
  });

  group('LyricFrameAlgorithms.frameIndexForPosition', () {
    // 行时间窗口 [2000ms, 4000ms]，两帧：帧0=[2000,3000)，帧1=[3000,4000)
    test('位置在行开始前：第 0 帧', () {
      expect(
        LyricFrameAlgorithms.frameIndexForPosition(
          frameCount: 2,
          lineStartMs: 2000,
          lineEndMs: 4000,
          positionMs: 1000,
        ),
        0,
      );
    });

    test('位置在前半段（中点前）：第 0 帧', () {
      expect(
        LyricFrameAlgorithms.frameIndexForPosition(
          frameCount: 2,
          lineStartMs: 2000,
          lineEndMs: 4000,
          positionMs: 2500,
        ),
        0,
      );
    });

    test('位置在后半段（中点后）：第 1 帧', () {
      expect(
        LyricFrameAlgorithms.frameIndexForPosition(
          frameCount: 2,
          lineStartMs: 2000,
          lineEndMs: 4000,
          positionMs: 3500,
        ),
        1,
      );
    });

    test('位置在行结束后：最后一帧', () {
      expect(
        LyricFrameAlgorithms.frameIndexForPosition(
          frameCount: 2,
          lineStartMs: 2000,
          lineEndMs: 4000,
          positionMs: 99999,
        ),
        1,
      );
    });

    test('单帧或无 end：恒第 0 帧', () {
      expect(
        LyricFrameAlgorithms.frameIndexForPosition(
          frameCount: 1,
          lineStartMs: 2000,
          lineEndMs: 4000,
          positionMs: 3500,
        ),
        0,
      );
      expect(
        LyricFrameAlgorithms.frameIndexForPosition(
          frameCount: 2,
          lineStartMs: 2000,
          lineEndMs: null,
          positionMs: 3500,
        ),
        0,
      );
    });
  });

  group('LyricFrameAlgorithms.frameIndexForPositionWithWords', () {
    const frames = ['旧梦前尘', '一去不回'];

    test('无逐字时间戳：退回等分逻辑', () {
      expect(
        LyricFrameAlgorithms.frameIndexForPositionWithWords(
          frames: frames,
          words: null,
          lineStartMs: 2000,
          lineEndMs: 6000,
          positionMs: 3000,
        ),
        0,
      );
      expect(
        LyricFrameAlgorithms.frameIndexForPositionWithWords(
          frames: frames,
          words: null,
          lineStartMs: 2000,
          lineEndMs: 6000,
          positionMs: 5000,
        ),
        1,
      );
    });

    test('逐字时间戳：唱到后半段立即翻帧（不等到行结束）', () {
      // 「旧梦前尘」(2000-4000) 是前半帧，「一去不回」从 4000ms 开始（后半帧）
      final List<KaraokeWordTiming> words = [
        const KaraokeWordTiming(text: '旧', startMs: 2000, endMs: 2500),
        const KaraokeWordTiming(text: '梦', startMs: 2500, endMs: 3000),
        const KaraokeWordTiming(text: '前', startMs: 3000, endMs: 3500),
        const KaraokeWordTiming(text: '尘', startMs: 3500, endMs: 4000),
        const KaraokeWordTiming(text: '一', startMs: 4000, endMs: 4500),
        const KaraokeWordTiming(text: '去', startMs: 4500, endMs: 5000),
        const KaraokeWordTiming(text: '不', startMs: 5000, endMs: 5500),
        const KaraokeWordTiming(text: '回', startMs: 5500, endMs: 6000),
      ];
      expect(
        LyricFrameAlgorithms.frameIndexForPositionWithWords(
          frames: frames,
          words: words,
          lineStartMs: 2000,
          lineEndMs: 6000,
          positionMs: 1500,
        ),
        0,
        reason: '行开始前 → 0',
      );
      expect(
        LyricFrameAlgorithms.frameIndexForPositionWithWords(
          frames: frames,
          words: words,
          lineStartMs: 2000,
          lineEndMs: 6000,
          positionMs: 2000,
        ),
        0,
        reason: '唱到「旧」(2000) → 帧 0',
      );
      expect(
        LyricFrameAlgorithms.frameIndexForPositionWithWords(
          frames: frames,
          words: words,
          lineStartMs: 2000,
          lineEndMs: 6000,
          positionMs: 4000,
        ),
        1,
        reason: '唱到「尘」末尾 /「一」开始 (4000) → 翻到帧 1',
      );
      expect(
        LyricFrameAlgorithms.frameIndexForPositionWithWords(
          frames: frames,
          words: words,
          lineStartMs: 2000,
          lineEndMs: 6000,
          positionMs: 99999,
        ),
        1,
        reason: '行结束后 → 最后一帧',
      );
    });

    test('逐字行 end 为 null：仍能按字推进（不退回第 0 帧）', () {
      final List<KaraokeWordTiming> words = [
        const KaraokeWordTiming(text: '一', startMs: 2000, endMs: 3000),
        const KaraokeWordTiming(text: '去', startMs: 3000, endMs: 4000),
      ];
      expect(
        LyricFrameAlgorithms.frameIndexForPositionWithWords(
          frames: const ['一', '去'],
          words: words,
          lineStartMs: 2000,
          lineEndMs: null,
          positionMs: 3500,
        ),
        1,
      );
    });
  });

  group('LyricFrameAlgorithms.frameForLine', () {
    final line = KaraokeLyricLine(
      startMs: 2000,
      endMs: 6000,
      text: '旧梦前尘一去不回',
      words: const [
        KaraokeWordTiming(text: '旧', startMs: 2000, endMs: 2500),
        KaraokeWordTiming(text: '梦', startMs: 2500, endMs: 3000),
        KaraokeWordTiming(text: '前', startMs: 3000, endMs: 3500),
        KaraokeWordTiming(text: '尘', startMs: 3500, endMs: 4000),
        KaraokeWordTiming(text: '一', startMs: 4000, endMs: 4500),
        KaraokeWordTiming(text: '去', startMs: 4500, endMs: 5000),
        KaraokeWordTiming(text: '不', startMs: 5000, endMs: 5500),
        KaraokeWordTiming(text: '回', startMs: 5500, endMs: 6000),
      ],
    );

    test('逐字推进：按位置切换帧，left+right 拼回 text', () {
      // frameChars 默认 10，8 字单行 → 单帧；这里用 4 拆成两帧按字推进
      final early = LyricFrameAlgorithms.frameForLine(line, 2000, frameChars: 4);
      expect(early.frameCount, 2);
      expect(early.text, '旧梦前尘');
      expect(early.frameIndex, 0);
      expect(early.left + early.right, early.text);

      final late = LyricFrameAlgorithms.frameForLine(line, 4000, frameChars: 4);
      expect(late.text, '一去不回');
      expect(late.frameIndex, 1);
      expect(late.left + late.right, late.text);
    });

    test('空文本行：得到空帧，索引/帧数为 0', () {
      final emptyLine = KaraokeLyricLine(
        startMs: 0,
        endMs: 1000,
        text: '',
      );
      final f = LyricFrameAlgorithms.frameForLine(emptyLine, 500);
      expect(f.text, '');
      expect(f.left, '');
      expect(f.right, '');
      expect(f.frameIndex, 0);
      expect(f.frameCount, 0);
    });
  });
}
