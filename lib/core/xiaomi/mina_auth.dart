import 'dart:convert';
import 'dart:typed_data';

import 'mina_constants.dart';
import 'mina_http.dart';
import 'mina_models.dart';
import 'xiaomi_token_store.dart';

/// 小米账密登录状态机（蓝本：miot `src/mina/auth.ts` 的 MinaAuth，
/// 短信触发步骤交叉 miservice `miaccount.py` 的 `_verify_otp`）。
///
/// 三步：serviceLogin 取 _sign/qs/callback → serviceLoginAuth2 提交
/// 密码 → 跟随 location 重定向换 serviceToken。图形验证码与短信
/// 验证以 [MinaLoginNeedCaptcha] / [MinaLoginNeedVerify] 类型化返回，
/// 调用方提交答案后用 [submitCaptcha] / [submitVerifyCode] 续跑
/// 同一次登录。本类不弹任何 UI，也不持久化密码（密码哈希只在
/// 内存中保留到本次登录结束）。
class MinaAuth {
  MinaAuth({
    required MinaHttpTransport http,
    required XiaomiTokenStore tokenStore,
    DateTime Function()? now,
  }) : _http = http,
       _tokenStore = tokenStore,
       _now = now ?? DateTime.now;

  final MinaHttpTransport _http;
  final XiaomiTokenStore _tokenStore;
  final DateTime Function() _now;

  final MinaCookieJar _jar = MinaCookieJar();

  String? _deviceId;
  String? _userAgent;

  // 本次登录的待续状态。
  Map<String, Object?>? _step1Data;
  String _username = '';
  String _passwordHash = '';
  String _captchaIck = '';
  String _verifyUrl = '';
  XiaomiVerifyKind _verifyKind = XiaomiVerifyKind.phone;

  // 70022 限流退避（miservice 的自锁策略）。
  int _rateLimitHits = 0;
  int _rateLimitCooldownUntilMs = 0;

  String? _lastSendCodeError;
  Uri? _lastFetchFinalUrl;

  XiaomiTokenInfo? get currentTokens => _tokenStore.cached;

  /// 最近一次 [sendVerificationCode] 失败的原因（含服务器 code / 描述），
  /// 成功或未调用时为 null，供 UI 展示。
  String? get lastSendCodeError => _lastSendCodeError;

  int get _nowMs => _now().millisecondsSinceEpoch;

  Future<String> _ua() async {
    if (_userAgent != null) return _userAgent!;
    _deviceId = await _tokenStore.deviceId();
    _userAgent = formatXiaomiUserAgent(_deviceId!);
    return _userAgent!;
  }

  // ===== 登录 =====

  /// 发起账密登录（sid 固定 micoapi）。
  Future<MinaLoginResult> login(String username, String password) async {
    if (_rateLimitBlocked()) {
      return const MinaLoginFailure('登录过于频繁，请稍后再试', code: 70022);
    }
    _username = username;
    _passwordHash = xiaomiPasswordHash(password);
    _captchaIck = '';
    _verifyUrl = '';

    final step1 = await _loginStep1(kMinaSid);
    if (step1 == null) {
      return const MinaLoginFailure('登录第一步无响应');
    }
    if (_codeOf(step1.data) == kLoginRateLimitCode) {
      _noteRateLimit();
      return const MinaLoginFailure('登录过于频繁，请稍后再试', code: 70022);
    }
    _step1Data = step1.data;
    return _loginStep2('');
  }

  /// 提交图形验证码，续跑同一次登录。
  Future<MinaLoginResult> submitCaptcha(String code) async {
    if (_step1Data == null) {
      return const MinaLoginFailure('没有进行中的登录，请先发起登录');
    }
    return _loginStep2(code);
  }

