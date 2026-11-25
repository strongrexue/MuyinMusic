import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:muyin_music/core/storage/settings_store.dart';
import 'package:muyin_music/core/xiaomi/mina_models.dart';
import 'package:muyin_music/core/xiaomi/takeover/speaker_gateway.dart';
import 'package:muyin_music/core/xiaomi/takeover/speaker_resolver.dart';
import 'package:muyin_music/core/xiaomi/takeover/takeover_state.dart';
import 'package:muyin_music/core/xiaomi/takeover_providers.dart';
import 'package:muyin_music/core/xiaomi/xiaoai_foreground_host.dart';
import 'package:muyin_music/features/settings/xiaoai/xiaoai_settings_controller.dart';
import 'package:muyin_music/features/settings/xiaoai/xiaoai_speaker_card.dart';
import 'package:muyin_music/theme/app_theme.dart';

import 'helpers/prism_test_environment.dart';

const _device = MinaDevice(
  deviceId: 'dev-1',
  miotDid: '331987746',
  name: '小爱音箱Pro',
  alias: '',
  model: '',
  hardware: 'LX06',
  presence: 'online',
);

final _tokens = XiaomiTokenInfo(
  userId: '42',
  deviceId: 'client-1',
  passToken: 'pass-token',
  services: const {},
  createdAtMs: 0,
);

class _FakeGateway implements SpeakerGateway {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _FakeResolver implements SpeakerSongResolver {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// 只提供状态的假接管总控：enable/disable 不碰真实网关。
class _FakeTakeoverController extends XiaoaiTakeoverController {
  _FakeTakeoverController()
    : super(
        gateway: _FakeGateway(),
        resolver: _FakeResolver(),
        host: const XiaoaiForegroundHost(),
        queueTailProvider: (_) => const [],
      );

  void showState(XiaoaiTakeoverState value) => state = value;
}

XiaoaiSettingsController _makeSettingsController(
  SharedPreferences prefs, {
  required bool loggedIn,
  List<MinaDevice> devices = const [],
  List<MinaDevice>? enableLog,
}) {
  return XiaoaiSettingsController(
    prefs: prefs,
    loadTokens: () async => loggedIn ? _tokens : null,
    fetchDevices: () async => devices,
    validateSession: () async => true,
    doLogout: () async {},
    enableTakeover: (device) async {
      enableLog?.add(device);
    },
    disableTakeover: () async {},
  );
}

Future<void> _pumpCard(
  WidgetTester tester, {
  required XiaoaiSettingsController settings,
  required _FakeTakeoverController takeover,
  required SharedPreferences prefs,
}) async {
  await tester.binding.setSurfaceSize(const Size(430, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      xiaoaiSettingsProvider.overrideWith((ref) => settings),
      xiaoaiTakeoverControllerProvider.overrideWith((ref) => takeover),
    ],
  );
  addTearDown(container.dispose);
  final router = GoRouter(
    initialLocation: '/card',
    routes: [
      GoRoute(
        path: '/card',
        builder: (_, _) => const Scaffold(
          body: SingleChildScrollView(child: XiaoaiSpeakerCard()),
        ),
      ),
      GoRoute(
        path: '/settings/xiaomi-login',
        builder: (_, _) => const Scaffold(body: Text('登录页占位')),
      ),
      GoRoute(
        path: '/settings/xiaomi-devices',
        builder: (_, _) => const Scaffold(body: Text('设备页占位')),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        builder: buildPrismTestEnvironment,
        theme: AppTheme.light(),
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('未登录时显示登录入口，点击进入登录页', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    final settings = _makeSettingsController(prefs, loggedIn: false);
    await _pumpCard(
      tester,
      settings: settings,
      takeover: _FakeTakeoverController(),
      prefs: prefs,
    );

    expect(find.text('小爱音箱'), findsOneWidget);
    expect(find.text('未登录小米账号'), findsOneWidget);
    expect(find.textContaining('由胖虎音乐接管播放'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('xiaoai-login-button')));
    await tester.pumpAndSettle();
    expect(find.text('登录页占位'), findsOneWidget);
  });

  testWidgets('已登录单设备自动选中，拨开关调用 enable 接线', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    final enableLog = <MinaDevice>[];
    final settings = _makeSettingsController(
      prefs,
      loggedIn: true,
      devices: const [_device],
      enableLog: enableLog,
    );
    await settings.handleLoginSuccess();
    expect(settings.state.selectedDevice?.deviceId, _device.deviceId);

    await _pumpCard(
      tester,
      settings: settings,
      takeover: _FakeTakeoverController(),
      prefs: prefs,
    );

    expect(find.text('已登录'), findsOneWidget);
    expect(find.text('小爱音箱Pro · 在线'), findsOneWidget);
    expect(find.text('未开启'), findsOneWidget);
    expect(find.text('退出登录'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('xiaoai-takeover-switch')));
    await tester.pumpAndSettle();
    expect(enableLog, [_device]);
    expect(settings.state.takeoverEnabled, isTrue);
  });

  testWidgets('监听中显示最近接管记录', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    final settings = _makeSettingsController(
      prefs,
      loggedIn: true,
      devices: const [_device],
    );
    await settings.handleLoginSuccess();
    await settings.setTakeoverEnabled(true);

    final takeover = _FakeTakeoverController();
    takeover.showState(
      const XiaoaiTakeoverState(
        phase: TakeoverPhase.listening,
        deviceName: '小爱音箱Pro',
        lastRecord: TakeoverRecord(
          query: '播放歌曲晴天',
          title: '晴天',
          artist: '周杰伦',
          atMs: 0,
          success: true,
        ),
      ),
    );
    await _pumpCard(
      tester,
      settings: settings,
      takeover: takeover,
      prefs: prefs,
    );

    expect(find.text('监听中'), findsOneWidget);
    expect(find.text('最近接管'), findsOneWidget);
    expect(find.text('《晴天》·周杰伦·已播放'), findsOneWidget);
  });

  testWidgets('未选设备时拨开关先引导去选设备，不调用 enable', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    final enableLog = <MinaDevice>[];
    final settings = _makeSettingsController(
      prefs,
      loggedIn: true,
      devices: const [],
      enableLog: enableLog,
    );
    await settings.handleLoginSuccess();

    await _pumpCard(
      tester,
      settings: settings,
      takeover: _FakeTakeoverController(),
      prefs: prefs,
    );

    expect(find.text('未选择'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('xiaoai-takeover-switch')));
    await tester.pumpAndSettle();
    expect(find.text('设备页占位'), findsOneWidget);
    expect(enableLog, isEmpty);
    expect(settings.state.takeoverEnabled, isFalse);
  });

  test('自启恢复探活失败时静默关闭开关并留下状态说明', () async {
    final prefs = await SharedPreferences.getInstance();
    final controller = XiaoaiSettingsController(
      prefs: prefs,
      loadTokens: () async => _tokens,
      fetchDevices: () async => const [_device],
      validateSession: () async => false,
      doLogout: () async {},
      enableTakeover: (_) async {},
      disableTakeover: () async {},
    );
    addTearDown(controller.dispose);

    await controller.handleLoginSuccess();
    await controller.setTakeoverEnabled(true);
    expect(controller.state.takeoverEnabled, isTrue);

    await controller.restoreOnStartup();
    expect(controller.state.takeoverEnabled, isFalse);
    expect(controller.state.statusNote, contains('登录态已失效'));
    expect(prefs.getBool(kXiaoaiEnabledPrefsKey), isFalse);
  });
}
