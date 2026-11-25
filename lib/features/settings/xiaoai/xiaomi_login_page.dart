import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:prism_ui/prism_ui.dart' as prism;
import 'package:prism_ui/icons/icons.dart';

import '../../../core/ui/app_toast.dart';
import '../../../core/xiaomi/mina_models.dart';
import '../../../core/xiaomi/xiaomi_providers.dart';
import '../../../theme/app_theme.dart';
import '../../shell/shell_bottom_area.dart';
import '../../shell/widgets/scrolling_page_header.dart';
import '../widgets/settings_action.dart';
import 'xiaoai_settings_controller.dart';

/// 小米账号登录页：账密 →（服务端要求时）图形验证码 →（要求时）短信 /
/// 邮箱验证码，分步状态全部由模块一 [MinaAuth] 的类型化结果驱动。
class XiaomiLoginPage extends ConsumerStatefulWidget {
  const XiaomiLoginPage({super.key});

  @override
  ConsumerState<XiaomiLoginPage> createState() => _XiaomiLoginPageState();
}

class _XiaomiLoginPageState extends ConsumerState<XiaomiLoginPage> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _captchaController = TextEditingController();
  final _verifyCodeController = TextEditingController();

  bool _busy = false;
  bool _passwordVisible = false;
  String? _error;

  /// 非 null 表示服务端要求图形验证码（同一次登录的续跑态）。
  MinaLoginNeedCaptcha? _captcha;

  /// 非 null 表示已进入二次验证步。
  XiaomiVerifyKind? _verifyKind;
  int _resendSeconds = 0;
  Timer? _resendTimer;

  @override
  void dispose() {
    _resendTimer?.cancel();
    _usernameController.dispose();
    _passwordController.dispose();
    _captchaController.dispose();
    _verifyCodeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.appSettingsSurface,
      body: CustomScrollView(
        key: const PageStorageKey('xiaomi-login-scroll'),
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        slivers: [
          const SliverToBoxAdapter(child: ScrollHeaderSpacer()),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              16,
              0,
              16,
              ShellBottomArea.contentPadding(context, 118),
            ),
            sliver: SliverToBoxAdapter(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_verifyKind == null) _formCard(context) else _verifyCard(context),
                      if (_verifyKind == null) ...[
                        const SizedBox(height: 12),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Text(
                            '登录可能需要短信验证，届时会在下一步提示。'
                            '密码仅发送给小米登录接口，保存在本机安全存储中。',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                  height: 1.5,
                                ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _formCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SettingsCard(
      separate: false,
      title: null,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: prism.FilledInputTheme(
            borderRadius: prism.AppRadius.md,
            fillColor: prism.SurfaceLevel.block.colorOf(
              prism.Theme.of(context).colorScheme,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _LabeledField(
                  label: '小米账号',
                  child: prism.TextField(
                    key: const ValueKey('xiaomi-username-field'),
                    controller: _usernameController,
                    enabled: !_busy,
                    textInputAction: TextInputAction.next,
                    autofillHints: const [AutofillHints.username],
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const prism.InputDecoration(
                      hintText: '手机号 / 邮箱 / 小米 ID',
                      hintMaxLines: 1,
                      prefixIcon: Icon(Icons.person_outline_rounded, size: 20),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                _LabeledField(
                  label: '密码',
                  child: prism.TextField(
                    key: const ValueKey('xiaomi-password-field'),
                    controller: _passwordController,
                    enabled: !_busy,
                    obscureText: !_passwordVisible,
                    keyboardType: TextInputType.visiblePassword,
                    textInputAction: _captcha == null
                        ? TextInputAction.done
                        : TextInputAction.next,
                    autofillHints: const [AutofillHints.password],
                    autocorrect: false,
                    enableSuggestions: false,
                    enableIMEPersonalizedLearning: false,
                    onSubmitted: _captcha == null
                        ? (_) => unawaited(_submitForm())
                        : null,
                    decoration: prism.InputDecoration(
                      hintText: '输入密码',
                      prefixIcon: const GlyphIcon(AppGlyphs.lock, size: 20),
                      suffixIcon: prism.IconButton(
                        tooltip: _passwordVisible ? '隐藏密码' : '显示密码',
                        onPressed: _busy
                            ? null
                            : () => setState(
                                () => _passwordVisible = !_passwordVisible,
                              ),
                        icon: GlyphIcon(
                          _passwordVisible ? Glyphs.eyeOff : Glyphs.eye,
                          size: 20,
                        ),
                      ),
                    ),
                  ),
                ),
                if (_captcha != null) ...[
                  const SizedBox(height: 16),
                  _LabeledField(
                    label: '图形验证码',
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: prism.TextField(
                            key: const ValueKey('xiaomi-captcha-field'),
                            controller: _captchaController,
                            enabled: !_busy,
                            textInputAction: TextInputAction.done,
                            autocorrect: false,
                            enableSuggestions: false,
                            onSubmitted: (_) => unawaited(_submitForm()),
                            decoration: const prism.InputDecoration(
                              hintText: '输入验证码',
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        _captchaImage(context),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Text(
              _error!,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.error),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: FilledButton(
            key: const ValueKey('xiaomi-login-submit'),
            onPressed: _busy ? null : () => unawaited(_submitForm()),
            child: Text(_busy ? '登录中…' : '登录'),
          ),
        ),
      ],
    );
  }

  Widget _captchaImage(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bytes = _captcha?.imageBytes;
    return InkWell(
      onTap: _busy ? null : () => unawaited(_refreshCaptcha()),
      child: Container(
        width: 96,
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: bytes == null
            ? Text(
                '点击刷新',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              )
            : ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.memory(bytes, width: 96, height: 48, fit: BoxFit.fill),
              ),
      ),
    );
  }

  Widget _verifyCard(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isPhone = _verifyKind == XiaomiVerifyKind.phone;
    return SettingsCard(
      separate: false,
      title: null,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                isPhone ? '短信验证' : '邮箱验证',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '请输入收到的验证码，完成登录。',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              prism.FilledInputTheme(
                borderRadius: prism.AppRadius.md,
                fillColor: prism.SurfaceLevel.block.colorOf(
                  prism.Theme.of(context).colorScheme,
                ),
                child: _LabeledField(
                  label: '验证码',
                  child: prism.TextField(
                    key: const ValueKey('xiaomi-verify-code-field'),
                    controller: _verifyCodeController,
                    enabled: !_busy,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.done,
                    autocorrect: false,
                    enableSuggestions: false,
                    onSubmitted: (_) => unawaited(_submitVerify()),
                    decoration: const prism.InputDecoration(hintText: '输入验证码'),
                  ),
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: _busy || _resendSeconds > 0
                      ? null
                      : () => unawaited(_sendCode()),
                  child: Text(
                    _resendSeconds > 0 ? '重新发送（$_resendSeconds 秒）' : '重新发送',
                  ),
                ),
              ),
            ],
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Text(
              _error!,
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FilledButton(
                key: const ValueKey('xiaomi-verify-submit'),
                onPressed: _busy ? null : () => unawaited(_submitVerify()),
                child: Text(_busy ? '验证中…' : '验证并登录'),
              ),
              const SizedBox(height: 4),
              TextButton(
                onPressed: _busy
                    ? null
                    : () => setState(() {
                        _verifyKind = null;
                        _error = null;
                      }),
                child: const Text('返回修改账号'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _submitForm() async {
    final auth = ref.read(minaAuthProvider);
    setState(() {
      _busy = true;
      _error = null;
    });
    final MinaLoginResult result;
    if (_captcha != null) {
      result = await auth.submitCaptcha(_captchaController.text.trim());
    } else {
      final username = _usernameController.text.trim();
      final password = _passwordController.text;
      if (username.isEmpty || password.isEmpty) {
        setState(() {
          _busy = false;
          _error = '请输入小米账号和密码';
        });
        return;
      }
      result = await auth.login(username, password);
    }
    if (!mounted) return;
    await _handleResult(result);
  }

  /// 模块一没有单独的验证码刷新接口：重新走一次 login 拿新图
  /// （服务端会重新下发验证码，旧的一次登录随之作废）。
  Future<void> _refreshCaptcha() async {
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    if (username.isEmpty || password.isEmpty) {
      setState(() => _error = '请先填写账号和密码，再刷新验证码');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await ref.read(minaAuthProvider).login(username, password);
    if (!mounted) return;
    await _handleResult(result);
  }

  Future<void> _sendCode() async {
    final ok = await ref.read(minaAuthProvider).sendVerificationCode();
    if (!mounted) return;
    if (!ok) {
      setState(() => _error = '验证码发送失败，请稍后重试');
      return;
    }
    _startResendCountdown();
  }

  void _startResendCountdown() {
    _resendTimer?.cancel();
    setState(() => _resendSeconds = 60);
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        _resendSeconds -= 1;
        if (_resendSeconds <= 0) {
          _resendSeconds = 0;
          timer.cancel();
        }
      });
    });
  }

  Future<void> _submitVerify() async {
    final code = _verifyCodeController.text.trim();
    if (code.isEmpty) {
      setState(() => _error = '请输入验证码');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await ref.read(minaAuthProvider).submitVerifyCode(code);
    if (!mounted) return;
    await _handleResult(result);
  }

  Future<void> _handleResult(MinaLoginResult result) async {
    switch (result) {
      case MinaLoginSuccess():
        setState(() => _busy = false);
        await ref.read(xiaoaiSettingsProvider.notifier).handleLoginSuccess();
        if (!mounted) return;
        showAppToast(context, '登录成功', type: AppToastType.success);
        if (context.canPop()) {
          context.pop();
        } else {
          context.go('/settings');
        }
      case MinaLoginNeedCaptcha(:final error):
        setState(() {
          _busy = false;
          _captcha = result;
          _captchaController.clear();
          _error = error;
        });
      case MinaLoginNeedVerify(:final kind):
        setState(() {
          _busy = false;
          _verifyKind = kind;
          _error = null;
          _verifyCodeController.clear();
        });
        await _sendCode();
      case MinaLoginFailure(:final message):
        setState(() {
          _busy = false;
          _error = message;
        });
    }
  }
}

/// 标签在上、输入框在下的字段（与 WebDAV 连接字段同款）。
class _LabeledField extends StatelessWidget {
  const _LabeledField({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 8),
        child: Text(
          label,
          style: prism.AppTextStyle.subheadline
              .of(context)
              .copyWith(
                color: prism.Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      ),
      Semantics(label: label, child: child),
    ],
  );
}
