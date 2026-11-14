import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Where the player should come back to when a page it opened (the equalizer)
/// is closed. The shell records it as the player hands over, and clears it as
/// soon as that page goes away, so a later visit from Settings stays inside
/// Settings.
final pageOpenedFromPlayerProvider = StateProvider<String?>((ref) => null);
