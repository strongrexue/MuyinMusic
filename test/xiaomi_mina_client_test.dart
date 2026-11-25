import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:muyin_music/core/xiaomi/mina_auth.dart';
import 'package:muyin_music/core/xiaomi/mina_client.dart';
import 'package:muyin_music/core/xiaomi/mina_constants.dart';
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

Future<XiaomiTokenStore> _loggedInStore({String serviceToken = 'tok-1'}) async {
  final store = XiaomiTokenStore(_MemorySecretStore());
  await store.save(
    XiaomiTokenInfo(
      userId: '42',
      deviceId: 'dev-fixed',
      passToken: 'pt-1',
      services: {
        kMinaSid: XiaomiServiceToken(
          serviceToken: serviceToken,
          ssecurity: 'sec',
          expiresAtMs:
              DateTime.now().millisecondsSinceEpoch + kServiceTokenValidHours * 3600 * 1000,
        ),
      },
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
    ),
  );
  return store;
}

MinaClient _client(FakeMinaTransport transport, XiaomiTokenStore store) {
  final auth = MinaAuth(http: transport, tokenStore: store);
  return MinaClient(http: transport, auth: auth, tokenStore: store);
}

const _deviceListBody =
    '{"code":0,"message":"ok","data":['
    '{"deviceID":"did-1","miotDID":"331987746","name":"小爱音箱Pro",'
    '"alias":"客厅","model":"Xiaomi Smart Speaker Pro","hardware":"LX06",'
    '"presence":"online","mac":"aa:bb:cc:dd:ee:ff"}]}';

