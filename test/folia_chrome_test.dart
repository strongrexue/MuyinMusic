// Folia immersive chrome (full-screen stage): hidden on entry, tap
// the stage to toggle, auto-hides after 3.5s idle while playing,
// pausing keeps it visible. Separate from the page-level immersive
// chrome so a tap on the empty stage toggles while taps on the
// controls themselves only restart the countdown.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:panghu_music/features/folia/folia_chrome.dart';

Future<ProviderContainer> _pumpChrome(
  WidgetTester tester, {
  required Widget child,
}) async {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: Scaffold(body: child)),
    ),
  );
  return container;
}

Widget _stateText() => Consumer(
  builder: (context, ref, _) {
    final visible = ref.watch(foliaChromeProvider);
    return Text(visible ? 'visible' : 'hidden', textDirection: TextDirection.ltr);
  },
);

void main() {
  testWidgets('chrome starts hidden, toggle shows, auto-hides after 3.5s',
      (tester) async {
    final container = await _pumpChrome(tester, child: _stateText());
    final chrome = container.read(foliaChromeProvider.notifier);

    expect(find.text('hidden'), findsOneWidget);

    // Tap the stage: show.
    chrome.toggle();
    await tester.pump();
    expect(find.text('visible'), findsOneWidget);

    // Still visible 2s later.
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('visible'), findsOneWidget);

    // Tap again: hide immediately.
    chrome.toggle();
    await tester.pump();
    expect(find.text('hidden'), findsOneWidget);

    // Show again, then idle: auto-hides after the delay.
    chrome.toggle();
    await tester.pump();
    expect(find.text('visible'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 3500));
    expect(find.text('hidden'), findsOneWidget);
  });

  testWidgets('poke restarts the countdown while visible',
      (tester) async {
    final container = await _pumpChrome(tester, child: _stateText());
    final chrome = container.read(foliaChromeProvider.notifier);

    chrome.show();
    await tester.pump();
    expect(find.text('visible'), findsOneWidget);

    // 3s in, an interaction restarts the countdown.
    await tester.pump(const Duration(seconds: 3));
    chrome.poke();
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('visible'), findsOneWidget);

    // Now it hides 3.5s after the poke.
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('hidden'), findsOneWidget);
  });

  testWidgets('pausing shows the chrome and holds it; resume restarts',
      (tester) async {
    final container = await _pumpChrome(tester, child: _stateText());
    final chrome = container.read(foliaChromeProvider.notifier);

    // Pausing while hidden shows the chrome.
    chrome.syncPlaying(false);
    await tester.pump();
    expect(find.text('visible'), findsOneWidget);

    // Held: no auto-hide while paused.
    await tester.pump(const Duration(seconds: 10));
    expect(find.text('visible'), findsOneWidget);

    // Resuming restarts the countdown.
    chrome.syncPlaying(true);
    await tester.pump(const Duration(milliseconds: 3500));
    expect(find.text('hidden'), findsOneWidget);
  });

  testWidgets('FoliaChromeFade blocks touches while hidden',
      (tester) async {
    var taps = 0;
    final container = await _pumpChrome(
      tester,
      child: FoliaChromeFade(
        child: GestureDetector(
          onTap: () => taps++,
          child: const Text('control', textDirection: TextDirection.ltr),
        ),
      ),
    );
    final chrome = container.read(foliaChromeProvider.notifier);

    // Hidden: the fade is transparent and ignores pointer.
    await tester.pump();
    final fade = tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));
    expect(fade.opacity, 0);
    await tester.tap(find.text('control'), warnIfMissed: false);
    await tester.pump();
    expect(taps, 0);

    // Shown: the control receives the tap.
    chrome.show();
    await tester.pump();
    final shownFade = tester.widget<AnimatedOpacity>(
      find.byType(AnimatedOpacity),
    );
    expect(shownFade.opacity, 1);
    await tester.tap(find.text('control'));
    await tester.pump();
    expect(taps, 1);

    // Cancel the pending auto-hide timer before the test ends.
    chrome.hide();
    await tester.pump();
  });
}
