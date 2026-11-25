import 'package:flutter_test/flutter_test.dart';
import 'package:muyin_music/core/xiaomi/mina_auth.dart';
import 'package:muyin_music/core/xiaomi/mina_constants.dart';
import 'package:muyin_music/core/xiaomi/mina_http.dart';
import 'package:muyin_music/core/xiaomi/mina_models.dart';
import 'package:muyin_music/core/xiaomi/xiaomi_token_store.dart';

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

const _step2OkBody =
    '&&&START&&&{"code":0,'
    '"location":"https://account.xiaomi.com/pass/sts?d=1",'
    '"ssecurity":"sec1","nonce":1610098522385872896,"userId":123456}';

Future<XiaomiTokenStore> _seededStore() async {
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
  return store;
}

void main() {
  group('MinaAuth 登录', () {
    test('happy path：三步登录，nonce 从原文提取，passToken 取 cookie', () async {
      final store = await _seededStore();
      var stsCalls = 0;
      final transport = FakeMinaTransport((req) {
        final url = req.urlText;
        if (url.contains('serviceLoginAuth2')) {
          return fakeJsonResponse(_step2OkBody);
        }
        if (url.contains('/pass/sts')) {
          stsCalls++;
          if (stsCalls == 1) {
            return fakeRedirect(
              'https://account.xiaomi.com/pass/sts-final',
              setCookies: ['passToken=pt-cookie; Path=/'],
            );
          }
          return fakeJsonResponse(
            '{}',
            setCookies: [
              'serviceToken=tok-abc; Path=/',
              'userId=123456; Path=/',
            ],
          );
        }
        if (url.contains('serviceLogin')) return fakeJsonResponse(_step1Body);
        throw StateError('unexpected request: $url');
      });
      final auth = MinaAuth(http: transport, tokenStore: store);

      final result = await auth.login('user@example.com', 'pw');

      expect(result, isA<MinaLoginSuccess>());
      final tokens = (result as MinaLoginSuccess).tokens;
      expect(tokens.userId, '123456');
      expect(tokens.passToken, 'pt-cookie');
      expect(tokens.service(kMinaSid)?.serviceToken, 'tok-abc');
      expect(tokens.service(kMinaSid)?.ssecurity, 'sec1');

      // step2 表单：密码 MD5 大写 + _sign 来自 step1。
      final step2 = transport.requestsTo('serviceLoginAuth2').single;
      expect(step2.form['hash'], xiaomiPasswordHash('pw'));
      expect(step2.form['_sign'], 'sign1');
      expect(step2.form['user'], 'user@example.com');

      // step3 请求 URL 带 clientSign=base64(SHA1("nonce=..&ssecurity"))，
      // nonce 是原始文本里的大整数（1610098522385872896 超过 JS 安全整数，
      // 但 Dart int 也不该靠解析后的 JSON 值——这里断言原文提取结果）。
      final sts = transport.requestsTo('/pass/sts').first;
      expect(
        sts.url.queryParameters['clientSign'],
        computeXiaomiClientSign('1610098522385872896', 'sec1'),
      );
      expect(sts.url.queryParameters['_userIdNeedEncrypt'], 'true');
    });

    test('图形验证码插入后可恢复同一次登录', () async {
      final store = await _seededStore();
      var step2Calls = 0;
      final transport = FakeMinaTransport((req) {
        final url = req.urlText;
        if (url.contains('serviceLoginAuth2')) {
          step2Calls++;
          if (step2Calls == 1) {
            return fakeJsonResponse(
              '{"code":87001,"captchaUrl":"/pass/captcha/img?id=9"}',
            );
          }
          return fakeJsonResponse(_step2OkBody);
        }
        if (url.contains('/pass/captcha/img')) {
          return MinaHttpResponse(
            statusCode: 200,
            bodyBytes: const [137, 80, 78, 71],
            headers: const {
              'set-cookie': ['ick=ick-42; Path=/'],
            },
          );
        }
        if (url.contains('/pass/sts')) {
          return fakeJsonResponse(
            '{}',
            setCookies: ['serviceToken=tok-abc; Path=/'],
          );
        }
        if (url.contains('serviceLogin')) return fakeJsonResponse(_step1Body);
        throw StateError('unexpected request: $url');
      });
      final auth = MinaAuth(http: transport, tokenStore: store);

      final first = await auth.login('user@example.com', 'pw');
      expect(first, isA<MinaLoginNeedCaptcha>());
      final need = first as MinaLoginNeedCaptcha;
      expect(need.imageBytes, [137, 80, 78, 71]);

      final second = await auth.submitCaptcha('AB12');
      expect(second, isA<MinaLoginSuccess>());

      // 第二次提交带上验证码与 ick cookie。
      final step2 = transport.requestsTo('serviceLoginAuth2');
      expect(step2.length, 2);
      expect(step2.last.form['captCode'], 'AB12');
      expect(step2.last.headers['Cookie'], contains('ick=ick-42'));
    });

    test('短信验证插入后可恢复：发码四步 + 提交换 passToken + 续 serviceToken', () async {
      final store = await _seededStore();
      var serviceLoginCalls = 0;
      final transport = FakeMinaTransport((req) {
        final url = req.urlText;
        if (url.contains('serviceLoginAuth2')) {
          return fakeJsonResponse(
            '{"code":0,"notificationUrl":'
            '"https://account.xiaomi.com/fe/service/identity/authStart'
            '?sid=micoapi&context=ctx9"}',
          );
        }
        if (url.contains('/identity/list')) {
          return fakeJsonResponse('{"flag":4}');
        }
        if (url.contains('/identity/auth/verifyPhone')) {
          if (req.method == 'GET') return fakeJsonResponse('{"code":0}');
          return fakeJsonResponse(
            '{"code":0,'
            '"location":"https://account.xiaomi.com/pass/sts?d=2"}',
          );
        }
        if (url.contains('/identity/auth/sendPhoneTicket')) {
          return fakeJsonResponse('{"code":0}');
        }
        if (url.contains('/fe/service/identity/authStart')) {
          return fakeJsonResponse('{}');
        }
        if (url.contains('/pass/sts?d=2')) {
          return fakeJsonResponse(
            '{}',
            setCookies: [
              'passToken=pt-verify; Path=/',
              'userId=123456; Path=/',
            ],
          );
        }
        if (url.contains('/pass/sts?d=3')) {
          return fakeJsonResponse(
            '{}',
            setCookies: ['serviceToken=tok-verify; Path=/'],
          );
        }
        if (url.contains('serviceLogin')) {
          serviceLoginCalls++;
          if (serviceLoginCalls == 1) return fakeJsonResponse(_step1Body);
          // passToken 续期（securityTokenService）。
          return fakeJsonResponse(
            '{"code":0,'
            '"location":"https://account.xiaomi.com/pass/sts?d=3",'
            '"ssecurity":"sec2","nonce":42}',
          );
        }
        throw StateError('unexpected request: ${req.method} $url');
      });
      final auth = MinaAuth(http: transport, tokenStore: store);

      final first = await auth.login('user@example.com', 'pw');
      expect(first, isA<MinaLoginNeedVerify>());
      expect((first as MinaLoginNeedVerify).kind, XiaomiVerifyKind.phone);

      expect(await auth.sendVerificationCode(), isTrue);
      // 发码链路走过 verifyPhone GET 与 sendPhoneTicket POST。
      expect(
        transport.requestsTo('/identity/auth/verifyPhone').first.method,
        'GET',
      );
      expect(transport.requestsTo('sendPhoneTicket'), hasLength(1));

      final second = await auth.submitVerifyCode('654321');
      expect(second, isA<MinaLoginSuccess>());
      final tokens = (second as MinaLoginSuccess).tokens;
      expect(tokens.passToken, 'pt-verify');
      expect(tokens.service(kMinaSid)?.serviceToken, 'tok-verify');

      // 提交验证码的表单：ticket/trust/_flag=4（手机）。
      final submit = transport.requestsTo('/identity/auth/verifyPhone').last;
      expect(submit.method, 'POST');
      expect(submit.form['ticket'], '654321');
      expect(submit.form['_flag'], '4');
      expect(submit.form['trust'], 'true');
    });
  });

  group('MinaAuth token 生命周期', () {
    test('passToken 续期换新 serviceToken 并落盘', () async {
      final store = await _seededStore();
      await store.save(
        XiaomiTokenInfo(
          userId: '42',
          deviceId: 'dev-fixed',
          passToken: 'pt-old',
          services: {
            kMinaSid: XiaomiServiceToken(
              serviceToken: 'tok-old',
              ssecurity: 'sec-old',
              expiresAtMs: 1, // 早已过期
            ),
          },
          createdAtMs: 0,
        ),
      );
      final transport = FakeMinaTransport((req) {
        final url = req.urlText;
        if (url.contains('/pass/sts')) {
          return fakeJsonResponse(
            '{}',
            setCookies: ['serviceToken=tok-new; Path=/'],
          );
        }
        if (url.contains('serviceLogin')) {
          expect(req.headers['Cookie'], contains('passToken=pt-old'));
          return fakeJsonResponse(
            '{"code":0,'
            '"location":"https://account.xiaomi.com/pass/sts?d=9",'
            '"ssecurity":"sec9","nonce":7}',
          );
        }
        throw StateError('unexpected request: $url');
      });
      final auth = MinaAuth(http: transport, tokenStore: store);

      expect(await auth.refreshServiceToken(), isTrue);
      expect(store.cached?.service(kMinaSid)?.serviceToken, 'tok-new');
      expect(store.cached?.service(kMinaSid)?.ssecurity, 'sec9');
      expect(store.cached?.passToken, 'pt-old');
    });

    test('ensureFresh：有效期充足时零请求，临近过期才刷新', () async {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final store = await _seededStore();
      await store.save(
        XiaomiTokenInfo(
          userId: '42',
          deviceId: 'dev-fixed',
          passToken: 'pt',
          services: {
            kMinaSid: XiaomiServiceToken(
              serviceToken: 'tok',
              ssecurity: 'sec',
              expiresAtMs: nowMs + kServiceTokenValidHours * 3600 * 1000,
            ),
          },
          createdAtMs: nowMs,
        ),
      );
      final transport = FakeMinaTransport((req) {
        throw StateError('should not be called');
      });
      final auth = MinaAuth(http: transport, tokenStore: store);

      expect(await auth.ensureFreshServiceToken(), isTrue);
      expect(transport.requests, isEmpty);
    });
  });

  group('XiaomiTokenStore', () {
    test('TokenInfo JSON 往返与 deviceId 稳定', () async {
      final store = XiaomiTokenStore(_MemorySecretStore());
      final info = XiaomiTokenInfo(
        userId: '7',
        deviceId: 'dev-x',
        passToken: 'pt',
        services: {
          kMinaSid: XiaomiServiceToken(
            serviceToken: 't',
            ssecurity: 's',
            expiresAtMs: 99,
          ),
        },
        createdAtMs: 5,
      );
      await store.save(info);
      final loaded = await XiaomiTokenStore(_MemorySecretStore()).load();
      expect(loaded, isNull); // 不同底层存储互不可见（ sanity ）

      final again = await store.load();
      expect(again?.encode(), info.encode());
      expect(await store.deviceId(), 'dev-x');
    });

    test('deviceId 首次生成后稳定', () async {
      final store = XiaomiTokenStore(_MemorySecretStore());
      final first = await store.deviceId();
      expect(first, hasLength(32));
      expect(await store.deviceId(), first);
    });
  });
}
