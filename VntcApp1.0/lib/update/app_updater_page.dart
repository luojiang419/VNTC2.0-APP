import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vnt_app/app_version.dart';
import 'package:vnt_app/update/update_service.dart';
import 'package:vnt_app/update/update_session.dart';

class AppUpdaterApp extends StatelessWidget {
  const AppUpdaterApp({
    super.key,
    required this.session,
  });

  final AppUpdateSession session;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: '正在更新',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2F6FED)),
        useMaterial3: true,
      ),
      home: AppUpdaterPage(session: session),
    );
  }
}

class AppUpdaterPage extends StatefulWidget {
  AppUpdaterPage({
    super.key,
    required this.session,
    AppUpdateService? service,
  }) : service = service ?? AppUpdateService();

  final AppUpdateSession session;
  final AppUpdateService service;

  @override
  State<AppUpdaterPage> createState() => _AppUpdaterPageState();
}

class _AppUpdaterPageState extends State<AppUpdaterPage> {
  String _message = '正在准备更新...';
  String? _error;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _run() async {
    try {
      await widget.service.runUpdaterSession(
        widget.session,
        onStep: (message) {
          if (!mounted) {
            return;
          }
          setState(() {
            _message = message;
          });
        },
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _done = true;
        _message = '更新完成，正在启动新版...';
      });
      Timer(const Duration(seconds: 1), () {
        exit(0);
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = '$error';
        _message = '更新失败';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasError = _error != null;
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      hasError
                          ? Icons.error_outline_rounded
                          : _done
                              ? Icons.check_circle_outline_rounded
                              : Icons.system_update_alt_rounded,
                      color: hasError
                          ? theme.colorScheme.error
                          : theme.colorScheme.primary,
                      size: 30,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        '${AppVersion.productName} 更新',
                        style: theme.textTheme.titleLarge,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Text(_message, style: theme.textTheme.bodyLarge),
                const SizedBox(height: 16),
                if (hasError) ...[
                  SelectableText(
                    _error!,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                  const SizedBox(height: 10),
                  SelectableText(
                    '日志目录：${widget.session.storageRoot}',
                    style: theme.textTheme.bodySmall,
                  ),
                ] else ...[
                  const LinearProgressIndicator(),
                  const SizedBox(height: 10),
                  Text(
                    widget.session.versionTag,
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
