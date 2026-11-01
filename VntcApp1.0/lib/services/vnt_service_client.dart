import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:uuid/uuid.dart';

const String vntServicePipeName = r'\\.\pipe\VntCoreService.v1';
const int _protocolVersion = 1;
const int _maximumFrameSize = 64 * 1024;

class VntServiceException implements Exception {
  const VntServiceException(this.message, {this.windowsError});

  final String message;
  final int? windowsError;

  @override
  String toString() => windowsError == null
      ? 'VntServiceException: $message'
      : 'VntServiceException: $message (Windows error $windowsError)';
}

class VntServiceStatus {
  const VntServiceStatus({
    required this.serviceState,
    required this.connectionState,
    required this.configKey,
    required this.revision,
    required this.virtualIp,
    required this.connectTarget,
    required this.lastError,
    required this.updatedAtUnixMs,
  });

  final String serviceState;
  final String connectionState;
  final String configKey;
  final String revision;
  final String virtualIp;
  final String connectTarget;
  final String lastError;
  final int updatedAtUnixMs;

  bool get isConnected => connectionState == 'connected';

  factory VntServiceStatus.fromJson(Map<String, dynamic> json) {
    return VntServiceStatus(
      serviceState: (json['serviceState'] ?? '').toString(),
      connectionState: (json['connectionState'] ?? '').toString(),
      configKey: (json['configKey'] ?? '').toString(),
      revision: (json['revision'] ?? '').toString(),
      virtualIp: (json['virtualIp'] ?? '').toString(),
      connectTarget: (json['connectTarget'] ?? '').toString(),
      lastError: (json['lastError'] ?? '').toString(),
      updatedAtUnixMs: _jsonInt(json['updatedAtUnixMs']),
    );
  }
}

