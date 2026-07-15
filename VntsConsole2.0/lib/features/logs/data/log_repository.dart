import 'dart:convert';
import 'dart:io';
import 'dart:math';

class LogFileInfo {
  const LogFileInfo({
    required this.name,
    required this.sizeBytes,
    required this.modifiedAt,
  });

  final String name;
  final int sizeBytes;
  final DateTime modifiedAt;
}

class LogDocument {
  const LogDocument({
    required this.fileName,
    required this.lines,
    required this.truncated,
  });

  final String fileName;
  final List<String> lines;
  final bool truncated;
}

class LogRepository {
  const LogRepository(this.directory);

  static const maximumReadBytes = 4 * 1024 * 1024;
  static final _allowedName = RegExp(r'^[^\\/]+\.log(?:\.\d+)?$');

  final Directory directory;

  Future<List<LogFileInfo>> listFiles() async {
    if (!await directory.exists()) return const [];
    final result = <LogFileInfo>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = _baseName(entity.path);
      if (!_allowedName.hasMatch(name)) continue;
      final stat = await entity.stat();
      result.add(
        LogFileInfo(
          name: name,
          sizeBytes: stat.size,
          modifiedAt: stat.modified,
        ),
      );
    }
    result.sort((left, right) => right.modifiedAt.compareTo(left.modifiedAt));
    return result;
  }

  Future<LogDocument> readTail(String fileName) async {
    final file = _resolve(fileName);
    final handle = await file.open();
    try {
      final length = await handle.length();
      final start = max(0, length - maximumReadBytes);
      await handle.setPosition(start);
      var text = utf8.decode(
        await handle.read(length - start),
        allowMalformed: true,
      );
      if (start > 0) {
        final firstBreak = text.indexOf('\n');
        text = firstBreak < 0 ? '' : text.substring(firstBreak + 1);
      }
      return LogDocument(
        fileName: fileName,
        lines: const LineSplitter().convert(text),
        truncated: start > 0,
      );
    } finally {
      await handle.close();
    }
  }

  File _resolve(String fileName) {
    if (!_allowedName.hasMatch(fileName)) {
      throw const FileSystemException('日志文件名不在允许范围内');
    }
    return File('${directory.path}${Platform.pathSeparator}$fileName');
  }

  static String _baseName(String path) {
    return path.split(Platform.pathSeparator).last;
  }
}
