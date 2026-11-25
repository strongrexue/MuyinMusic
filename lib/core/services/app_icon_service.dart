import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum AppIconVariant {
  classic('classic', '胖虎·经典'),
  midnight('midnight', '胖虎·沉浸'),
  sky('sky', '胖虎·耳机'),
  lavender('lavender', '胖虎·黑胶'),
  mint('mint', '胖虎·吉他'),
  peach('peach', '胖虎·麦克风');

  const AppIconVariant(this.code, this.label);

  final String code;
  final String label;
  String get previewAsset => 'assets/app_icons/$code.png';

  static AppIconVariant fromCode(String? code) =>
      values.firstWhere((icon) => icon.code == code, orElse: () => classic);
}

bool get supportsCustomAppIcons {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;
}

final appIconProvider =
    AsyncNotifierProvider<AppIconController, AppIconVariant>(
      AppIconController.new,
    );

class AppIconController extends AsyncNotifier<AppIconVariant> {
  static const _channel = MethodChannel('muyin_music/app_icon');

  @override
  Future<AppIconVariant> build() async {
    if (!supportsCustomAppIcons) return AppIconVariant.classic;
    return AppIconVariant.fromCode(
      await _channel.invokeMethod<String>('getCurrentIcon'),
    );
  }

  Future<bool> select(AppIconVariant icon) async {
    if (!supportsCustomAppIcons || state.isLoading) return false;
    if (state.valueOrNull == icon) return false;
    final previous = state;
    state = const AsyncLoading<AppIconVariant>().copyWithPrevious(previous);
    try {
      final code = await _channel.invokeMethod<String>('setIcon', {
        'icon': icon.code,
      });
      state = AsyncData(AppIconVariant.fromCode(code));
      return true;
    } catch (error, stack) {
      state = previous;
      Error.throwWithStackTrace(error, stack);
    }
  }
}