void main() {
  group('MinaClient 设备列表', () {
    test('解析字段 + Cookie/UA 按蓝本拼装', () async {
      final store = await _loggedInStore();
      final transport = FakeMinaTransport((req) {
        if (req.urlText.contains('device_list')) {
          return fakeJsonResponse(_deviceListBody);
        }
        throw StateError('unexpected request: ${req.urlText}');
      });
      final client = _client(transport, store);

      final devices = await client.getDeviceList();
      expect(devices, hasLength(1));
      final d = devices.single;
      expect(d.deviceId, 'did-1');
      expect(d.miotDid, '331987746');
      expect(d.name, '小爱音箱Pro');
      expect(d.alias, '客厅');
      expect(d.hardware, 'LX06');
      expect(d.isOnline, isTrue);

      final req = transport.requestsTo('device_list').single;
      expect(
        req.headers['Cookie'],
        'userId=42; serviceToken=tok-1; channel=MI_APP_STORE',
      );
      expect(req.headers['User-Agent'], contains('dev-fixed'));
      expect(await client.validateToken(), isTrue);
    });

    test('device_list 401 → passToken 刷新 → 带新 token 重试成功', () async {
      final store = await _loggedInStore(serviceToken: 'tok-old');
      final transport = FakeMinaTransport((req) {
        final url = req.urlText;
        if (url.contains('device_list')) {
          if ((req.headers['Cookie'] ?? '').contains('tok-old')) {
            return fakeJsonResponse('', status: 401);
          }
          return fakeJsonResponse(_deviceListBody);
        }
        if (url.contains('/pass/sts')) {
          return fakeJsonResponse(
            '{}',
            setCookies: ['serviceToken=tok-new; Path=/'],
          );
        }
        if (url.contains('serviceLogin')) {
          return fakeJsonResponse(
            '{"code":0,'
            '"location":"https://account.xiaomi.com/pass/sts?d=9",'
            '"ssecurity":"sec9","nonce":7}',
          );
        }
        throw StateError('unexpected request: $url');
      });
      final client = _client(transport, store);

      final devices = await client.getDeviceList();
      expect(devices, hasLength(1));
      final calls = transport.requestsTo('device_list');
      expect(calls, hasLength(2));
      expect(calls.last.headers['Cookie'], contains('serviceToken=tok-new'));
      expect(store.cached?.service(kMinaSid)?.serviceToken, 'tok-new');
    });
  });

  group('MinaClient ubus', () {
    test('双层 code：外层 0 但 data.code 非 0 视为失败', () async {
      final store = await _loggedInStore();
      var ubusCalls = 0;
      final transport = FakeMinaTransport((req) {
        if (req.urlText.contains('/remote/ubus')) {
          ubusCalls++;
          if (ubusCalls == 1) {
            return fakeJsonResponse('{"code":0,"data":{"code":-100}}');
          }
          return fakeJsonResponse('{"code":0,"data":{"code":0}}');
        }
        throw StateError('unexpected request: ${req.urlText}');
      });
      final client = _client(transport, store);

      expect(await client.playerPause('did-1'), isFalse);
      expect(await client.playerPause('did-1'), isTrue);

      // form 编码字段与 requestId 格式。
      final form = transport.requests.first.form;
      expect(form['deviceId'], 'did-1');
      expect(form['method'], 'player_play_operation');
      expect(form['path'], 'mediaplayer');
      expect(jsonDecode(form['message']!), {
        'action': 'pause',
        'media': 'app_ios',
      });
      expect(form['requestId'], startsWith('app_ios_'));
      expect(form['requestId'], hasLength(38));
    });

    test('播放状态解析 data.info（status/position/duration 毫秒）', () async {
      final store = await _loggedInStore();
      // 结构以协议文档为准：status/volume 在 info 顶层，
      // position/duration 在 play_song_detail 内。
      final info = jsonEncode({
        'status': 1,
        'volume': 37,
        'play_song_detail': {'position': 61000, 'duration': 240000},
      });
      final transport = FakeMinaTransport((req) {
        if (req.urlText.contains('/remote/ubus')) {
          return fakeJsonResponse(
            jsonEncode({
              'code': 0,
              'data': {'code': 0, 'info': info},
            }),
          );
        }
        throw StateError('unexpected request: ${req.urlText}');
      });
      final client = _client(transport, store);

      final status = await client.getPlayerStatus('did-1');
      expect(status, isNotNull);
      expect(status!.isPlaying, isTrue);
      expect(status.volume, 37);
      expect(status.positionMs, 61000);
      expect(status.durationMs, 240000);
      expect(await client.getVolume('did-1'), 37);
    });

    test('playMusic：music JSON 带 REPLACE_ALL 与占位 audio_id', () async {
      final store = await _loggedInStore();
      final transport = FakeMinaTransport((req) {
        if (req.urlText.contains('/remote/ubus')) {
          return fakeJsonResponse('{"code":0,"data":{"code":0}}');
        }
        throw StateError('unexpected request: ${req.urlText}');
      });
      final client = _client(transport, store);

      expect(
        await client.playMusic('did-1', 'http://192.168.1.2/a.mp3'),
        isTrue,
      );
      final form = transport.requests.single.form;
      expect(form['method'], 'player_play_music');
      final message = jsonDecode(form['message']!) as Map<String, Object?>;
      expect(message['startaudioid'], kDefaultMusicAudioId);
      final music =
          jsonDecode(message['music']! as String) as Map<String, Object?>;
      expect(music['play_behavior'], 'REPLACE_ALL');
      final payload = music['payload']! as Map<String, Object?>;
      final items = payload['audio_items']! as List<Object?>;
      final item = items.single as Map<String, Object?>;
      final itemId = item['item_id']! as Map<String, Object?>;
      expect(itemId['audio_id'], kDefaultMusicAudioId);
      expect((itemId['cp']! as Map<String, Object?>)['id'], kMusicCpId);
      expect(
        (item['stream']! as Map<String, Object?>)['url'],
        'http://192.168.1.2/a.mp3',
      );
    });

    test('TTS 101/3012 视为可能已播出：返回 null 且绝不重发', () async {
      final store = await _loggedInStore();
      final transport = FakeMinaTransport((req) {
        if (req.urlText.contains('/remote/ubus')) {
          return fakeJsonResponse(
            '{"code":101,"data":{"device_data":{"code":3012}}}',
          );
        }
        throw StateError('unexpected request: ${req.urlText}');
      });
      final client = _client(transport, store);

      expect(await client.textToSpeech('did-1', '你好'), isNull);
      expect(transport.requestsTo('/remote/ubus'), hasLength(1));
    });

    test('TTS 101/3012（device_data 为 JSON 字符串形态）同样不重发', () async {
      final store = await _loggedInStore();
      final transport = FakeMinaTransport((req) {
        if (req.urlText.contains('/remote/ubus')) {
          return fakeJsonResponse(
            '{"code":101,"data":{"device_data":"{\\"code\\":3012}"}}',
          );
        }
        throw StateError('unexpected request: ${req.urlText}');
      });
      final client = _client(transport, store);

      expect(await client.textToSpeech('did-1', '你好'), isNull);
      expect(transport.requestsTo('/remote/ubus'), hasLength(1));
    });
  });

  group('MinaClient 对话记录', () {
    test('成功解析 records 与 TTS 回答', () async {
      final store = await _loggedInStore();
      final data = jsonEncode({
        'records': [
          {
            'time': 1764000000000,
            'query': '播放周杰伦晴天',
            'answers': [
              {
                'type': 'TTS',
                'tts': {'text': '好的'},
              },
            ],
          },
        ],
      });
      final transport = FakeMinaTransport((req) {
        if (req.urlText.contains('userprofile.mina.mi.com')) {
          return fakeJsonResponse(jsonEncode({'code': 0, 'data': data}));
        }
        throw StateError('unexpected request: ${req.urlText}');
      });
      final client = _client(transport, store);

      final result = await client.fetchLatestAsk(
        deviceId: 'did-1',
        hardware: 'LX06',
        timestampMs: 1764000001000,
      );
      expect(result, isA<ConversationFetchSuccess>());
      final records = (result as ConversationFetchSuccess).records;
      expect(records, hasLength(1));
      expect(records.single.query, '播放周杰伦晴天');
      expect(records.single.timeMs, 1764000000000);
      expect(records.single.ttsAnswerText, '好的');

      final req = transport.requests.single;
      expect(req.urlText, contains('hardware=LX06'));
      expect(req.urlText, contains('timestamp=1764000001000'));
      expect(req.headers['Cookie'], contains('deviceId=did-1'));
    });

    test('成功但无记录：data 为空串 → Success 空列表（区别于失败）', () async {
      final store = await _loggedInStore();
      final transport = FakeMinaTransport((req) {
        if (req.urlText.contains('userprofile.mina.mi.com')) {
          return fakeJsonResponse('{"code":0,"data":""}');
        }
        throw StateError('unexpected request: ${req.urlText}');
      });
      final client = _client(transport, store);

      final result = await client.fetchLatestAsk(
        deviceId: 'did-1',
        hardware: 'LX06',
      );
      expect(result, isA<ConversationFetchSuccess>());
      expect((result as ConversationFetchSuccess).records, isEmpty);
      expect(transport.requests, hasLength(1));
    });

    test('拉取失败：HTTP 500 重试 3 次后返回 Failure', () async {
      final store = await _loggedInStore();
      final transport = FakeMinaTransport((req) {
        if (req.urlText.contains('userprofile.mina.mi.com')) {
          return fakeJsonResponse('server error', status: 500);
        }
        throw StateError('unexpected request: ${req.urlText}');
      });
      final client = _client(transport, store);

      final result = await client.fetchLatestAsk(
        deviceId: 'did-1',
        hardware: 'LX06',
      );
      expect(result, isA<ConversationFetchFailure>());
      expect(
        transport.requestsTo('userprofile.mina.mi.com'),
        hasLength(kConversationMaxRetries),
      );
    });
  });
}
