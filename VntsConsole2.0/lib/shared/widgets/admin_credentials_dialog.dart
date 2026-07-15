import 'package:flutter/material.dart';

import '../../core/design_system/app_spacing.dart';

class AdminCredentials {
  const AdminCredentials({required this.username, required this.password});

  final String username;
  final String password;
}

Future<AdminCredentials?> showAdminCredentialsDialog(
  BuildContext context, {
  required String currentUsername,
}) {
  return showDialog<AdminCredentials>(
    context: context,
    barrierDismissible: false,
    builder: (context) =>
        _AdminCredentialsDialog(currentUsername: currentUsername),
  );
}

class _AdminCredentialsDialog extends StatefulWidget {
  const _AdminCredentialsDialog({required this.currentUsername});

  final String currentUsername;

  @override
  State<_AdminCredentialsDialog> createState() =>
      _AdminCredentialsDialogState();
}

class _AdminCredentialsDialogState extends State<_AdminCredentialsDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _username;
  final _password = TextEditingController();
  final _confirmation = TextEditingController();
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    _username = TextEditingController(text: widget.currentUsername);
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
    return AlertDialog(
      title: const Text('修改管理员账号和密码'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('保存后服务会立即重启，当前登录会话随即失效；必须使用新凭据重新登录。密码不限制长度，但不能为空。'),
                const SizedBox(height: AppSpacing.lg),
                TextFormField(
                  key: const Key('new-admin-username'),
                  controller: _username,
                  autofocus: true,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(labelText: '管理员账号'),
                  validator: (value) =>
                      (value ?? '').trim().isEmpty ? '管理员账号不能为空' : null,
                ),
                const SizedBox(height: AppSpacing.lg),
                TextFormField(
                  key: const Key('new-admin-password'),
                  controller: _password,
                  obscureText: _obscure,
                  enableSuggestions: false,
                  autocorrect: false,
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: '新管理员密码',
                    suffixIcon: IconButton(
                      tooltip: _obscure ? '显示密码' : '隐藏密码',
                      onPressed: () => setState(() => _obscure = !_obscure),
                      icon: Icon(
                        _obscure
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                    ),
                  ),
                  validator: (value) {
                    final password = value ?? '';
                    if (password.trim().isEmpty) return '管理员密码不能为空';
                    if (password.toLowerCase() == 'admin') {
                      return '管理员密码不能使用 admin';
                    }
                    if (password == _username.text.trim()) {
                      return '管理员密码不能与账号相同';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: AppSpacing.lg),
                TextFormField(
                  key: const Key('confirm-admin-password'),
                  controller: _confirmation,
                  obscureText: _obscure,
                  enableSuggestions: false,
                  autocorrect: false,
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) => _submit(),
                  decoration: const InputDecoration(labelText: '确认新管理员密码'),
                  validator: (value) =>
                      value != _password.text ? '两次输入的管理员密码不一致' : null,
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          key: const Key('save-admin-credentials'),
          onPressed: _submit,
          icon: const Icon(Icons.restart_alt_rounded),
          label: const Text('保存并重新登录'),
        ),
      ],
    );
  }

  void _submit() {
    if (_formKey.currentState?.validate() != true) return;
    Navigator.pop(
      context,
      AdminCredentials(
        username: _username.text.trim(),
        password: _password.text,
      ),
    );
  }
}
