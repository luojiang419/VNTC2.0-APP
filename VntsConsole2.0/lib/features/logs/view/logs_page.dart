import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/design_system/app_colors.dart';
import '../../../core/design_system/app_spacing.dart';
import '../../../core/platform/portable_layout.dart';
import '../../../shared/widgets/app_state_view.dart';
import '../../dashboard/view/dashboard_formatters.dart';
import '../controller/log_controller.dart';
import '../data/log_repository.dart';

class LogsPage extends StatefulWidget {
  const LogsPage({super.key, this.layout});

  final PortableLayout? layout;

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  late final LogController controller;
  final query = TextEditingController();

  @override
  void initState() {
    super.initState();
    controller = LogController(
      widget.layout == null
          ? null
          : LogRepository(widget.layout!.logsDirectory),
    )..load();
  }

  @override
  void dispose() {
    query.dispose();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => Padding(
        key: const Key('logs-page'),
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('日志', style: theme.textTheme.headlineMedium),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        '本地读取、筛选、复制和导出服务日志',
                        style: TextStyle(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (controller.files.isNotEmpty)
                  SizedBox(
                    width: 210,
                    child: DropdownButtonFormField<String>(
                      initialValue: controller.selectedFile,
                      decoration: const InputDecoration(labelText: '日志文件'),
                      items: controller.files
                          .map(
                            (file) => DropdownMenuItem(
                              value: file.name,
                              child: Text(
                                '${file.name} · ${formatBytes(file.sizeBytes)}',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: controller.loading
                          ? null
                          : (value) {
                              if (value != null) controller.selectFile(value);
                            },
                    ),
                  ),
                const SizedBox(width: AppSpacing.xs),
                IconButton(
                  tooltip: '刷新',
                  onPressed: controller.loading ? null : controller.load,
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            _toolbar(),
            const SizedBox(height: AppSpacing.md),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _toolbar() {
    final lines = controller.filteredLines;
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SizedBox(
          width: 300,
          child: TextField(
            controller: query,
            onChanged: controller.setQuery,
            decoration: const InputDecoration(
              labelText: '筛选文本',
              prefixIcon: Icon(Icons.search_rounded),
            ),
          ),
        ),
        SizedBox(
          width: 160,
          child: DropdownButtonFormField<LogLevelFilter>(
            initialValue: controller.level,
            decoration: const InputDecoration(labelText: '级别'),
            items: LogLevelFilter.values
                .map(
                  (level) => DropdownMenuItem(
                    value: level,
                    child: Text(_levelLabel(level)),
                  ),
                )
                .toList(),
            onChanged: (value) {
              if (value != null) controller.setLevel(value);
            },
          ),
        ),
        FilterChip(
          selected: controller.live,
          onSelected: controller.setLive,
          avatar: const Icon(Icons.sync_rounded, size: 18),
          label: const Text('每 5 秒跟随'),
        ),
        OutlinedButton.icon(
          onPressed: lines.isEmpty ? null : _copy,
          icon: const Icon(Icons.copy_rounded),
          label: Text('复制 ${lines.length} 行'),
        ),
        FilledButton.tonalIcon(
          onPressed: lines.isEmpty ? null : _export,
          icon: const Icon(Icons.save_alt_rounded),
          label: const Text('导出筛选结果'),
        ),
      ],
    );
  }

  Widget _body() {
    if (controller.loading) return const Card(child: AppStateView.loading());
    if (controller.error != null && controller.document == null) {
      return Card(
        child: AppStateView.error(
          message: controller.error!,
          onAction: controller.load,
        ),
      );
    }
    if (controller.files.isEmpty || controller.document == null) {
      return const Card(
        child: AppStateView.empty(
          icon: Icons.receipt_long_outlined,
          title: '尚无日志文件',
          message: '服务产生首条日志后会显示在这里。',
          iconColor: AppColors.brand,
        ),
      );
    }
    final lines = controller.filteredLines;
    if (lines.isEmpty) {
      return const Card(
        child: AppStateView.empty(
          icon: Icons.filter_alt_off_outlined,
          title: '没有匹配日志',
          message: '请调整文本或级别筛选条件。',
          iconColor: AppColors.brand,
        ),
      );
    }
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          if (controller.document!.truncated)
            Container(
              width: double.infinity,
              color: AppColors.warning.withValues(alpha: 0.12),
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.xs,
              ),
              child: const Text('文件较大，仅显示末尾 4 MiB 的完整日志行。'),
            ),
          Expanded(
            child: SelectionArea(
              child: ListView.builder(
                padding: const EdgeInsets.all(AppSpacing.md),
                itemCount: lines.length,
                itemBuilder: (context, index) => _LogLine(line: lines[index]),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _copy() async {
    await Clipboard.setData(
      ClipboardData(text: controller.filteredLines.join('\n')),
    );
    if (mounted) _message('筛选日志已复制到剪贴板');
  }

  Future<void> _export() async {
    final source = controller.selectedFile ?? 'vnts2.log';
    final location = await getSaveLocation(
      suggestedName: '${source.replaceAll('.', '_')}_filtered.txt',
      acceptedTypeGroups: const [
        XTypeGroup(label: '文本日志', extensions: ['txt', 'log']),
      ],
    );
    if (location == null) return;
    try {
      await File(
        location.path,
      ).writeAsString('${controller.filteredLines.join('\n')}\n', flush: true);
      if (mounted) _message('筛选日志已导出');
    } on FileSystemException catch (exception) {
      if (mounted) _message('导出失败：${exception.message}');
    }
  }

  void _message(String value) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(value)));
  }

  static String _levelLabel(LogLevelFilter level) => switch (level) {
    LogLevelFilter.all => '全部级别',
    LogLevelFilter.error => 'ERROR',
    LogLevelFilter.warn => 'WARN',
    LogLevelFilter.info => 'INFO',
    LogLevelFilter.debug => 'DEBUG',
    LogLevelFilter.trace => 'TRACE',
  };
}

class _LogLine extends StatelessWidget {
  const _LogLine({required this.line});

  final String line;

  @override
  Widget build(BuildContext context) {
    final upper = line.toUpperCase();
    final color = upper.contains('ERROR')
        ? Theme.of(context).colorScheme.error
        : upper.contains('WARN')
        ? AppColors.warning
        : upper.contains('DEBUG') || upper.contains('TRACE')
        ? Theme.of(context).colorScheme.onSurfaceVariant
        : null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Text(
        line,
        style: TextStyle(fontFamily: 'monospace', fontSize: 12, color: color),
      ),
    );
  }
}
