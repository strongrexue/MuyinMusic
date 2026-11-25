import 'dart:io';
import 'dart:async';

import 'package:muyin_music/core/app_info.dart';
import 'package:muyin_music/core/services/app_update_service.dart';
import 'package:muyin_music/core/storage/settings_store.dart';
import 'package:muyin_music/core/ui/app_toast.dart';
import 'package:muyin_music/core/ui/widgets/prism_environment.dart';
import 'package:muyin_music/features/update/app_update_prompt.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          pathProviderChannel,
          (_) async => Directory.systemTemp.path,
        );
  });
  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
  });

  const releaseUri =
      'https://github.com/strongrexue/MuyinMusic/releases/tag/v1.1.0';

  testWidgets('newer release shows dialog and later does not open GitHub', (
    tester,
  ) async {
    final service = _FakeAppUpdateService(
      release: _release(version: '1.1.0', pageUri: releaseUri),
    );
    final launchedUris = <Uri>[];
    AppUpdateCheckOutcome? outcome;
    await _pumpHarness(
      tester,
      service: service,
      launcher: (uri) async {
        launchedUris.add(uri);
        return true;
      },
      onOutcome: (value) => outcome = value,
    );

    await tester.tap(find.byKey(const ValueKey('check-update')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('app-update-dialog')), findsOneWidget);
    expect(find.text('发现新版本'), findsOneWidget);
    expect(find.textContaining('1.0.1  →  1.1.0'), findsOneWidget);
    expect(find.textContaining('胖虎音乐 1.1.0'), findsOneWidget);
    expect(outcome, isNull);

    await tester.tap(find.byKey(const ValueKey('app-update-later')));
    await tester.pumpAndSettle();

    expect(launchedUris, isEmpty);
    expect(outcome, AppUpdateCheckOutcome.updateAvailable);
    expect(service.callCount, 1);
  });

  testWidgets('download action opens the exact release URI', (tester) async {
    final service = _FakeAppUpdateService(
      release: _release(version: '1.1.0', pageUri: releaseUri),
    );
    final launchedUris = <Uri>[];
    AppUpdateCheckOutcome? outcome;
    await _pumpHarness(
      tester,
      service: service,
      launcher: (uri) async {
        launchedUris.add(uri);
        return true;
      },
      onOutcome: (value) => outcome = value,
    );

    await tester.tap(find.byKey(const ValueKey('check-update')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('app-update-open-release')));
    await tester.pumpAndSettle();

    expect(launchedUris, [Uri.parse(releaseUri)]);
    expect(outcome, AppUpdateCheckOutcome.updateAvailable);
  });

  testWidgets('same release reports that the app is up to date', (
    tester,
  ) async {
    final service = _FakeAppUpdateService(
      release: _release(
        version: '1.0.1',
        pageUri:
            'https://github.com/strongrexue/MuyinMusic/releases/tag/v1.0.1',
      ),
    );
    final launchedUris = <Uri>[];
    AppUpdateCheckOutcome? outcome;
    await _pumpHarness(
      tester,
      service: service,
      launcher: (uri) async {
        launchedUris.add(uri);
        return true;
      },
      onOutcome: (value) => outcome = value,
    );

    await tester.tap(find.byKey(const ValueKey('check-update')));
    await tester.pumpAndSettle();

    expect(find.text('已是最新版（1.0.1）'), findsOneWidget);
    expect(find.byKey(const ValueKey('app-update-dialog')), findsNothing);
    expect(launchedUris, isEmpty);
    expect(outcome, AppUpdateCheckOutcome.upToDate);

    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });

  testWidgets('service failure reports that the update check failed', (
    tester,
  ) async {
    final service = _FakeAppUpdateService(error: StateError('network down'));
    AppUpdateCheckOutcome? outcome;
    await _pumpHarness(
      tester,
      service: service,
      launcher: (_) async => true,
      onOutcome: (value) => outcome = value,
    );

    await tester.tap(find.byKey(const ValueKey('check-update')));
    await tester.pumpAndSettle();
    for (var attempt = 0; attempt < 10 && outcome == null; attempt += 1) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.text('检查更新失败，请稍后重试'), findsOneWidget);
    expect(find.byKey(const ValueKey('app-update-dialog')), findsNothing);
    expect(outcome, AppUpdateCheckOutcome.failed);
    expect(service.callCount, 1);

    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });

  testWidgets('concurrent checks share one request and do not stack dialogs', (
    tester,
  ) async {
    final pendingRelease = Completer<AppRelease?>();
    final service = _FakeAppUpdateService(
      pendingRelease: pendingRelease.future,
    );
    final outcomes = <AppUpdateCheckOutcome>[];
    await _pumpHarness(
      tester,
      service: service,
      launcher: (_) async => true,
      onOutcome: outcomes.add,
    );

    await tester.tap(find.byKey(const ValueKey('check-update')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('check-update')));
    await tester.pump();

    expect(service.callCount, 1);
    expect(outcomes, contains(AppUpdateCheckOutcome.alreadyChecking));

    pendingRelease.complete(_release(version: '1.1.0', pageUri: releaseUri));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('app-update-dialog')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('app-update-later')));
    await tester.pumpAndSettle();
    expect(service.callCount, 1);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });

  testWidgets('ignore records only that version and keeps startup check on', (
    tester,
  ) async {
    SharedPreferences? prefs;
    final service = _FakeAppUpdateService(
      release: _release(version: '1.1.0', pageUri: releaseUri),
    );
    AppUpdateCheckOutcome? outcome;
    await _pumpHarness(
      tester,
      service: service,
      launcher: (_) async => true,
      onOutcome: (value) => outcome = value,
      onPrefs: (value) => prefs = value,
    );

    await tester.tap(find.byKey(const ValueKey('check-update')));
    await tester.pumpAndSettle();
    expect(find.text('忽略此版本'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('app-update-ignore')));
    await tester.pumpAndSettle();

    expect(prefs!.getString('ignored_app_update_version'), 'v1.1.0');
    expect(prefs!.getBool('check_for_updates_on_startup'), isNot(false));
    expect(outcome, AppUpdateCheckOutcome.updateAvailable);

    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });

  testWidgets('automatic check skips an ignored version silently', (
    tester,
  ) async {
    final service = _FakeAppUpdateService(
      release: _release(version: '1.1.0', pageUri: releaseUri),
    );
    AppUpdateCheckOutcome? outcome;
    await _pumpHarness(
      tester,
      service: service,
      launcher: (_) async => true,
      onOutcome: (value) => outcome = value,
      showFeedback: false,
      initialPrefs: const {'ignored_app_update_version': 'v1.1.0'},
    );

    await tester.tap(find.byKey(const ValueKey('check-update')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('app-update-dialog')), findsNothing);
    expect(outcome, AppUpdateCheckOutcome.ignoredVersion);
    expect(service.callCount, 1);
  });

  testWidgets('automatic check still prompts for a version newer than the '
      'ignored one', (tester) async {
    final service = _FakeAppUpdateService(
      release: _release(
        version: '1.2.0',
        pageUri:
            'https://github.com/strongrexue/MuyinMusic/releases/tag/v1.2.0',
      ),
    );
    AppUpdateCheckOutcome? outcome;
    await _pumpHarness(
      tester,
      service: service,
      launcher: (_) async => true,
      onOutcome: (value) => outcome = value,
      showFeedback: false,
      initialPrefs: const {'ignored_app_update_version': 'v1.1.0'},
    );

    await tester.tap(find.byKey(const ValueKey('check-update')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('app-update-dialog')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('app-update-later')));
    await tester.pumpAndSettle();
    expect(outcome, AppUpdateCheckOutcome.updateAvailable);
  });

  testWidgets('manual check bypasses the ignored version', (tester) async {
    final service = _FakeAppUpdateService(
      release: _release(version: '1.1.0', pageUri: releaseUri),
    );
    AppUpdateCheckOutcome? outcome;
    await _pumpHarness(
      tester,
      service: service,
      launcher: (_) async => true,
      onOutcome: (value) => outcome = value,
      initialPrefs: const {'ignored_app_update_version': 'v1.1.0'},
    );

    await tester.tap(find.byKey(const ValueKey('check-update')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('app-update-dialog')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('app-update-later')));
    await tester.pumpAndSettle();
    expect(outcome, AppUpdateCheckOutcome.updateAvailable);

    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });

  testWidgets('later writes nothing and the next cold start prompts again', (
    tester,
  ) async {
    SharedPreferences? prefs;
    final service = _FakeAppUpdateService(
      release: _release(version: '1.1.0', pageUri: releaseUri),
    );
    AppUpdateCheckOutcome? outcome;
    await _pumpHarness(
      tester,
      service: service,
      launcher: (_) async => true,
      onOutcome: (value) => outcome = value,
      showFeedback: false,
      onPrefs: (value) => prefs = value,
    );

    await tester.tap(find.byKey(const ValueKey('check-update')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('app-update-later')));
    await tester.pumpAndSettle();

    expect(outcome, AppUpdateCheckOutcome.updateAvailable);
    // snooze 不落任何持久状态，误触可自愈。
    expect(prefs!.getString('ignored_app_update_version'), isNull);
    expect(prefs!.getBool('check_for_updates_on_startup'), isNot(false));

    // 模拟下次冷启动：重建容器，持久状态里没有忽略记录，应再次提示。
    AppUpdateCheckOutcome? secondOutcome;
    await _pumpHarness(
      tester,
      service: service,
      launcher: (_) async => true,
      onOutcome: (value) => secondOutcome = value,
      showFeedback: false,
    );
    await tester.tap(find.byKey(const ValueKey('check-update')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('app-update-dialog')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('app-update-later')));
    await tester.pumpAndSettle();
    expect(secondOutcome, AppUpdateCheckOutcome.updateAvailable);
  });

  testWidgets('legacy globally disabled startup check is healed once', (
    tester,
  ) async {
    final service = _FakeAppUpdateService(
      release: _release(version: '1.1.0', pageUri: releaseUri),
    );
    await _pumpHarness(
      tester,
      service: service,
      launcher: (_) async => true,
      onOutcome: (_) {},
      initialPrefs: const {'check_for_updates_on_startup': false},
    );

    final context = tester.element(
      find.byKey(const ValueKey('check-update')),
    );
    final container = ProviderScope.containerOf(context);
    expect(container.read(settingsProvider).checkForUpdatesOnStartup, isTrue);
  });
}

