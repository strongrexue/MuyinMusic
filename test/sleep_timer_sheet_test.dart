import 'package:muyin_music/features/player/sleep_timer_controller.dart';
import 'package:muyin_music/features/player/widgets/player_sleep_timer_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import 'helpers/prism_test_environment.dart';

void main() {
  testWidgets('preset timer starts from the popup and can be cancelled', (
    tester,
  ) async {
    final container = await _pumpHarness(tester);
    await tester.tap(find.text('打开定时'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('player-sleep-timer-popup')),
      findsOneWidget,
    );
    // The old bottom sheet is gone: no keyboard field anywhere.
    expect(find.byType(TextField), findsNothing);

    await tester.tap(find.text('45 分钟'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('player-sleep-timer-popup')), findsNothing);
    expect(container.read(sleepTimerProvider), const Duration(minutes: 45));

    await tester.pump(const Duration(seconds: 5));
    final remaining = container.read(sleepTimerProvider)!;
    expect(remaining, lessThan(const Duration(minutes: 45)));
    expect(remaining, greaterThan(const Duration(minutes: 44)));

    await tester.tap(find.text('打开定时'));
    await tester.pumpAndSettle();
    expect(find.textContaining('距离暂停'), findsOneWidget);
    await tester.tap(find.text('取消定时'));
    await tester.pumpAndSettle();
    expect(container.read(sleepTimerProvider), isNull);
    expect(tester.takeException(), isNull);
  });
}

Future<ProviderContainer> _pumpHarness(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sleepTimerProvider.overrideWith(
          (ref) => SleepTimerController(
            onElapsed: () async {},
            now: tester.binding.clock.now,
          ),
        ),
      ],
      child: MaterialApp(
        builder: buildPrismTestEnvironment,
        home: Scaffold(
          body: Center(
            child: prism.PopupAnchor(
              targetBuilder: (open) => FilledButton(
                onPressed: open,
                child: const Text('打开定时'),
              ),
              popupBuilder: (_) => const PlayerSleepTimerPopup(),
            ),
          ),
        ),
      ),
    ),
  );
  return ProviderScope.containerOf(tester.element(find.text('打开定时')));
}
