import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:muyin_music/core/xiaomi/mina_auth.dart';
import 'package:muyin_music/core/xiaomi/mina_models.dart';
import 'package:muyin_music/core/xiaomi/xiaomi_providers.dart';
import 'package:muyin_music/core/xiaomi/xiaomi_token_store.dart';
import 'package:muyin_music/features/settings/xiaoai/xiaomi_login_page.dart';
import 'package:muyin_music/theme/app_theme.dart';

import 'helpers/prism_test_environment.dart';
import 'xiaomi_mina_test_utils.dart';

class _MemorySecretStore implements XiaomiSecretStore {
  final Map<String, String> data = {};

  @override
  Future<String?> read(String key) async => data[key];

  @override
  Future<void> write(String key, String value) async {
    data[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    data.remove(key);
  }
}

const _step1Body =
    '&&&START&&&{"code":0,"qs":"qs1","sid":"micoapi","_sign":"sign1",'
    '"callback":"https://api.mina.mi.com/sts"}';

const _step2NeedVerifyBody =
    '&&&START&&&{"code":0,"notificationUrl":'
    '"https://account.xiaomi.com/fe/service/identity/authStart'
    '?sid=micoapi&context=ctx9"}';

/// 假 MinaAuth：账密登录走到 NeedVerify，发码四步全部成功。
Future<MinaAuth> _fakeAuth() async {
  final store = XiaomiTokenStore(_MemorySecretStore());
  await store.save(
    XiaomiTokenInfo(
      userId: '',
      deviceId: 'dev-fixed',
      passToken: '',
      services: const {},
      createdAtMs: 0,
    ),
  );
  final transport = FakeMinaTransport((req) {
    final url = req.urlText;
    if (url.contains('serviceLoginAuth2')) {
      return fakeJsonResponse(_step2NeedVerifyBody);
    }
    if (url.contains('serviceLogin')) return fakeJsonResponse(_step1Body);
    // 发码链：建会话 → 定方式（flag=4 手机）→ 触发 → 真发短信。
    if (url.contains('/fe/service/identity/authStart')) {
      return fakeJsonResponse('&&&START&&&{}');
    }
    if (url.contains('/identity/list')) {
      return fakeJsonResponse('&&&START&&&{"code":0,"flag":4}');
    }
    if (url.contains('/identity/auth/verifyPhone')) {
      return fakeJsonResponse('&&&START&&&{"code":0}');
    }
    if (url.contains('/identity/auth/sendPhoneTicket')) {
      return fakeJsonResponse('&&&START&&&{"code":0}');
    }
    throw StateError('unexpected request: $url');
  });
  return MinaAuth(http: transport, tokenStore: store);
}

Future<void> _pumpLoginPage(WidgetTester tester, MinaAuth auth) async {
  await tester.binding.setSurfaceSize(const Size(430, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final container = ProviderContainer(
    overrides: [minaAuthProvider.overrideWithValue(auth)],
  );
  addTearDown(container.dispose);
  final router = GoRouter(
    initialLocation: '/settings/xiaomi-login',
    routes: [
      GoRoute(
        path: '/settings/xiaomi-login',
        builder: (_, _) => const XiaomiLoginPage(),
      ),
      GoRoute(
        path: '/settings',
        builder: (_, _) => const Scaffold(body: Text('设置页占位')),
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

/// 冲刷假传输的异步链（不用 pumpAndSettle：发码成功后倒计时
/// Timer.periodic 会让它永远 settle 不下来）。
Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('登录页无页签：打开就是账密表单', (tester) async {
    await _pumpLoginPage(tester, await _fakeAuth());

    expect(find.byKey(const ValueKey('xiaomi-login-tab-qr')), findsNothing);
    expect(
      find.byKey(const ValueKey('xiaomi-login-tab-password')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('xiaomi-username-field')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('xiaomi-password-field')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('xiaomi-login-submit')), findsOneWidget);
  });

  testWidgets('NeedVerify 为 App 内发码形态：自动发码 + 倒计时，无外开按钮', (
    tester,
  ) async {
    await _pumpLoginPage(tester, await _fakeAuth());

    await tester.enterText(
      find.byKey(const ValueKey('xiaomi-username-field')),
      '13712340817',
    );
    await tester.enterText(
      find.byKey(const ValueKey('xiaomi-password-field')),
      'pw',
    );
    await tester.tap(find.byKey(const ValueKey('xiaomi-login-submit')));
    await _flush(tester);

    // 进入验证步即自动发码：发码按钮在位且已进入倒计时文案。
    expect(
      find.byKey(const ValueKey('xiaomi-verify-send-code')),
      findsOneWidget,
    );
    expect(find.textContaining('重新发送（'), findsOneWidget);

    // 外开取码形态必须消失。
    expect(
      find.byKey(const ValueKey('xiaomi-verify-open-page')),
      findsNothing,
    );
    expect(find.text('打开小米验证页面'), findsNothing);

    // 回填输入框与提交按钮在位。
    expect(
      find.byKey(const ValueKey('xiaomi-verify-code-field')),
      findsOneWidget,
    );
    expect(find.text('验证并登录'), findsOneWidget);
    expect(find.text('重新开始'), findsOneWidget);

    // 重新开始回表单（顺带取消倒计时定时器）。
    await tester.tap(find.text('重新开始'));
    await _flush(tester);
    expect(find.byKey(const ValueKey('xiaomi-login-submit')), findsOneWidget);
  });
}
