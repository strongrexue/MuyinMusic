import 'package:flutter_test/flutter_test.dart';
import 'package:panghu_music/features/folia/folia_storyboard.dart';
import 'package:panghu_music/features/player/lyric_parser.dart';

KaraokeLyrics _lyrics(List<(int, int, String)> rows) => KaraokeLyrics([
  for (final (start, end, text) in rows)
    KaraokeLyricLine(startMs: start, endMs: end, text: text),
]);

void main() {
  const compiler = FoliaStoryboardCompiler();

  test('empty lyrics compile to an empty program', () {
    final program = compiler.compile(const KaraokeLyrics([]), 'song-a');
    expect(program.isEmpty, isTrue);
    expect(program.durationMs, 0);
    expect(program.paragraphs, isEmpty);
  });

  test('a single line is one paragraph with one shot', () {
    final program = compiler.compile(_lyrics([(0, 3000, 'hello')]), 'song-a');
    expect(program.paragraphs.length, 1);
    expect(program.shots.length, 1);
    expect(program.shots.single.lineIndices, [0]);
    expect(program.durationMs, 3000);
  });

  test('compiling is deterministic for the same song id', () {
    final lyrics = _lyrics([
      for (var i = 0; i < 8; i++) (i * 3000, i * 3000 + 2500, 'line $i'),
    ]);
    final first = compiler.compile(lyrics, 'song-a');
    final second = compiler.compile(lyrics, 'song-a');
    expect(first, second);
    expect(first.hashCode, second.hashCode);
  });

  test('a different song id compiles a different program', () {
    final lyrics = _lyrics([
      for (var i = 0; i < 8; i++) (i * 3000, i * 3000 + 2500, 'line $i'),
    ]);
    expect(
      compiler.compile(lyrics, 'song-a'),
      isNot(compiler.compile(lyrics, 'song-b')),
    );
  });

  test('shots hold at most 4 lines and 6000ms', () {
    final lyrics = _lyrics([
      for (var i = 0; i < 12; i++) (i * 3000, i * 3000 + 2500, 'line $i'),
    ]);
    final program = compiler.compile(lyrics, 'song-a');
    for (final shot in program.shots) {
      expect(shot.lineIndices.length, lessThanOrEqualTo(4));
      expect(shot.endMs - shot.startMs, lessThanOrEqualTo(6000));
    }
    expect(program.shots.length, 6);
  });

  test('repeated lines mark the paragraph a chorus', () {
    final program = compiler.compile(_lyrics([
      (0, 3000, 'love you'),
      (3000, 6000, 'hold me'),
      (6000, 9000, 'love you'),
      (9000, 12000, 'hold me'),
    ]), 'song-a');
    expect(program.paragraphs.length, 1);
    expect(program.paragraphs.single.kind, FoliaParagraphKind.chorus);
  });

  test('shot kinds never repeat back to back', () {
    final lyrics = _lyrics([
      for (var i = 0; i < 20; i++) (i * 3000, i * 3000 + 2500, 'line $i'),
    ]);
    final shots = compiler.compile(lyrics, 'song-a').shots;
    for (var i = 1; i < shots.length; i++) {
      expect(shots[i].kind, isNot(shots[i - 1].kind));
    }
  });

  test('a long gap splits paragraphs; a 12s gap is an interlude', () {
    final program = compiler.compile(_lyrics([
      (0, 3000, 'first'),
      (20000, 23000, 'second'),
      (40000, 43000, 'third'),
    ]), 'song-a');
    expect(program.paragraphs.length, 3);
    expect(program.paragraphs[1].kind, FoliaParagraphKind.interlude);
    expect(program.paragraphs[2].kind, FoliaParagraphKind.outro);
  });

  test('the final stretch is the outro', () {
    final program = compiler.compile(_lyrics([
      (0, 3000, 'first'),
      (12000, 15000, 'second'),
    ]), 'song-a');
    expect(program.paragraphs.length, 2);
    expect(program.paragraphs[1].kind, FoliaParagraphKind.outro);
  });

  test('camera paths stay inside their bounds', () {
    final lyrics = _lyrics([
      for (var i = 0; i < 20; i++) (i * 3000, i * 3000 + 2500, 'line $i'),
    ]);
    for (final shot in compiler.compile(lyrics, 'song-a').shots) {
      final camera = shot.camera;
      expect(camera.startScale, inInclusiveRange(1.0, 1.05));
      expect(camera.endScale, greaterThan(camera.startScale));
      expect(camera.endScale, lessThanOrEqualTo(1.12));
      expect(camera.startDx.abs(), lessThanOrEqualTo(0.031));
      expect(camera.startDy.abs(), lessThanOrEqualTo(0.031));
      expect(camera.endDx.abs(), lessThanOrEqualTo(0.031));
      expect(camera.endDy.abs(), lessThanOrEqualTo(0.031));
    }
  });
}
