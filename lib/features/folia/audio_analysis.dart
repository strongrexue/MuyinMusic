import 'dart:async';
import 'dart:math' as math;

import 'package:bass_player/bass_player.dart';
import 'package:flutter/foundation.dart';

/// Per-band energy of the audible output, all 0..1. Band edges follow
/// Folia's five audio bands: bass 20–150Hz, low-mid 150–400Hz,
/// mid 400–1200Hz, vocal 1–3.5kHz, treble 3.5kHz and up.
@immutable
class AudioBands {
  const AudioBands({
    required this.bass,
    required this.lowMid,
    required this.mid,
    required this.vocal,
    required this.treble,
  });

  const AudioBands.zero()
    : bass = 0,
      lowMid = 0,
      mid = 0,
      vocal = 0,
      treble = 0;

  final double bass;
  final double lowMid;
  final double mid;
  final double vocal;
  final double treble;
}

/// One analysis tick: the band energies, the overall [power], whether
/// this tick is a beat onset, and the [beatImpact] envelope (1.0 on the
/// onset, decaying afterwards) that stages use to punch the camera or
/// the glow. [positionMs] is the playback position the tick was taken
/// at, so stages can evaluate everything as f(absolute time).
@immutable
class AudioAnalysisFrame {
  const AudioAnalysisFrame({
    required this.bands,
    required this.power,
    required this.beat,
    required this.beatImpact,
    required this.positionMs,
  });

  final AudioBands bands;
  final double power;
  final bool beat;
  final double beatImpact;
  final int positionMs;
}

/// Pure FFT → bands + beat logic. Stateful only in the energy follower
/// (peak + last beat); no allocations beyond one frame per call.
class AudioAnalysisProcessor {
  static const double _kBeatThreshold = 1.12;
  static const double _kBeatMinPower = 0.2;
  static const int _kBeatMinIntervalMs = 220;
  static const double _kPeakDecay = 0.94;
  static const double _kImpactDecay = 0.86;

  double _peak = 0;
  int _lastBeatPositionMs = -100000;
  double _beatImpact = 0;

  void reset() {
    _peak = 0;
    _lastBeatPositionMs = -100000;
    _beatImpact = 0;
  }

  AudioAnalysisFrame process(
    List<double> fft,
    int sampleRateHz,
    int positionMs,
  ) {
    final bands = _bands(fft, sampleRateHz);
    final power = _power(fft);
    var beat = false;
    if (power > _peak * _kBeatThreshold &&
        power > _kBeatMinPower &&
        positionMs - _lastBeatPositionMs >= _kBeatMinIntervalMs) {
      beat = true;
      _beatImpact = 1;
      _lastBeatPositionMs = positionMs;
    } else {
      _beatImpact *= _kImpactDecay;
    }
    _peak = math.max(power, _peak * _kPeakDecay);
    return AudioAnalysisFrame(
      bands: bands,
      power: power,
      beat: beat,
      beatImpact: _beatImpact,
      positionMs: positionMs,
    );
  }

  AudioBands _bands(List<double> fft, int sampleRateHz) {
    double band(int lowHz, int highHz) {
      if (fft.isEmpty || sampleRateHz <= 0) return 0;
      final binWidth = sampleRateHz / (fft.length * 2);
      final start = (lowHz / binWidth).floor().clamp(0, fft.length - 1);
      final end = (highHz / binWidth).ceil().clamp(0, fft.length - 1);
      if (end < start) return 0;
      var sum = 0.0;
      for (var i = start; i <= end; i++) {
        sum += fft[i].abs();
      }
      return math.sqrt(sum / (end - start + 1)).clamp(0, 1).toDouble();
    }

    return AudioBands(
      bass: band(20, 150),
      lowMid: band(150, 400),
      mid: band(400, 1200),
      vocal: band(1000, 3500),
      treble: band(3500, 12000),
    );
  }

  double _power(List<double> fft) {
    if (fft.isEmpty) return 0;
    var sum = 0.0;
    for (final value in fft) {
      sum += value.abs();
    }
    return math.sqrt(sum / fft.length).clamp(0, 1).toDouble();
  }
}

/// Polls [BassPlayer.getFft] on a timer (~12Hz) and emits analysis
/// frames. Owns no playback state: the caller starts it when the
/// folia stage is visible and stops it when the stage leaves.
class AudioAnalysisService {
  AudioAnalysisService({
    required FftFetcher fetchFft,
    Duration Function()? positionNow,
    this.interval = const Duration(milliseconds: 80),
  }) : _fetchFft = fetchFft,
       _positionNow = positionNow ?? (() => Duration.zero);

  /// Builds a service reading FFT from [player].
  factory AudioAnalysisService.fromPlayer(
    BassPlayer player, {
    Duration Function()? positionNow,
  }) => AudioAnalysisService(
    fetchFft: player.getFft,
    positionNow: positionNow,
  );

  final FftFetcher _fetchFft;
  final Duration Function() _positionNow;

  /// Poll period; 80ms (~12Hz) keeps a stage reactive without
  /// hammering the method channel.
  final Duration interval;

  final AudioAnalysisProcessor _processor = AudioAnalysisProcessor();
  final StreamController<AudioAnalysisFrame> _frames =
      StreamController<AudioAnalysisFrame>.broadcast();

  Stream<AudioAnalysisFrame> get frames => _frames.stream;
  AudioAnalysisFrame? get latest => _latest;
  AudioAnalysisFrame? _latest;

  Timer? _timer;
  bool _polling = false;
  bool _disposed = false;

  bool get running => _timer != null;

  void start() {
    if (_timer != null || _disposed) return;
    _timer = Timer.periodic(interval, (_) => _poll());
  }

  Future<void> _poll() async {
    if (_polling) return;
    _polling = true;
    try {
      final data = await _fetchFft();
      if (data == null || data.fft.isEmpty || _disposed || _timer == null) {
        return;
      }
      _latest = _processor.process(
        data.fft,
        data.sampleRateHz,
        _positionNow().inMilliseconds,
      );
      _frames.add(_latest!);
    } finally {
      _polling = false;
    }
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> dispose() async {
    _disposed = true;
    stop();
    await _frames.close();
  }
}

/// Fetches one FFT snapshot, or null when none is available.
typedef FftFetcher = Future<BassFftData?> Function();