  /// 触发短信 / 邮箱验证码发送（miservice _verify_otp 的步骤 1–4）。
  ///
  /// miot 的 auth 层没有这一步（其前端另行处理），这里按 miservice
  /// 的完整流程实现：打开 notificationUrl 建会话 → /identity/list
  /// 定方式 → GET verify{Phone,Email} 触发 → 手机再 POST
  /// sendPhoneTicket 真正发短信。每步都带 deviceId cookie（miservice
  /// 全程显式携带）并跟随重定向（其传输层默认行为）；响应按
  /// parse_resp 语义解析，严格校验：非空响应解析失败或 code 显式
  /// 非 0 都如实返回失败，原因记入 [lastSendCodeError]，绝不把服务
  /// 器拒绝吞成成功。
  ///
  /// 全程 UA 用 [kXiaomiOtpUserAgent]（miservice `_verify_otp` 的
  /// UA_OTP）：这是 H5 验证流程，用 App UA 时依赖会话的触发步会
  /// 被服务器返回 HTML 验证页而非 JSON（真机实测）。
  Future<bool> sendVerificationCode() async {
    _lastSendCodeError = null;
    if (_verifyUrl.isEmpty) {
      return _sendCodeFailed('没有进行中的验证会话');
    }
    final ua = kXiaomiOtpUserAgent;
    final deviceCookie = 'deviceId=${_deviceId ?? ''}';

    // 1. 打开 notificationUrl 建立验证会话（跟随重定向，最终须 200，
    //    与 miservice 的硬性要求一致）。
    final startResp = await _fetch(
      'GET',
      Uri.parse(_verifyUrl),
      headers: {'User-Agent': ua},
      extraCookie: deviceCookie,
      maxRedirects: 10,
    );
    if (startResp.statusCode != 200) {
      return _sendCodeFailed('打开验证页失败（HTTP ${startResp.statusCode}）');
    }

    // 2. 查可用验证方式（flag 4=手机、8=邮箱）；解析不到 flag 直接
    //    失败，不猜默认值。
    final verifyUri = Uri.parse(_verifyUrl);
    final context = verifyUri.queryParameters['context'] ?? '';
    final sidParam = verifyUri.queryParameters['sid'] ?? kMinaSid;
    final listUrl =
        '$kXiaomiAccountBaseUrl/identity/list?sid=$sidParam'
        '&supportedMask=0&_locale=zh_CN&context=${Uri.encodeQueryComponent(context)}';
    final listResp = await _fetch(
      'GET',
      Uri.parse(listUrl),
      headers: {'User-Agent': ua},
      extraCookie: deviceCookie,
      maxRedirects: 10,
    );
    final listParse = _parseAccountResponse(listResp);
    final listJson = listParse.json;
    if (listJson == null) {
      return _sendCodeFailed(
        _serverErrorText('查询验证方式', null, listParse.failureDetail),
      );
    }
    final flag = (listJson['flag'] as num?)?.toInt();
    if (flag == null) {
      return _sendCodeFailed('查询验证方式失败：响应缺少 flag 字段');
    }
    _verifyKind = flag == 8 ? XiaomiVerifyKind.email : XiaomiVerifyKind.phone;

    // 3. 触发发送。miservice 的传输层默认跟随重定向，这一步同样
    //    跟随；响应按 parse_resp 语义解析（空体视作无 code）。
    final method = _verifyKind == XiaomiVerifyKind.email ? 'Email' : 'Phone';
    final triggerResp = await _fetch(
      'GET',
      Uri.parse(
        '$kXiaomiAccountBaseUrl/identity/auth/verify$method'
        '?_flag=$flag&_json=true',
      ),
      headers: {'User-Agent': ua},
      extraCookie: deviceCookie,
      maxRedirects: 10,
    );
    final triggerParse = _parseAccountResponse(triggerResp);
    if (!_strictSendCodeOk(triggerParse.json)) {
      return _sendCodeFailed(
        _serverErrorText(
          '触发验证码发送',
          triggerParse.json,
          triggerParse.failureDetail,
        ),
      );
    }

    // 4. 手机需再调 sendPhoneTicket 才真正发出短信。
    if (_verifyKind == XiaomiVerifyKind.phone) {
      final sendResp = await _fetch(
        'POST',
        Uri.parse('$kXiaomiAccountBaseUrl/identity/auth/sendPhoneTicket'),
        headers: {
          'User-Agent': ua,
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        extraCookie: deviceCookie,
        body: _encodeForm({'retry': '0', 'icode': '', '_json': 'true'}),
        maxRedirects: 10,
      );
      final sendParse = _parseAccountResponse(sendResp);
      if (!_strictSendCodeOk(sendParse.json)) {
        return _sendCodeFailed(
          _serverErrorText('短信发送', sendParse.json, sendParse.failureDetail),
        );
      }
    }
    return true;
  }

  /// 提交短信 / 邮箱验证码，完成登录。
  Future<MinaLoginResult> submitVerifyCode(String code) async {
    if (_verifyUrl.isEmpty) {
      return const MinaLoginFailure('没有进行中的验证，请先发起登录');
    }
    final location = await _verifyTicket(code);
    if (location == null) {
      return const MinaLoginFailure('验证码校验失败');
    }

    // 跟随重定向链收集 passToken / userId（仍属 miservice
    // _verify_otp 流程内，UA 继续用 UA_OTP）。
    await _fetch(
      'GET',
      Uri.parse(location),
      headers: {'User-Agent': kXiaomiOtpUserAgent},
      maxRedirects: 10,
    );
    // miservice 7a'：重定向链可能停在「确认手机号」页，最终 URL 上的
    // confirmUrl 续链后才会走到下发 passToken 的终点，先带 cookie
    // GET 它再继续找 passToken。
    final confirmUrl = _lastFetchFinalUrl?.queryParameters['confirmUrl'];
    if (confirmUrl != null && confirmUrl.isNotEmpty) {
      await _fetch(
        'GET',
        Uri.parse(confirmUrl),
        headers: {'User-Agent': kXiaomiOtpUserAgent},
        extraCookie: 'deviceId=${_deviceId ?? ''}',
        maxRedirects: 10,
      );
    }
    final passToken = _jar.value('passToken') ?? '';
    final userId = _jar.value('userId') ?? '';
    if (passToken.isEmpty) {
      return const MinaLoginFailure('验证后未拿到 passToken');
    }

    final ok = await _exchangeServiceToken(passToken, userId, kMinaSid);
    if (!ok) {
      return const MinaLoginFailure('验证后换取 serviceToken 失败');
    }
    final tokens = currentTokens;
    if (tokens == null) {
      return const MinaLoginFailure('登录态保存失败');
    }
    return MinaLoginSuccess(tokens);
  }

  // ===== Token 生命周期 =====

  /// 用落盘的 passToken 续期指定 sid 的 serviceToken（免密）。
  Future<bool> refreshServiceToken([String sid = kMinaSid]) async {
    if (_rateLimitBlocked()) return false;
    final tokens = await _tokenStore.load();
    if (tokens == null || tokens.passToken.isEmpty) return false;
    return _exchangeServiceToken(tokens.passToken, tokens.userId, sid);
  }

  /// serviceToken 剩余有效期不足（含已过期 / 不存在）时才刷新。
  Future<bool> ensureFreshServiceToken([String sid = kMinaSid]) async {
    final tokens = await _tokenStore.load();
    final svc = tokens?.service(sid);
    if (svc != null && !svc.needsRefreshAt(_nowMs)) return true;
    return refreshServiceToken(sid);
  }

  /// 退出登录：清掉全部落盘凭据与待续状态。
  Future<void> logout() async {
    _step1Data = null;
    _username = '';
    _passwordHash = '';
    _captchaIck = '';
    _verifyUrl = '';
    _lastSendCodeError = null;
    _jar.clear();
    await _tokenStore.clear();
  }

  // ===== 三步登录内部实现 =====

  Future<({Map<String, Object?> data, String raw})?> _loginStep1(
    String sid,
  ) async {
    await _ua();
    final url = Uri.parse(
      '$kXiaomiAccountBaseUrl/pass/serviceLogin?sid=$sid&_json=true',
    );
    final resp = await _fetch(
      'GET',
      url,
      headers: {'User-Agent': _userAgent ?? ''},
      extraCookie: 'sdkVersion=3.8.6; deviceId=${_deviceId ?? ''}',
    );
    final raw = stripXiaomiJsonPrefix(resp.bodyText);
    final json = _parseJson(raw);
    if (json == null) return null;
    return (data: json, raw: raw);
  }

  Future<MinaLoginResult> _loginStep2(String captcha) async {
    final auth = _step1Data!;
    final url = Uri.parse(
      '$kXiaomiAccountBaseUrl/pass/serviceLoginAuth2?_json=true',
    );
    final form = <String, String>{
      'user': _username,
      'hash': _passwordHash,
      'callback': _stringValue(auth, 'callback'),
      'sid': _stringValue(auth, 'sid', kMinaSid),
      'qs': _stringValue(auth, 'qs'),
      '_sign': _stringValue(auth, '_sign'),
      if (captcha.isNotEmpty) 'captCode': captcha,
    };
    final resp = await _fetch(
      'POST',
      url,
      headers: {
        'User-Agent': await _ua(),
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      // miservice 的 _serviceLogin 两步都显式带 sdkVersion + deviceId
      // cookie；此前第二步只在验证码场景带 ick、常态下漏了 deviceId，
      // 与蓝本对齐（ick 仍只在验证码场景追加）。
      extraCookie: [
        'sdkVersion=3.8.6; deviceId=${_deviceId ?? ''}',
        if (captcha.isNotEmpty && _captchaIck.isNotEmpty) 'ick=$_captchaIck',
      ].join('; '),
      body: _encodeForm(form),
    );
    final raw = stripXiaomiJsonPrefix(resp.bodyText);
    final result = _parseJson(raw);
    if (result == null) {
      return MinaLoginFailure('登录第二步响应解析失败: ${_truncate(raw)}');
    }

    final code = _codeOf(result);
    if (code == kLoginRateLimitCode) {
      _noteRateLimit();
      return const MinaLoginFailure('登录过于频繁，请稍后再试', code: 70022);
    }

    // 二次验证优先于图形验证码（miot 的判定顺序）。
    final notificationUrl = _stringValue(result, 'notificationUrl');
    if (notificationUrl.isNotEmpty) {
      _verifyUrl = notificationUrl.startsWith('http')
          ? notificationUrl
          : '$kXiaomiAccountBaseUrl$notificationUrl';
      _verifyKind = _verifyUrl.contains('email')
          ? XiaomiVerifyKind.email
          : XiaomiVerifyKind.phone;
      return MinaLoginNeedVerify(_verifyKind);
    }

    // 图形验证码（兼容小米不同版本的字段名）。
    var captchaUrl = '';
    for (final field in [
      'captchaUrl',
      'captchaURL',
      'captcha_url',
      'captcha',
      'imgUrl',
    ]) {
      final v = _stringValue(result, field);
      if (v.isNotEmpty) {
        captchaUrl = v;
        break;
      }
    }
    if (captchaUrl.isNotEmpty) {
      final fullUrl = captchaUrl.startsWith('http')
          ? captchaUrl
          : '$kXiaomiAccountBaseUrl$captchaUrl';
      try {
        final fetched = await _fetchCaptchaImage(fullUrl);
        return MinaLoginNeedCaptcha(imageBytes: fetched);
      } catch (e) {
        // 取图失败降级为「需要验证码但无图」，不让整个登录抛异常（miot 同策略）。
        return MinaLoginNeedCaptcha(error: '获取验证码图片失败: $e');
      }
    }

    final location = _stringValue(result, 'location');
    if (location.isEmpty) {
      final desc =
          _stringValue(result, 'description') + _stringValue(result, 'desc');
      return MinaLoginFailure(
        '登录失败${desc.isEmpty ? '' : ': $desc'}',
        code: code,
      );
    }

    final ssecurity = _stringValue(result, 'ssecurity');
    // nonce 必须从原始文本提取，防大整数精度丢失。
    final nonce =
        extractBigIntField(raw, 'nonce') ?? _stringValue(result, 'nonce');
    final step2PassToken = _stringValue(result, 'passToken');
    final step2UserId = _stringValue(result, 'userId');

    final ok = await _step3Follow(location, nonce, ssecurity, kMinaSid);
    if (!ok) {
      return const MinaLoginFailure('登录第三步换取 serviceToken 失败');
    }
    await _harvestTokens(
      userIdHint: step2UserId,
      passTokenHint: step2PassToken,
    );
    _rateLimitHits = 0;
    final tokens = currentTokens;
    if (tokens == null) return const MinaLoginFailure('登录态保存失败');
    return MinaLoginSuccess(tokens);
  }

  /// Step 3 / STS：给 location 追加 clientSign 后跟随重定向，
  /// 从最终响应的 Set-Cookie 取 serviceToken 并写入 token 存储。
  Future<bool> _step3Follow(
    String location,
    String nonce,
    String ssecurity,
    String sid,
  ) async {
    final clientSign = computeXiaomiClientSign(nonce, ssecurity);
    final sep = location.contains('?') ? '&' : '?';
    final signedLocation =
        '$location${sep}_userIdNeedEncrypt=true'
        '&clientSign=${Uri.encodeComponent(clientSign)}';
    final resp = await _fetch(
      'GET',
      Uri.parse(signedLocation),
      headers: {'User-Agent': await _ua()},
      maxRedirects: 10,
    );
    final serviceToken =
        setCookieValue(resp.setCookies, 'serviceToken') ??
        _jar.value('serviceToken') ??
        '';
    if (serviceToken.isEmpty) return false;

    final existing = await _tokenStore.load();
    final services = Map<String, XiaomiServiceToken>.of(
      existing?.services ?? const {},
    );
    services[sid] = XiaomiServiceToken(
      serviceToken: serviceToken,
      ssecurity: ssecurity,
      expiresAtMs: _nowMs + kServiceTokenValidHours * 3600 * 1000,
    );
    await _tokenStore.save(
      XiaomiTokenInfo(
        userId: existing?.userId ?? '',
        deviceId: _deviceId ?? existing?.deviceId ?? '',
        passToken: existing?.passToken ?? '',
        services: services,
        createdAtMs: existing?.createdAtMs ?? _nowMs,
      ),
    );
    return true;
  }

  /// 登录/续期成功后，把 jar 与响应里散落的 userId / passToken 收拢落盘。
  Future<void> _harvestTokens({
    String userIdHint = '',
    String passTokenHint = '',
  }) async {
    final existing = await _tokenStore.load();
    if (existing == null) return;
    final userId = _jar.value('userId') ?? '';
    final passToken = _jar.value('passToken') ?? '';
    await _tokenStore.save(
      existing.copyWith(
        userId: userId.isNotEmpty
            ? userId
            : (userIdHint.isNotEmpty ? userIdHint : existing.userId),
        passToken: passToken.isNotEmpty
            ? passToken
            : (passTokenHint.isNotEmpty ? passTokenHint : existing.passToken),
      ),
    );
  }

  /// passToken → serviceToken（serviceLogin + Step 3）。
  Future<bool> _exchangeServiceToken(
    String passToken,
    String userId,
    String sid,
  ) async {
    await _ua();
    final url = Uri.parse(
      '$kXiaomiAccountBaseUrl/pass/serviceLogin?sid=$sid&_json=true',
    );
    final cookieParts = <String>[
      'passToken=$passToken',
      'userId=$userId',
      'deviceId=${_deviceId ?? ''}',
      'sdkVersion=3.8.6',
    ];
    final cUserId = _jar.value('cUserId');
    if (cUserId != null && cUserId.isNotEmpty) {
      cookieParts.add('cUserId=$cUserId');
    }
    final resp = await _fetch(
      'GET',
      url,
      headers: {'User-Agent': await _ua()},
      extraCookie: cookieParts.join('; '),
    );
    final raw = stripXiaomiJsonPrefix(resp.bodyText);
    final json = _parseJson(raw);
    if (json == null) return false;

    final code = _codeOf(json);
    if (code == kLoginRateLimitCode) {
      _noteRateLimit();
      return false;
    }
    if (code != null && code != 0) return false;

    final location = _stringValue(json, 'location');
    final ssecurity = _stringValue(json, 'ssecurity');
    if (location.isEmpty) return false;

    final nonce =
        extractBigIntField(raw, 'nonce') ?? _stringValue(json, 'nonce');
    final ok = await _step3Follow(location, nonce, ssecurity, sid);
    if (!ok) return false;
    await _harvestTokens(
      userIdHint: _stringValue(json, 'userId').isNotEmpty
          ? _stringValue(json, 'userId')
          : userId,
      passTokenHint: passToken,
    );
    _rateLimitHits = 0;
    return true;
  }

  // ===== 二次验证 =====

  Future<String?> _verifyTicket(String ticket) async {
    if (_verifyUrl.contains('/fe/service/identity/authStart')) {
      await _checkIdentityList();
    }
    final isEmail = _verifyKind == XiaomiVerifyKind.email;
    final api = isEmail ? 'verifyEmail' : 'verifyPhone';
    final flag = isEmail ? '8' : '4';
    final url = Uri.parse(
      '$kXiaomiAccountBaseUrl/identity/auth/$api?_dc=$_nowMs',
    );
    final resp = await _fetch(
      'POST',
      url,
      headers: {
        'User-Agent': kXiaomiOtpUserAgent,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      extraCookie: 'deviceId=${_deviceId ?? ''}',
      body: _encodeForm({
        'ticket': ticket,
        // trust 取值蓝本分歧未定版：miot 用 'true'、miservice 用
        // 'false'，当前沿用 miot 的 'true'，待真机抓包定版后再改。
        'trust': 'true',
        '_json': 'true',
        '_flag': flag,
      }),
    );
    final json = _parseJson(stripXiaomiJsonPrefix(resp.bodyText));
    if (json == null) return null;
    // miservice 的成功判定：响应带 location 即视为校验通过（其流程
    // 根本不看 code），没有 location 才算失败。
    final location = _stringValue(json, 'location');
    return location.isEmpty ? null : location;
  }

  Future<void> _checkIdentityList() async {
    final listUrl = _verifyUrl.replaceFirst(
      '/fe/service/identity/authStart',
      '/identity/list',
    );
    try {
      await _fetch(
        'GET',
        Uri.parse(listUrl),
        headers: {'User-Agent': kXiaomiOtpUserAgent},
        extraCookie: 'deviceId=${_deviceId ?? ''}',
      );
    } catch (_) {
      // 非致命：拿不到 identity_session 也继续提交（miot 同策略）。
    }
  }

  // ===== HTTP 辅助 =====

  /// 带 Cookie 罐的请求：自动合并罐内 Cookie、吸收响应 Set-Cookie，
  /// 按需跟随重定向（跟随时转 GET 并丢弃 body）。
  Future<MinaHttpResponse> _fetch(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    String? extraCookie,
    String? body,
    int maxRedirects = 0,
  }) async {
    var currentMethod = method;
    var currentUrl = url;
    var currentHeaders = headers;
    var currentBody = body;
    var currentExtra = extraCookie;
    var hops = 0;
    while (true) {
      final effective = Map<String, String>.of(currentHeaders);
      final cookieParts = <String>[
        if (currentExtra != null && currentExtra.isNotEmpty) currentExtra,
        _jar.cookieHeaderFor(currentUrl),
      ].where((s) => s.isNotEmpty).toList();
      if (cookieParts.isNotEmpty) {
        effective['Cookie'] = cookieParts.join('; ');
      }
      final resp = await _http.send(
        currentMethod,
        currentUrl,
        headers: effective,
        body: currentBody,
        timeout: kMinaHttpTimeout,
      );
      _jar.absorb(resp.setCookies, currentUrl);

      final location = resp.header('location');
      final isRedirect =
          resp.statusCode >= 300 && resp.statusCode < 400 && location != null;
      if (!isRedirect || hops >= maxRedirects) {
        _lastFetchFinalUrl = currentUrl;
        return resp;
      }
      hops++;
      currentUrl = currentUrl.resolve(location);
      currentMethod = 'GET';
      currentBody = null;
      currentExtra = null;
      currentHeaders = {'User-Agent': currentHeaders['User-Agent'] ?? ''};
    }
  }

  Future<Uint8List> _fetchCaptchaImage(String captchaUrl) async {
    final resp = await _fetch(
      'GET',
      Uri.parse(captchaUrl),
      headers: {'User-Agent': await _ua()},
      maxRedirects: 5,
    );
    _captchaIck = _jar.value('ick') ?? '';
    if (resp.bodyBytes.isEmpty) {
      throw StateError('验证码图片为空 (HTTP ${resp.statusCode})');
    }
    return Uint8List.fromList(resp.bodyBytes);
  }

  // ===== 小工具 =====

  bool _rateLimitBlocked() =>
      _rateLimitHits >= kLoginRateLimitMaxHits &&
      _nowMs < _rateLimitCooldownUntilMs;

  void _noteRateLimit() {
    _rateLimitHits++;
    if (_rateLimitHits >= kLoginRateLimitMaxHits) {
      _rateLimitCooldownUntilMs =
          _nowMs + kLoginRateLimitCooldown.inMilliseconds;
    }
  }

  static int? _codeOf(Map<String, Object?> json) =>
      (json['code'] as num?)?.toInt();

  /// 发码链严格校验：非空响应解析失败（null）直接算失败；code 显式
  /// 非 0 也失败。code 缺失时与 miservice 一致容忍（其触发/发码步
  /// 判定为 `code not in (0, None)` 才报错；空体经 parse_resp 归一
  /// 为无 code，同样容忍）——但非空垃圾响应绝不放行，这是与旧
  /// _codeOkOrAbsent 的关键区别。
  static bool _strictSendCodeOk(Map<String, Object?>? json) {
    if (json == null) return false;
    final code = _codeOf(json);
    return code == null || code == 0;
  }

  /// 把服务器返回的 code / 描述拼成可读的失败原因；解析失败时附
  /// [_parseAccountResponse] 给出的响应形态描述，便于真机定位。
  static String _serverErrorText(
    String step,
    Map<String, Object?>? json, [
    String? parseDetail,
  ]) {
    if (json == null) {
      return '$step失败：服务器响应解析失败'
          '${parseDetail != null ? '（$parseDetail）' : ''}';
    }
    final code = _codeOf(json);
    var desc = '';
    for (final key in ['desc', 'description', 'message']) {
      final v = json[key];
      if (v is String && v.isNotEmpty) {
        desc = v;
        break;
      }
    }
    return '$step失败${code != null ? '（code=$code）' : ''}'
        '${desc.isNotEmpty ? '：$desc' : ''}';
  }

  bool _sendCodeFailed(String message) {
    _lastSendCodeError = message;
    return false;
  }

  /// 按 miservice `parse_resp` 语义解析 account 响应：剥前缀后为
  /// 空体时视作 `{}`（无 code 字段，触发 / 发码步据此容忍通过，与
  /// 蓝本 `loads(raw) if raw else {}` 一致）；非空但解码失败、或
  /// 解出的是非对象 JSON 时判解析失败，并附响应形态描述。
  static _AccountParse _parseAccountResponse(MinaHttpResponse resp) {
    final stripped = stripXiaomiJsonPrefix(resp.bodyText);
    if (stripped.isEmpty) {
      return const _AccountParse({}, null);
    }
    Object? decoded;
    try {
      decoded = jsonDecode(stripped);
    } catch (_) {
      return _AccountParse(null, _describeResponseShape(resp));
    }
    if (decoded is Map) {
      return _AccountParse(decoded.cast<String, Object?>(), null);
    }
    return _AccountParse(
      null,
      _describeResponseShape(resp, jsonNotObject: true),
    );
  }

  /// 把不可解析的响应概括成可辨识形态：HTTP 状态、字节数、内容
  /// 类别与起始片段。不带响应原文整段（可能含敏感值）：起始片段
  /// 最多 24 个字符，连续数字串一律打码。
  static String _describeResponseShape(
    MinaHttpResponse resp, {
    bool jsonNotObject = false,
  }) {
    final raw = resp.bodyText;
    final trimmed = raw.trim();
    final String kind;
    if (jsonNotObject) {
      kind = 'JSON 结构异常（非对象）';
    } else if (trimmed.isEmpty) {
      kind = '空响应';
    } else if (trimmed.startsWith('<')) {
      kind = 'HTML 页面';
    } else if (raw.startsWith('&&&START&&&')) {
      kind = '带 &&&START&&& 前缀但内容非 JSON';
    } else {
      kind = '非 JSON 文本';
    }
    var head = trimmed.length <= 24 ? trimmed : trimmed.substring(0, 24);
    head = head
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'\d+'), '***');
    // HTML 时附带页面 <title>：标题只是页面名（如验证页 / 风控页的
    // 自称），无敏感值，却能一眼定性这是什么页。限长 40、去内嵌标签。
    var titlePart = '';
    var bodyPart = '';
    if (kind == 'HTML 页面') {
      final title = _extractHtmlTitle(raw);
      if (title != null) titlePart = '，页面标题「$title」';
      // 再附正文可见文本：「温馨提示」类页面的正文就是服务器给出的
      // 具体原因（如验证已过期 / 操作频繁），标题定不了性时靠它。
      // 只取去标签后的可见文本并限长 80，不带整段原文。
      final bodyText = _extractHtmlBodyText(raw);
      if (bodyText != null) bodyPart = '，正文「$bodyText」';
    }
    return 'HTTP ${resp.statusCode}，${resp.bodyBytes.length} 字节，'
        '$kind，起始「$head」$titlePart$bodyPart';
  }

