import 'package:flutter_test/flutter_test.dart';

import 'package:panghu_music/features/cast/av_transport_client.dart';
import 'package:panghu_music/features/cast/cast_advance.dart';

void main() {
  const duration = Duration(minutes: 4, seconds: 21);

  CastAdvanceDecision decide({
    AvTransportPlaybackState state = AvTransportPlaybackState.playing,
    Duration position = const Duration(minutes: 1),
    Duration trackDuration = duration,
    Duration previousPosition = const Duration(minutes: 1),
    bool wasPlaying = true,
    bool playCommanded = true,
    Duration sinceStart = const Duration(minutes: 1),
  }) {
    return decideCastAdvance(
      transportState: state,
      position: position,
      duration: trackDuration,
      previousPosition: previousPosition,
      wasPlaying: wasPlaying,
      playCommanded: playCommanded,
      sinceTrackStart: sinceStart,
    );
  }

  group('decideCastAdvance', () {
    test('mid-track playback keeps polling', () {
      expect(decide(), CastAdvanceDecision.none);
    });

    test('paused never advances', () {
      expect(
        decide(
          state: AvTransportPlaybackState.paused,
          position: duration,
          previousPosition: duration,
        ),
        CastAdvanceDecision.none,
      );
    });

    test('stopped at the tail advances', () {
      expect(
        decide(
          state: AvTransportPlaybackState.stopped,
          position: duration - const Duration(milliseconds: 800),
          previousPosition: duration - const Duration(seconds: 2),
        ),
        CastAdvanceDecision.advance,
      );
    });

    test('position wrapping past the end (renderer loops) advances', () {
      expect(
        decide(
          position: const Duration(seconds: 2),
          previousPosition: duration - const Duration(seconds: 1),
        ),
        CastAdvanceDecision.advance,
      );
    });

    test('stopped at zero shortly after Play is a start failure', () {
      expect(
        decide(
          state: AvTransportPlaybackState.stopped,
          position: Duration.zero,
          previousPosition: Duration.zero,
          wasPlaying: false,
          sinceStart: const Duration(seconds: 3),
        ),
        CastAdvanceDecision.startFailed,
      );
    });

    test('stopped at zero inside the buffering grace is not a failure', () {
      expect(
        decide(
          state: AvTransportPlaybackState.stopped,
          position: Duration.zero,
          previousPosition: Duration.zero,
          wasPlaying: false,
          sinceStart: const Duration(seconds: 1),
        ),
        CastAdvanceDecision.none,
      );
    });

    test('stopped at zero long after start is not a start failure', () {
      expect(
        decide(
          state: AvTransportPlaybackState.stopped,
          position: Duration.zero,
          previousPosition: Duration.zero,
          wasPlaying: false,
          sinceStart: const Duration(seconds: 30),
        ),
        CastAdvanceDecision.none,
      );
    });

    test('stopped mid-track after playing advances instead of stalling', () {
      expect(
        decide(
          state: AvTransportPlaybackState.stopped,
          position: const Duration(minutes: 2),
          previousPosition: const Duration(minutes: 2),
        ),
        CastAdvanceDecision.advance,
      );
    });

    test('unknown duration never fabricates an end', () {
      expect(
        decide(
          state: AvTransportPlaybackState.stopped,
          position: Duration.zero,
          trackDuration: Duration.zero,
          previousPosition: Duration.zero,
          wasPlaying: false,
          sinceStart: const Duration(seconds: 30),
        ),
        CastAdvanceDecision.none,
      );
    });
  });

  group('shouldFallbackToRelay', () {
    test('only direct remote starts fall back, once', () {
      expect(
        shouldFallbackToRelay(
          startedWithRelay: false,
          isLocalFile: false,
          alreadyRetried: false,
        ),
        isTrue,
      );
      expect(
        shouldFallbackToRelay(
          startedWithRelay: true,
          isLocalFile: false,
          alreadyRetried: false,
        ),
        isFalse,
      );
      expect(
        shouldFallbackToRelay(
          startedWithRelay: false,
          isLocalFile: true,
          alreadyRetried: false,
        ),
        isFalse,
      );
      expect(
        shouldFallbackToRelay(
          startedWithRelay: false,
          isLocalFile: false,
          alreadyRetried: true,
        ),
        isFalse,
      );
    });
  });
}
