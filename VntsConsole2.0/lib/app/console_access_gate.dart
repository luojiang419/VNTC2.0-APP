import 'package:flutter/material.dart';

import '../core/design_system/app_colors.dart';
import '../core/design_system/app_spacing.dart';
import 'app_controller.dart';

class ConsoleAccessGate extends StatefulWidget {
  const ConsoleAccessGate({super.key, required this.controller});

  final AppController controller;

  @override
  State<ConsoleAccessGate> createState() => _ConsoleAccessGateState();
}

class _ConsoleAccessGateState extends State<ConsoleAccessGate> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _confirmation = TextEditingController();
  bool _obscure = true;

  bool get _isSetup =>
      widget.controller.accessState == ConsoleAccessState.setupRequired;

  bool get _canSubmit {
    if (_username.text.trim().isEmpty || _password.text.trim().isEmpty) {
      return false;
    }
    return !_isSetup || _confirmation.text.isNotEmpty;
  }

  @override
  void initState() {
    super.initState();
    _syncUsername();
  }

  @override
  void didUpdateWidget(covariant ConsoleAccessGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_username.text.isEmpty) _syncUsername();
  }

  void _syncUsername() {
    final username = widget.controller.knownUsername;
    if (username != 'bootstrap-admin') _username.text = username;
  }

  @override
  void dispose() {
    _password.clear();
    _confirmation.clear();
    _username.dispose();
    _password.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = widget.controller.accessState;
    final title = switch (state) {
      ConsoleAccessState.setupRequired => '首次设置管理员',
      ConsoleAccessState.locked => '控制台已锁定',
      _ => '登录 VNTS2 控制台',
    };
    final description = switch (state) {
      ConsoleAccessState.setupRequired =>
        '首次运行必须设置管理员账号和密码。凭据只写入本机服务配置，控制台不会保存明文密码。',
      ConsoleAccessState.locked => '为保护隐私，业务页面已隐藏。请重新验证管理员身份。',
      _ => '请输入管理员账号和密码，验证通过后才能进入软件。',
    };

    return ColoredBox(
      color: theme.colorScheme.surfaceContainerLowest,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Card(
              key: const Key('console-access-gate'),
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: AutofillGroup(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Align(
                        alignment: Alignment.center,
                        child: Container(
                          width: 58,
                          height: 58,
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary.withValues(
                              alpha: 0.12,
                            ),
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: Icon(
                            _isSetup
                                ? Icons.admin_panel_settings_outlined
                                : Icons.lock_outline_rounded,
                            size: 30,
                            color: AppColors.brand,
                          ),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      Text(
                        title,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      Text(
                        description,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          height: 1.55,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xl),
                      TextField(
                        key: const Key('access-username'),
                        controller: _username,
                        enabled: !widget.controller.accessBusy,
                        autofillHints: const [AutofillHints.username],
                        textInputAction: TextInputAction.next,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          labelText: '管理员账号',
                          prefixIcon: Icon(Icons.person_outline_rounded),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      TextField(
                        key: const Key('access-password'),
                        controller: _password,
                        enabled: !widget.controller.accessBusy,
                        obscureText: _obscure,
                        enableSuggestions: false,
                        autocorrect: false,
                        autofillHints: const [AutofillHints.password],
                        textInputAction: _isSetup
                            ? TextInputAction.next
                            : TextInputAction.done,
                        onChanged: (_) => setState(() {}),
                        onSubmitted: (_) {
                          if (!_isSetup && _canSubmit) _submit();
                        },
                        decoration: InputDecoration(
                          labelText: '管理员密码',
                          prefixIcon: const Icon(Icons.key_outlined),
                          suffixIcon: IconButton(
                            tooltip: _obscure ? '显示密码' : '隐藏密码',
                            onPressed: () =>
                                setState(() => _obscure = !_obscure),
                            icon: Icon(
                              _obscure
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                            ),
                          ),
                        ),
                      ),
                      if (_isSetup) ...[
                        const SizedBox(height: AppSpacing.lg),
                        TextField(
                          key: const Key('access-password-confirmation'),
                          controller: _confirmation,
                          enabled: !widget.controller.accessBusy,
                          obscureText: _obscure,
                          enableSuggestions: false,
                          autocorrect: false,
                          textInputAction: TextInputAction.done,
                          onChanged: (_) => setState(() {}),
                          onSubmitted: (_) {
                            if (_canSubmit) _submit();
                          },
                          decoration: const InputDecoration(
                            labelText: '确认管理员密码',
                            prefixIcon: Icon(Icons.verified_user_outlined),
                          ),
                        ),
                      ],
                      if (widget.controller.accessMessage != null) ...[
                        const SizedBox(height: AppSpacing.md),
                        Semantics(
                          liveRegion: true,
                          child: Text(
                            widget.controller.accessMessage!,
                            key: const Key('access-message'),
                            style: TextStyle(
                              color: theme.colorScheme.error,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: AppSpacing.xl),
                      FilledButton.icon(
                        key: const Key('login-now'),
                        onPressed: widget.controller.accessBusy || !_canSubmit
                            ? null
                            : _submit,
                        icon: widget.controller.accessBusy
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Icon(
                                _isSetup
                                    ? Icons.check_circle_outline_rounded
                                    : Icons.login_rounded,
                              ),
                        label: Text(_isSetup ? '保存管理员并进入' : '立即登录'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    if (_isSetup && _password.text != _confirmation.text) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('两次输入的管理员密码不一致')));
      return;
    }
    final password = _password.text;
    final succeeded = _isSetup
        ? await widget.controller.completeInitialSetup(_username.text, password)
        : await widget.controller.login(_username.text, password);
    _password.clear();
    _confirmation.clear();
    if (mounted && !succeeded) setState(() {});
  }
}
