import 'av_transport_client.dart';

enum CastAdvanceDecision {
  /// Keep polling; the track is still playing (or state is inconclusive).
  none,

  /// The track reached its end on the renderer — move the queue on.
  advance,

  /// The renderer is stuck at the start (direct URL failed): the session
  /// should retry this track through the relay.
  startFailed,
}

/// Decides, from one position-poll sample, whether a cast track has ended.
///
/// Renderers without SetNextAVTransportURI support (e.g. Xiaomi speakers,
/// where the action is a stub) are advanced by the app, so this decision
/// is the queue's only driver. Samples are ~1 s apart.
CastAdvanceDecision decideCastAdvance({
  required AvTransportPlaybackState transportState,
  required Duration position,
  required Duration duration,
  required Duration previousPosition,
  required bool wasPlaying,
  required bool playCommanded,
  required Duration sinceTrackStart,
}) {
  final hasDuration = duration > Duration.zero;
  final nearEnd =
      hasDuration && position >= duration - const Duration(milliseconds: 1500);

  // Wrapped past the end: some renderers loop the single track instead of
  // stopping (the LX06 does), so a position that jumps backwards from the
  // tail means the track finished and restarted.
  if (wasPlaying &&
      hasDuration &&
      previousPosition >= duration - const Duration(seconds: 3) &&
      position < previousPosition - const Duration(seconds: 2)) {
    return CastAdvanceDecision.advance;
  }

  if (transportState == AvTransportPlaybackState.stopped ||
      transportState == AvTransportPlaybackState.noMedia) {
    if (nearEnd) return CastAdvanceDecision.advance;
    // Stopped at (or reset to) the beginning shortly after Play was
    // commanded: the renderer rejected the stream. The 2 s grace avoids
    // misreading the stop a renderer passes through while buffering; a
    // renderer that rejects a URL outright may never report PLAYING, so
    // this keys off the commanded state, not the observed one.
    if (playCommanded &&
        position <= const Duration(seconds: 1) &&
        sinceTrackStart >= const Duration(seconds: 2) &&
        sinceTrackStart <= const Duration(seconds: 8)) {
      return CastAdvanceDecision.startFailed;
    }
    // Stopped mid-track after having played: treat as ended so the queue
    // does not stall on a renderer that stops instead of pausing at end.
    if (wasPlaying && hasDuration && position > Duration.zero) {
      return CastAdvanceDecision.advance;
    }
  }
  return CastAdvanceDecision.none;
}

/// Whether the direct→relay fallback should fire for a track whose start
/// failed, given the URL it was started with. Local files and relay URLs
/// never fall back further.
bool shouldFallbackToRelay({
  required bool startedWithRelay,
  required bool isLocalFile,
  required bool alreadyRetried,
}) => !startedWithRelay && !isLocalFile && !alreadyRetried;
