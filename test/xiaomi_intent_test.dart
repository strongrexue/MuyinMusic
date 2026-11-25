import 'package:flutter_test/flutter_test.dart';
import 'package:muyin_music/core/xiaomi/takeover/speaker_intent.dart';

void main() {
  group('点歌句式', () {
    test('播放+歌手歌名连写：整体作 keyword，不伪造拆分', () {
      final intent = parseSpeakerIntent('播放周杰伦晴天');
      expect(intent, isA<PlaySongIntent>());
      final play = intent! as PlaySongIntent;
      expect(play.keyword, '周杰伦晴天');
      expect(play.artist, isNull);
    });

    test('播放歌曲+歌名', () {
      final intent = parseSpeakerIntent('播放歌曲晴天')! as PlaySongIntent;
      expect(intent.keyword, '晴天');
      expect(intent.title, '晴天');
    });

    test('歌手的歌名句式可拆分', () {
      final intent = parseSpeakerIntent('播放周杰伦的晴天')! as PlaySongIntent;
      expect(intent.artist, '周杰伦');
      expect(intent.title, '晴天');
    });

    test('我想听 / 唱一首 量词剥离', () {
      expect(
        (parseSpeakerIntent('我想听晴天')! as PlaySongIntent).keyword,
        '晴天',
      );
      expect(
        (parseSpeakerIntent('唱一首晴天')! as PlaySongIntent).keyword,
        '晴天',
      );
      expect(
        (parseSpeakerIntent('来一首周杰伦的稻香')! as PlaySongIntent).artist,
        '周杰伦',
      );
    });

    test('播放下一首是控制指令不是点歌', () {
      expect(parseSpeakerIntent('播放下一首'), isA<NextIntent>());
    });
  });

  group('控制指令', () {
    test('停止类', () {
      expect(parseSpeakerIntent('停止播放'), isA<StopIntent>());
      expect(parseSpeakerIntent('停止'), isA<StopIntent>());
      expect(parseSpeakerIntent('关机'), isA<StopIntent>());
      expect(parseSpeakerIntent('关掉音乐'), isA<StopIntent>());
    });

    test('暂停类', () {
      expect(parseSpeakerIntent('暂停'), isA<PauseIntent>());
      expect(parseSpeakerIntent('暂停播放'), isA<PauseIntent>());
    });

    test('继续类与裸播放', () {
      expect(parseSpeakerIntent('继续播放'), isA<ResumeIntent>());
      expect(parseSpeakerIntent('播放'), isA<ResumeIntent>());
    });

    test('上下首（带尾随句号）', () {
      expect(parseSpeakerIntent('下一首'), isA<NextIntent>());
      expect(parseSpeakerIntent('下一首。'), isA<NextIntent>());
      expect(parseSpeakerIntent('上一首'), isA<PreviousIntent>());
      expect(parseSpeakerIntent('切歌'), isA<NextIntent>());
    });

    test('关闭窗帘不误触（控制指令只认完全匹配）', () {
      expect(parseSpeakerIntent('关闭窗帘'), isNull);
    });
  });

  group('音量', () {
    test('阿拉伯数字', () {
      final intent = parseSpeakerIntent('音量调到50')! as SetVolumeIntent;
      expect(intent.value, 50);
      expect((parseSpeakerIntent('音量100')! as SetVolumeIntent).value, 100);
    });

    test('中文数字', () {
      expect((parseSpeakerIntent('设置音量三十')! as SetVolumeIntent).value, 30);
      expect((parseSpeakerIntent('音量十五')! as SetVolumeIntent).value, 15);
      expect((parseSpeakerIntent('音量十')! as SetVolumeIntent).value, 10);
    });

    test('步进', () {
      expect((parseSpeakerIntent('大声一点')! as VolumeStepIntent).up, isTrue);
      expect((parseSpeakerIntent('小声一点')! as VolumeStepIntent).up, isFalse);
    });
  });

  group('交还原生', () {
    test('歌单 / 歌手 / 闲聊 / 空', () {
      expect(parseSpeakerIntent('播放歌单周杰伦'), isNull);
      expect(parseSpeakerIntent('播放歌手周杰伦'), isNull);
      expect(parseSpeakerIntent('今天天气怎么样'), isNull);
      expect(parseSpeakerIntent(''), isNull);
      expect(parseSpeakerIntent('讲个笑话'), isNull);
    });
  });
}
