import 'enums.dart';

/// Sources the app can resolve itself, without an imported JS music source.
/// Their qualities are fixed because the platform decides what it hands out.
///
/// Soda (汽水) is not listed: its playback is delegated to imported sources
/// just like the other platforms, so it needs a script like any of them.
const Map<MusicSource, List<Quality>> kNativeSourceQualities = {};

bool isNativeMusicSource(MusicSource source) =>
    kNativeSourceQualities.containsKey(source);

List<Quality> nativeQualitiesFor(MusicSource source) =>
    kNativeSourceQualities[source] ?? const <Quality>[];
