import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../data/log_repository.dart';

enum LogLevelFilter { all, error, warn, info, debug, trace }

class LogController extends ChangeNotifier {
  LogController(this._repository);

  final LogRepository? _repository;
  List<LogFileInfo> files = const [];
  LogDocument? document;
  String? selectedFile;
  String query = '';
  LogLevelFilter level = LogLevelFilter.all;
  bool loading = true;
  bool live = false;
  String? error;
  Timer? _timer;
  bool _refreshing = false;
  bool _disposed = false;

  List<String> get filteredLines {
    final source = document?.lines ?? const <String>[];
    final needle = query.trim().toLowerCase();
    final levelNeedle = level == LogLevelFilter.all
        ? null
        : level.name.toUpperCase();
    return source
        .where((line) {
          if (levelNeedle != null &&
              !line.toUpperCase().contains(levelNeedle)) {
            return false;
          }
          return needle.isEmpty || line.toLowerCase().contains(needle);
        })
        .toList(growable: false);
  }

  Future<void> load() async {
    final repository = _repository;
    if (repository == null) {
      loading = false;
      error = '未发现便携 data/logs 目录，请从完整增强版分发目录启动。';
      _notify();
      return;
    }
    loading = true;
    error = null;
    _notify();
    try {
      files = await repository.listFiles();
      if (files.isEmpty) {
        selectedFile = null;
        document = null;
      } else {
        if (!files.any((item) => item.name == selectedFile)) {
          selectedFile = files.first.name;
        }
        document = await repository.readTail(selectedFile!);
      }
    } on FileSystemException catch (exception) {
      error = '读取日志失败：${exception.message}';
    } finally {
      loading = false;
      _notify();
    }
  }

  Future<void> selectFile(String value) async {
    if (value == selectedFile || _repository == null) return;
    selectedFile = value;
    loading = true;
    error = null;
    _notify();
    try {
      document = await _repository.readTail(value);
    } on FileSystemException catch (exception) {
      error = '读取日志失败：${exception.message}';
    } finally {
      loading = false;
      _notify();
    }
  }

  void setQuery(String value) {
    query = value;
    _notify();
  }

  void setLevel(LogLevelFilter value) {
    if (value == level) return;
    level = value;
    _notify();
  }

  void setLive(bool value) {
    if (live == value) return;
    live = value;
    _timer?.cancel();
    _timer = value
        ? Timer.periodic(const Duration(seconds: 5), (_) => _refreshTail())
        : null;
    _notify();
  }

  Future<void> _refreshTail() async {
    if (_refreshing || _repository == null || selectedFile == null) return;
    _refreshing = true;
    try {
      document = await _repository.readTail(selectedFile!);
      files = await _repository.listFiles();
      error = null;
    } on FileSystemException catch (exception) {
      error = '刷新日志失败：${exception.message}';
    } finally {
      _refreshing = false;
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
