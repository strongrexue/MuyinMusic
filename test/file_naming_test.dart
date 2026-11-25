import 'package:muyin_music/core/models/enums.dart';
import 'package:muyin_music/core/models/music_info.dart';
import 'package:muyin_music/core/services/file_naming.dart';
import 'package:flutter_test/flutter_test.dart';

MusicInfo track({required String name, required String singer}) => MusicInfo(
  id: 'song-1',
  name: name,
  singer: singer,
  source: MusicSource.kw,
  interval: '03:00',
  meta: const MusicMeta(
    songId: 'song-1',
    albumName: 'Test Album',
    qualitys: [],
    raw: {},
  ),
  raw: const {},
);

void main() {
  group('FileNaming.artistFolder', () {
    test('uses the singer name as the folder', () {
      expect(FileNaming.artistFolder(track(name: '歌', singer: '周杰伦')), '周杰伦');
    });

    test('sanitizes path separators so one folder is created', () {
      expect(FileNaming.artistFolder(track(name: '歌', singer: 'AC/DC')), 'AC_DC');
    });

    test('keeps a combined singer string in a single folder', () {
      expect(
        FileNaming.artistFolder(track(name: '歌', singer: '甲 / 乙')),
        '甲 _ 乙',
      );
    });

    test('falls back to a placeholder when the singer is empty', () {
      expect(FileNaming.artistFolder(track(name: '歌', singer: '  ')), '未知歌手');
    });
  });

  test('grouped layout combines artist folder with the file name format', () {
    final info = track(name: '晴天', singer: '周杰伦');
    final folder = FileNaming.artistFolder(info);
    final file = FileNaming.build(
      info,
      'flac',
      format: DownloadFileNameFormat.titleArtist,
    );
    expect('$folder/$file', '周杰伦/晴天 - 周杰伦.flac');
  });
}
