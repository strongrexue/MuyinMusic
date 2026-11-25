import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:muyin_music/core/storage/settings_store.dart';
import 'package:muyin_music/core/xiaomi/lan_stream_server.dart';
import 'package:muyin_music/core/xiaomi/mina_models.dart';
import 'package:muyin_music/core/xiaomi/takeover/speaker_gateway.dart';
import 'package:muyin_music/core/xiaomi/takeover/speaker_resolver.dart';
import 'package:muyin_music/core/xiaomi/takeover/takeover_state.dart';
import 'package:muyin_music/core/xiaomi/takeover/wake_word_filter.dart';
import 'package:muyin_music/core/xiaomi/takeover_providers.dart';
import 'package:muyin_music/core/xiaomi/xiaoai_foreground_host.dart';
import 'package:muyin_music/features/settings/settings_page.dart';
import 'package:muyin_music/features/settings/xiaoai/xiaoai_settings_controller.dart';
import 'package:muyin_music/features/settings/xiaoai/xiaoai_speaker_page.dart';
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
        streamServer: LanStreamServer(),
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

ProviderContainer _makeContainer({
  required XiaoaiSettingsController settings,
  required _FakeTakeoverController takeover,
  required SharedPreferences prefs,
}) {
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      xiaoaiCardSupportedProvider.overrideWith((ref) => true),
      xiaoaiSettingsProvider.overrideWith((ref) => settings),
      xiaoaiTakeoverControllerProvider.overrideWith((ref) => takeover),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _pumpPage(
  WidgetTester tester, {
  required XiaoaiSettingsController settings,
  required _FakeTakeoverController takeover,
  required SharedPreferences prefs,
}) async {
  await tester.binding.setSurfaceSize(const Size(430, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final container = _makeContainer(
    settings: settings,
    takeover: takeover,
    prefs: prefs,
  );
  final router = GoRouter(
    initialLocation: '/settings/xiaomi',
    routes: [
      GoRoute(
        path: '/settings/xiaomi',
        builder: (_, _) => const XiaoaiSpeakerPage(),
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
    await _pumpPage(
      tester,
      settings: settings,
      takeover: _FakeTakeoverController(),
      prefs: prefs,
    );

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

    await _pumpPage(
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
    const record = TakeoverRecord(
      query: '播放歌曲晴天',
      title: '晴天',
      artist: '周杰伦',
      atMs: 0,
      success: true,
    );
    takeover.showState(
      const XiaoaiTakeoverState(
        phase: TakeoverPhase.listening,
        deviceName: '小爱音箱Pro',
        lastRecord: record,
        records: [record],
      ),
    );
    await _pumpPage(
      tester,
      settings: settings,
      takeover: takeover,
      prefs: prefs,
    );

    expect(find.text('监听中'), findsOneWidget);
    expect(find.text('最近接管'), findsOneWidget);
    expect(find.text('《晴天》·周杰伦·已播放'), findsOneWidget);
  });

  testWidgets('最近接管渲染 records 列表（新→旧，含音源/音质/时间 meta）', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    final settings = _makeSettingsController(
      prefs,
      loggedIn: true,
      devices: const [_device],
    );
    await settings.handleLoginSuccess();
    await settings.setTakeoverEnabled(true);

    int at(int hour, int minute) =>
        DateTime(2026, 1, 1, hour, minute).millisecondsSinceEpoch;
    final takeover = _FakeTakeoverController();
    takeover.showState(
      XiaoaiTakeoverState(
        phase: TakeoverPhase.listening,
        deviceName: '小爱音箱Pro',
        records: [
          TakeoverRecord(
            query: '播放歌三',
            title: '歌三',
            artist: '歌手三',
            atMs: at(9, 5),
            success: true,
            sourceName: '网易云',
            qualityLabel: '320k',
            viaProxy: true,
          ),
          TakeoverRecord(
            query: '播放歌二',
            title: '歌二',
            artist: '歌手二',
            atMs: at(8, 30),
            success: true,
            sourceName: 'QQ音乐',
            qualityLabel: '128k',
          ),
          TakeoverRecord(
            query: '播放歌一',
            title: '歌一',
            artist: '歌手一',
            atMs: at(7, 15),
            success: false,
            detail: '推播未落地',
          ),
        ],
      ),
    );
    await _pumpPage(
      tester,
      settings: settings,
      takeover: takeover,
      prefs: prefs,
    );

    expect(find.text('《歌三》·歌手三·已播放'), findsOneWidget);
    expect(find.text('《歌二》·歌手二·已播放'), findsOneWidget);
    expect(find.text('《歌一》·歌手一·推播未落地'), findsOneWidget);
    expect(find.text('09:05 · 网易云 · 320k · 局域网代理'), findsOneWidget);
    expect(find.text('08:30 · QQ音乐 · 128k · 直推'), findsOneWidget);
    expect(find.text('07:15 · 直推'), findsOneWidget);
    // 顺序新→旧：歌三在歌二之上，歌二在歌一之上。
    final dy3 = tester.getTopLeft(find.text('《歌三》·歌手三·已播放')).dy;
    final dy2 = tester.getTopLeft(find.text('《歌二》·歌手二·已播放')).dy;
    final dy1 = tester.getTopLeft(find.text('《歌一》·歌手一·推播未落地')).dy;
    expect(dy3 < dy2 && dy2 < dy1, isTrue);
  });

  testWidgets('有诊断日志时显示「诊断日志」区，条目直显无需展开', (tester) async {
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
        diagnosticLog: [
          '16:20:05 takeover mute failed: setVolume(0) not acknowledged',
          '16:20:31 takeover push receipt=true but verify=foreignPlaying',
        ],
      ),
    );
    await _pumpPage(
      tester,
      settings: settings,
      takeover: takeover,
      prefs: prefs,
    );

    expect(find.text('诊断日志'), findsOneWidget);
    expect(find.byType(ExpansionTile), findsNothing);
    expect(
      find.text('16:20:05 takeover mute failed: setVolume(0) not acknowledged'),
      findsOneWidget,
    );
    expect(
      find.text(
        '16:20:31 takeover push receipt=true but verify=foreignPlaying',
      ),
      findsOneWidget,
    );
  });

  testWidgets('无诊断日志时显示明确空态文案，不出现折叠灰块', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    final settings = _makeSettingsController(
      prefs,
      loggedIn: true,
      devices: const [_device],
    );
    await settings.handleLoginSuccess();
    await settings.setTakeoverEnabled(true);

    // 初始 state（diagnosticLog 为空）直接渲染：日志区在、空态文案可见。
    await _pumpPage(
      tester,
      settings: settings,
      takeover: _FakeTakeoverController(),
      prefs: prefs,
    );

    expect(find.text('诊断日志'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('xiaoai-diagnostic-log-empty')),
      findsOneWidget,
    );
    expect(find.text('暂无诊断日志'), findsOneWidget);
    expect(find.byType(ExpansionTile), findsNothing);
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

    await _pumpPage(
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

  testWidgets('设置页总览只剩入口行，点击进入独立页', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    final settings = _makeSettingsController(
      prefs,
      loggedIn: true,
      devices: const [_device],
    );
    await settings.handleLoginSuccess();

    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final container = _makeContainer(
      settings: settings,
      takeover: _FakeTakeoverController(),
      prefs: prefs,
    );
    final router = GoRouter(
      initialLocation: '/settings',
      routes: [
        GoRoute(path: '/settings', builder: (_, _) => const SettingsPage()),
        GoRoute(
          path: '/settings/xiaomi',
          builder: (_, _) => const XiaoaiSpeakerPage(),
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

    // 总览里只有入口行：标题 + 状态副标题在，三态卡内容不在。
    expect(find.byKey(const ValueKey('xiaoai-settings-entry')), findsOneWidget);
    expect(find.text('小爱音箱'), findsOneWidget);
    expect(find.text('未开启'), findsOneWidget);
    expect(find.byKey(const ValueKey('xiaoai-takeover-switch')), findsNothing);
    expect(find.text('退出登录'), findsNothing);
    expect(find.text('登录小米账号'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('xiaoai-settings-entry')));
    await tester.pumpAndSettle();

    // 独立页：账号区与接管开关都在。
    expect(find.byType(XiaoaiSpeakerPage), findsOneWidget);
    expect(find.text('已登录'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('xiaoai-takeover-switch')),
      findsOneWidget,
    );
    expect(find.text('退出登录'), findsOneWidget);
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

  testWidgets('开启专属口令后出现口令词行并显示当前词', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    final settings = _makeSettingsController(
      prefs,
      loggedIn: true,
      devices: const [_device],
    );
    await settings.handleLoginSuccess();
    await settings.setWakeWordEnabled(true);

    await _pumpPage(
      tester,
      settings: settings,
      takeover: _FakeTakeoverController(),
      prefs: prefs,
    );

    expect(find.text('专属口令'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('xiaoai-wake-word-switch')),
      findsOneWidget,
    );
    expect(find.text('口令词'), findsOneWidget);
    expect(find.text(kDefaultWakeWord), findsOneWidget);
  });

  testWidgets('专属口令关闭时无口令词行', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    final settings = _makeSettingsController(
      prefs,
      loggedIn: true,
      devices: const [_device],
    );
    await settings.handleLoginSuccess();

    await _pumpPage(
      tester,
      settings: settings,
      takeover: _FakeTakeoverController(),
      prefs: prefs,
    );

    expect(find.text('专属口令'), findsOneWidget);
    expect(find.text('口令词'), findsNothing);
  });

  test('专属口令 prefs 读写、空词不更新、过滤器同步回调', () async {
    final prefs = await SharedPreferences.getInstance();
    final synced = <WakeWordFilter>[];
    XiaoaiSettingsController make() => XiaoaiSettingsController(
      prefs: prefs,
      loadTokens: () async => null,
      fetchDevices: () async => const [],
      validateSession: () async => true,
      doLogout: () async {},
      enableTakeover: (_) async {},
      disableTakeover: () async {},
      syncWakeWordFilter: synced.add,
    );

    final controller = make();
    addTearDown(controller.dispose);
    await controller.initialize();
    expect(controller.state.wakeWordEnabled, isFalse);
    expect(controller.state.wakeWord, kDefaultWakeWord);
    expect(synced.last.enabled, isFalse);
    expect(synced.last.word, kDefaultWakeWord);

    await controller.setWakeWordEnabled(true);
    expect(prefs.getBool(kXiaoaiWakeWordEnabledPrefsKey), isTrue);
    expect(synced.last.enabled, isTrue);

    await controller.setWakeWord(' 阿虎 ');
    expect(controller.state.wakeWord, '阿虎');
    expect(prefs.getString(kXiaoaiWakeWordPrefsKey), '阿虎');
    expect(synced.last.word, '阿虎');

    await controller.setWakeWord('   ');
    expect(controller.state.wakeWord, '阿虎');
    expect(prefs.getString(kXiaoaiWakeWordPrefsKey), '阿虎');

    // 新控制器从 prefs 读回。
    final restored = make();
    addTearDown(restored.dispose);
    await restored.initialize();
    expect(restored.state.wakeWordEnabled, isTrue);
    expect(restored.state.wakeWord, '阿虎');
    expect(synced.last.enabled, isTrue);
    expect(synced.last.word, '阿虎');
  });
}
