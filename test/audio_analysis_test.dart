import 'package:bass_player/bass_player.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:panghu_music/features/folia/audio_analysis.dart';

List<double> _fft({Map<int, double> bins = const {}, double fill = 0}) {
  final fft = List<double>.filled(512, fill);
  bins.forEach((index, value) => fft[index] = value);
  return fft;
}

void main() {
  group('AudioAnalysisProcessor', () {
    test('silence gives zero bands, zero power, no beat', () {
      final processor = AudioAnalysisProcessor();
      final frame = processor.process(_fft(), 44100, 0);
      expect(frame.bands.bass, 0);
      expect(frame.bands.treble, 0);
      expect(frame.power, 0);
      expect(frame.beat, isFalse);
      expect(frame.beatImpact, 0);
    });

    test('uniform spectrum gives sqrt power', () {
      final processor = AudioAnalysisProcessor();
      final frame = processor.process(_fft(fill: 0.25), 44100, 0);
      expect(frame.power, closeTo(0.5, 0.001));
    });

    test('bass-heavy spectrum lands in the bass band, not treble', () {
      final processor = AudioAnalysisProcessor();
      final frame = processor.process(
        _fft(bins: {0: 1, 1: 1, 2: 1, 3: 1, 4: 1}),
        44100,
        0,
      );
      expect(frame.bands.bass, closeTo(1, 0.001));
      expect(frame.bands.treble, 0);
    });

    test('treble-heavy spectrum lands in the treble band, not bass', () {
      final processor = AudioAnalysisProcessor();
      final frame = processor.process(
        _fft(bins: {for (var i = 100; i < 200; i++) i: 1}),
        44100,
        0,
      );
      expect(frame.bands.treble, greaterThan(0.5));
      expect(frame.bands.bass, 0);
    });

    test('a power jump fires one beat, then the interval gate holds', () {
      final processor = AudioAnalysisProcessor();
      final steady = processor.process(_fft(fill: 0.09), 44100, 0);
      expect(steady.beat, isTrue); // first frame: peak starts at zero
      expect(steady.beatImpact, 1);

      final tooSoon = processor.process(_fft(fill: 0.36), 44100, 100);
      expect(tooSoon.beat, isFalse);

      // The blocked jump is absorbed into the peak, so the same level
      // no longer fires — a second onset needs a new jump.
      final sameLevel = processor.process(_fft(fill: 0.36), 44100, 300);
      expect(sameLevel.beat, isFalse);
      final second = processor.process(_fft(fill: 0.81), 44100, 400);
      expect(second.beat, isTrue);
      expect(second.beatImpact, 1);
    });

    test('beat impact decays while power stays steady', () {
      final processor = AudioAnalysisProcessor();
      processor.process(_fft(fill: 0.09), 44100, 0);
      final next = processor.process(_fft(fill: 0.09), 44100, 500);
      expect(next.beat, isFalse);
      expect(next.beatImpact, closeTo(0.86, 0.001));
      final later = processor.process(_fft(fill: 0.09), 44100, 1000);
      expect(later.beatImpact, closeTo(0.86 * 0.86, 0.001));
    });

    test('reset clears the peak and beat state', () {
      final processor = AudioAnalysisProcessor();
      processor.process(_fft(fill: 0.09), 44100, 0);
      processor.reset();
      final frame = processor.process(_fft(fill: 0.09), 44100, 0);
      expect(frame.beat, isTrue);
    });
  });

  group('AudioAnalysisService', () {
    test('polls the fetcher and emits frames', () async {
      final service = AudioAnalysisService(
        fetchFft: () async =>
            const BassFftData(fft: [], sampleRateHz: 44100),
        interval: const Duration(milliseconds: 10),
      );
      // Empty FFT is a valid "no data" tick: no frame is emitted.
      service.start();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(service.latest, isNull);
      await service.dispose();
    });

    test('emits a frame per FFT snapshot', () async {
      final service = AudioAnalysisService(
        fetchFft: () async => BassFftData(
          fft: _fft(fill: 0.09),
          sampleRateHz: 44100,
        ),
        interval: const Duration(milliseconds: 10),
      );
      service.start();
      final frame = await service.frames.first.timeout(
        const Duration(seconds: 2),
      );
      expect(frame.power, closeTo(0.3, 0.001));
      expect(service.latest, same(frame));
      service.stop();
      expect(service.running, isFalse);
      await service.dispose();
    });

    test('a failing fetcher never throws out of the poll loop', () async {
      var calls = 0;
      final service = AudioAnalysisService(
        fetchFft: () async {
          calls++;
          return null;
        },
        interval: const Duration(milliseconds: 10),
      );
      service.start();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(calls, greaterThan(0));
      expect(service.latest, isNull);
      await service.dispose();
    });
  });
}
