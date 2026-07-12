import 'package:flutter/material.dart';
import 'package:vnt_app/update/update_proxy_settings.dart';
import 'package:vnt_app/update/update_service.dart';
import 'package:vnt_app/utils/toast_utils.dart';

Future<void> showUpdateProxySettingsDialog(BuildContext context) async {
  final settings = await AppUpdateProxySettings.load();
  if (!context.mounted) {
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (_) => _UpdateProxySettingsDialog(initialSettings: settings),
  );
}

class _UpdateProxySettingsDialog extends StatefulWidget {
  const _UpdateProxySettingsDialog({required this.initialSettings});

  final AppUpdateProxySettings initialSettings;

  @override
  State<_UpdateProxySettingsDialog> createState() =>
      _UpdateProxySettingsDialogState();
}

class _UpdateProxySettingsDialogState
    extends State<_UpdateProxySettingsDialog> {
  late AppUpdateProxyMode _mode;
  late final TextEditingController _addressController;
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    _mode = widget.initialSettings.mode;
    _addressController = TextEditingController(
      text: widget.initialSettings.customAddress,
    );
  }

  @override
  void dispose() {
    _addressController.dispose();
    super.dispose();
  }

  AppUpdateProxy? _customProxy() => AppUpdateProxyResolver.parseProxyValue(
        _addressController.text,
        '自定义代理',
      );

  Future<void> _testProxy() async {
    final proxy = _customProxy();
    if (proxy == null) {
      showTopToast(context, '代理地址格式无效', isSuccess: false);
      return;
    }
    setState(() => _testing = true);
    final reachable = await AppUpdateProxyResolver.canConnect(proxy);
    if (!mounted) {
      return;
    }
    setState(() => _testing = false);
    showTopToast(
      context,
      reachable ? '代理端口连接成功' : '无法连接该代理端口',
      isSuccess: reachable,
    );
  }

  Future<void> _save() async {
    if (_mode == AppUpdateProxyMode.custom && _customProxy() == null) {
      showTopToast(
        context,
        '请输入有效的 HTTP、HTTPS 或 SOCKS5 代理地址',
        isSuccess: false,
      );
      return;
    }
    await AppUpdateProxySettings(
      mode: _mode,
      customAddress: _addressController.text,
    ).save();
    if (!mounted) {
      return;
    }
    Navigator.of(context).pop();
    showTopToast(context, '更新代理设置已保存', isSuccess: true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('更新网络代理'),
      content: SizedBox(
        width: 480,
        child: RadioGroup<AppUpdateProxyMode>(
          groupValue: _mode,
          onChanged: (value) => setState(() => _mode = value!),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const RadioListTile<AppUpdateProxyMode>(
                value: AppUpdateProxyMode.automatic,
                title: Text('自动使用系统代理'),
                subtitle: Text('系统代理→环境变量→本机 7890 代理→直连'),
              ),
              const RadioListTile<AppUpdateProxyMode>(
                value: AppUpdateProxyMode.custom,
                title: Text('自定义代理'),
                subtitle: Text('失败时不会自动切换直连'),
              ),
              if (_mode == AppUpdateProxyMode.custom) ...[
                const SizedBox(height: 8),
                TextField(
                  controller: _addressController,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: '代理地址',
                    hintText: 'http://127.0.0.1:7890',
                    helperText: '支持 HTTP、HTTPS、SOCKS5；省略协议时按 HTTP 处理',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: _testing ? null : _testProxy,
                    icon: _testing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.network_check),
                    label: const Text('测试代理端口'),
                  ),
                ),
              ],
              const RadioListTile<AppUpdateProxyMode>(
                value: AppUpdateProxyMode.direct,
                title: Text('强制直连'),
                subtitle: Text('忽略系统代理和代理环境变量'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }
}