  /// 提取 HTML 的正文可见文本：去掉 script/style/title 元素与全部
  /// 标签，解常见实体，折叠空白，限长 80 字；无可见文本返回 null。
  static String? _extractHtmlBodyText(String html) {
    var text = html
        .replaceAll(
          RegExp(r'<(script|style|title)[^>]*>[\s\S]*?</\1>', caseSensitive: false),
          ' ',
        )
        .replaceAll(RegExp(r'<[^>]*>'), ' ')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&amp;', '&')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (text.isEmpty) return null;
    if (text.length > 80) text = text.substring(0, 80);
    return text;
  }

  /// 提取 HTML 的 `<title>` 文本：去内嵌标签、折叠空白、限长 40 字；
  /// 无 title 或为空时返回 null。
  static String? _extractHtmlTitle(String html) {
    final match = RegExp(
      r'<title[^>]*>([\s\S]*?)</title>',
      caseSensitive: false,
    ).firstMatch(html);
    if (match == null) return null;
    var title = match
        .group(1)!
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (title.isEmpty) return null;
    if (title.length > 40) title = title.substring(0, 40);
    return title;
  }

  static Map<String, Object?>? _parseJson(String text) {
    if (text.isEmpty) return null;
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map) return decoded.cast<String, Object?>();
    } catch (_) {
      return null;
    }
    return null;
  }

  static String _stringValue(
    Map<String, Object?> map,
    String key, [
    String fallback = '',
  ]) {
    final v = map[key];
    if (v == null) return fallback;
    if (v is String) return v;
    if (v is num) {
      return v == v.truncateToDouble() ? v.toInt().toString() : v.toString();
    }
    return v.toString();
  }

  static String _encodeForm(Map<String, String> params) {
    return params.entries
        .map(
          (e) =>
              '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}',
        )
        .join('&');
  }

  static String _truncate(String s) =>
      s.length <= 200 ? s : '${s.substring(0, 200)}…';
}

/// [_parseAccountResponse] 的结果：[json] 为 null 表示解析失败，
/// [failureDetail] 是可辨识的响应形态描述（不含响应原文）。
class _AccountParse {
  const _AccountParse(this.json, this.failureDetail);

  final Map<String, Object?>? json;
  final String? failureDetail;
}
