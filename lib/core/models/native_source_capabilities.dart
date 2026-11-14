import 'enums.dart';

/// Sources the app can resolve itself, without an imported JS music source.
/// Their qualities are fixed because the platform decides what it hands out.
const Map<MusicSource, List<Quality>> kNativeSourceQualities = {
  MusicSource.qishui: <Quality>[
    Quality.k128,
    Quality.k192,
    Quality.k320,
    Quality.flac,
    Quality.hires,
    Quality.atmos,
    Quality.atmosPlus,
  ],
};

bool isNativeMusicSource(MusicSource source) =>
    kNativeSourceQualities.containsKey(source);

List<Quality> nativeQualitiesFor(MusicSource source) =>
    kNativeSourceQualities[source] ?? const <Quality>[];