class VntServiceClient {
  VntServiceClient({Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  final Uuid _uuid;

  Future<bool> isAvailable() async {
    if (!Platform.isWindows) {
      return false;
    }
    try {
      await ping();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> ping() async {
    await _request('ping');
  }

  Future<VntServiceStatus> getStatus() async {
    final result = await _request('getStatus');
    return VntServiceStatus.fromJson(result);
  }

  Future<void> reload() async {
    await _request('reload');
  }

  Future<Map<String, dynamic>> _request(String command) async {
    if (!Platform.isWindows) {
      throw const VntServiceException('VNT 系统服务仅支持 Windows');
    }
    final request = <String, dynamic>{
      'version': _protocolVersion,
      'id': _uuid.v4(),
      'command': command,
    };
    final response = await Isolate.run(() => _sendPipeRequestSync(request));
    if (response['version'] != _protocolVersion ||
        response['id'] != request['id']) {
      throw const VntServiceException('VNT 系统服务返回了不匹配的 IPC 响应');
    }
    if (response['ok'] != true) {
      throw VntServiceException(
        (response['error'] ?? 'VNT 系统服务请求失败').toString(),
      );
    }
    final result = response['result'];
    if (result is! Map) {
      return <String, dynamic>{};
    }
    return result.map((key, value) => MapEntry(key.toString(), value));
  }
}

Map<String, dynamic> _sendPipeRequestSync(Map<String, dynamic> request) {
  final requestBytes = utf8.encode(jsonEncode(request));
  if (requestBytes.length > _maximumFrameSize) {
    throw const VntServiceException('VNT 系统服务 IPC 请求超过 64 KiB');
  }

  final pipeName = vntServicePipeName.toNativeUtf16();
  Pointer<Void> handle = nullptr;
  try {
    if (_waitNamedPipe(pipeName, 3000) == 0) {
      throw VntServiceException(
        '等待 VNT 系统服务命名管道超时',
        windowsError: _getLastError(),
      );
    }
    handle = _createFile(
      pipeName,
      _genericRead | _genericWrite,
      0,
      nullptr,
      _openExisting,
      0,
      nullptr,
    );
    if (handle.address == _invalidHandleValue.address) {
      throw VntServiceException(
        '连接 VNT 系统服务命名管道失败',
        windowsError: _getLastError(),
      );
    }

    final mode = calloc<Uint32>()..value = _pipeReadModeMessage;
    final requestBuffer = calloc<Uint8>(requestBytes.length);
    final bytesWritten = calloc<Uint32>();
    final responseBuffer = calloc<Uint8>(_maximumFrameSize);
    final bytesRead = calloc<Uint32>();
    try {
      if (_setNamedPipeHandleState(handle, mode, nullptr, nullptr) == 0) {
        throw VntServiceException(
          '设置 VNT 系统服务命名管道模式失败',
          windowsError: _getLastError(),
        );
      }
      requestBuffer.asTypedList(requestBytes.length).setAll(0, requestBytes);
      if (_writeFile(
            handle,
            requestBuffer,
            requestBytes.length,
            bytesWritten,
            nullptr,
          ) ==
          0) {
        throw VntServiceException(
          '写入 VNT 系统服务请求失败',
          windowsError: _getLastError(),
        );
      }
      if (bytesWritten.value != requestBytes.length) {
        throw const VntServiceException('VNT 系统服务 IPC 请求写入不完整');
      }
      if (_readFile(
            handle,
            responseBuffer,
            _maximumFrameSize,
            bytesRead,
            nullptr,
          ) ==
          0) {
        throw VntServiceException(
          '读取 VNT 系统服务响应失败',
          windowsError: _getLastError(),
        );
      }
      if (bytesRead.value == 0 || bytesRead.value > _maximumFrameSize) {
        throw const VntServiceException('VNT 系统服务返回了无效响应长度');
      }
      final decoded = jsonDecode(
        utf8.decode(responseBuffer.asTypedList(bytesRead.value)),
      );
      if (decoded is! Map) {
        throw const VntServiceException('VNT 系统服务响应不是 JSON 对象');
      }
      return decoded.map((key, value) => MapEntry(key.toString(), value));
    } finally {
      calloc.free(mode);
      calloc.free(requestBuffer);
      calloc.free(bytesWritten);
      calloc.free(responseBuffer);
      calloc.free(bytesRead);
    }
  } finally {
    if (handle != nullptr && handle.address != _invalidHandleValue.address) {
      _closeHandle(handle);
    }
    calloc.free(pipeName);
  }
}

int _jsonInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

const int _genericRead = 0x80000000;
const int _genericWrite = 0x40000000;
const int _openExisting = 3;
const int _pipeReadModeMessage = 2;
final Pointer<Void> _invalidHandleValue = Pointer<Void>.fromAddress(-1);

final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');

final int Function(Pointer<Utf16>, int) _waitNamedPipe =
    _kernel32.lookupFunction<Int32 Function(Pointer<Utf16>, Uint32),
        int Function(Pointer<Utf16>, int)>('WaitNamedPipeW');
final Pointer<Void> Function(
  Pointer<Utf16>,
  int,
  int,
  Pointer<Void>,
  int,
  int,
  Pointer<Void>,
) _createFile = _kernel32.lookupFunction<
    Pointer<Void> Function(
      Pointer<Utf16>,
      Uint32,
      Uint32,
      Pointer<Void>,
      Uint32,
      Uint32,
      Pointer<Void>,
    ),
    Pointer<Void> Function(
      Pointer<Utf16>,
      int,
      int,
      Pointer<Void>,
      int,
      int,
      Pointer<Void>,
    )>('CreateFileW');
final int Function(
  Pointer<Void>,
  Pointer<Uint32>,
  Pointer<Uint32>,
  Pointer<Uint32>,
) _setNamedPipeHandleState = _kernel32.lookupFunction<
    Int32 Function(
      Pointer<Void>,
      Pointer<Uint32>,
      Pointer<Uint32>,
      Pointer<Uint32>,
    ),
    int Function(
      Pointer<Void>,
      Pointer<Uint32>,
      Pointer<Uint32>,
      Pointer<Uint32>,
    )>('SetNamedPipeHandleState');
final int Function(
  Pointer<Void>,
  Pointer<Uint8>,
  int,
  Pointer<Uint32>,
  Pointer<Void>,
) _writeFile = _kernel32.lookupFunction<
    Int32 Function(
      Pointer<Void>,
      Pointer<Uint8>,
      Uint32,
      Pointer<Uint32>,
      Pointer<Void>,
    ),
    int Function(
      Pointer<Void>,
      Pointer<Uint8>,
      int,
      Pointer<Uint32>,
      Pointer<Void>,
    )>('WriteFile');
final int Function(
  Pointer<Void>,
  Pointer<Uint8>,
  int,
  Pointer<Uint32>,
  Pointer<Void>,
) _readFile = _kernel32.lookupFunction<
    Int32 Function(
      Pointer<Void>,
      Pointer<Uint8>,
      Uint32,
      Pointer<Uint32>,
      Pointer<Void>,
    ),
    int Function(
      Pointer<Void>,
      Pointer<Uint8>,
      int,
      Pointer<Uint32>,
      Pointer<Void>,
    )>('ReadFile');
final int Function(Pointer<Void>) _closeHandle = _kernel32.lookupFunction<
    Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('CloseHandle');
final int Function() _getLastError =
    _kernel32.lookupFunction<Uint32 Function(), int Function()>('GetLastError');
