import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:vnt_app/vnt/vnt_manager.dart';

void main() {
  test('VntManager 连接变化监听器可以添加、去重和移除', () {
    final manager = VntManager();
    var calls = 0;

    void listener() {
      calls += 1;
    }

    manager.addConnectionListener(listener);
    manager.addConnectionListener(listener);
    manager.debugNotifyConnectionsChanged();

    expect(calls, 1);

    manager.removeConnectionListener(listener);
    manager.debugNotifyConnectionsChanged();

    expect(calls, 1);
  });

  test('VntManager 连接变化通知会触达所有监听器', () {
    final manager = VntManager();
    var firstCalls = 0;
    var secondCalls = 0;

    void firstListener() {
      firstCalls += 1;
    }

    void secondListener() {
      secondCalls += 1;
    }

    manager.addConnectionListener(firstListener);
    manager.addConnectionListener(secondListener);
    manager.debugNotifyConnectionsChanged();

    expect(firstCalls, 1);
    expect(secondCalls, 1);

    manager.removeConnectionListener(firstListener);
    manager.debugNotifyConnectionsChanged();

    expect(firstCalls, 1);
    expect(secondCalls, 2);
  });

  test('VntConnectionGate 会阻止同配置重复创建', () {
    final gate = VntConnectionGate();

    expect(gate.begin('config-a'), isTrue);
    expect(gate.begin('config-a'), isFalse);
    expect(gate.isCreating, isTrue);
    expect(gate.isCreatingKey('config-a'), isTrue);

    expect(gate.finish('config-a'), isTrue);
    expect(gate.isCreating, isFalse);
    expect(gate.begin('config-a'), isTrue);
  });

  test('VntConnectionGate 允许不同配置并发创建且状态互不干扰', () {
    final gate = VntConnectionGate();

    expect(gate.begin('config-a'), isTrue);
    expect(gate.begin('config-b'), isTrue);
    expect(gate.isCreatingKey('config-a'), isTrue);
    expect(gate.isCreatingKey('config-b'), isTrue);

    expect(gate.finish('config-a'), isTrue);
    expect(gate.isCreatingKey('config-a'), isFalse);
    expect(gate.isCreatingKey('config-b'), isTrue);
    expect(gate.finish('config-b'), isTrue);
    expect(gate.isCreating, isFalse);
  });

  test('VntManager 对 Android 和 iOS 明确关闭多连接能力', () {
    expect(
      VntManager.supportsMultipleForPlatform(TargetPlatform.android),
      isFalse,
    );
    expect(
      VntManager.supportsMultipleForPlatform(TargetPlatform.iOS),
      isFalse,
    );
    expect(
      VntManager.supportsMultipleForPlatform(TargetPlatform.windows),
      isTrue,
    );
  });

  test('VntConnectionGate 会让创建完成前的取消生效', () {
    final gate = VntConnectionGate();

    expect(gate.begin('config-a'), isTrue);
    gate.cancel('config-a');

    expect(gate.finish('config-a'), isFalse);
    expect(gate.isCreating, isFalse);
    expect(gate.isCreatingKey('config-a'), isFalse);
  });

  test('VntConnectionGate 创建失败会清理 pending 状态', () {
    final gate = VntConnectionGate();

    expect(gate.begin('config-a'), isTrue);
    gate.cancel('config-a');
    gate.fail('config-a');

    expect(gate.isCreating, isFalse);
    expect(gate.begin('config-a'), isTrue);
    expect(gate.finish('config-a'), isTrue);
  });
}