AppRelease _release({required String version, required String pageUri}) {
  return AppRelease(
    version: Version.parse(version),
    tagName: 'v$version',
    pageUri: Uri.parse(pageUri),
    title: '胖虎音乐 $version',
  );
}

Future<void> _pumpHarness(
  WidgetTester tester, {
  required AppUpdateService service,
  required ExternalUriLauncher launcher,
  required ValueChanged<AppUpdateCheckOutcome> onOutcome,
  bool showFeedback = true,
  Map<String, Object> initialPrefs = const {},
  ValueChanged<SharedPreferences>? onPrefs,
}) async {
  PackageInfo.setMockInitialValues(
    appName: appDisplayName,
    packageName: 'com.muyin.muyinmusic',
    version: '1.0.1',
    buildNumber: '2',
    buildSignature: '',
  );
  SharedPreferences.setMockInitialValues(initialPrefs);
  final prefs = await SharedPreferences.getInstance();
  onPrefs?.call(prefs);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appUpdateServiceProvider.overrideWithValue(service),
        externalUriLauncherProvider.overrideWithValue(launcher),
        sharedPreferencesProvider.overrideWithValue(prefs),
      ],
      child: MaterialApp(
        localizationsDelegates: const [PrismChineseStrings.delegate],
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        ),
        builder: (context, child) =>
            AppToastOverlay(child: child ?? const SizedBox.shrink()),
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => Center(
              child: FilledButton(
                key: const ValueKey('check-update'),
                onPressed: () async {
                  onOutcome(
                    await checkForAppUpdate(
                      context,
                      ref,
                      showFeedback: showFeedback,
                    ),
                  );
                },
                child: const Text('检查更新'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _FakeAppUpdateService implements AppUpdateService {
  _FakeAppUpdateService({this.release, this.error, this.pendingRelease});

  final AppRelease? release;
  final Object? error;
  final Future<AppRelease?>? pendingRelease;
  int callCount = 0;

  @override
  Future<AppRelease?> fetchLatestRelease() async {
    callCount += 1;
    final failure = error;
    if (failure != null) throw failure;
    final pending = pendingRelease;
    if (pending != null) return pending;
    return release;
  }
}
