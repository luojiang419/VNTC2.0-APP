import 'package:flutter_test/flutter_test.dart';
import 'package:vnt_app/chat/chat_manager.dart';
import 'package:vnt_app/chat/chat_models.dart';
import 'package:vnt_app/windows/windows_firewall_service.dart';

void main() {
  final manager = ChatManager.instance;
  const remoteAssistRule = WindowsFirewallRuleSpec(
    name: 'VNT Remote Assist TCP 21118',
    protocol: 'TCP',
    port: 21118,
    purpose: '远程协助 RustDesk 监听',
  );

  WindowsFirewallEnsureResult softFirewallFailure() {
    return const WindowsFirewallEnsureResult(
      success: false,
      promptedForElevation: true,
      includeRemoteAssist: true,
      targetedRules: const [remoteAssistRule],
      allowedRules: const [],
      missingRules: const [remoteAssistRule],
      failureKind: WindowsFirewallEnsureFailureKind.elevationNotShown,
      blocksRemoteAssist: false,
      firewallEnabled: true,
      errorMessage: '管理员授权未显示，继续尝试启动桌面服务',
    );
  }

  RemoteAssistSession buildSession({
    required String sessionId,
    required RemoteAssistMode mode,
    required bool isIncoming,
    required String peerId,
    required String peerVirtualIp,
    required String controllerPeerId,
    required String controlledPeerId,
    required String controllerVirtualIp,
    required String controlledVirtualIp,
    RemoteAssistState state = RemoteAssistState.pending,
  }) {
    return RemoteAssistSession(
      sessionId: sessionId,
      networkKey: 'net-a',
      peerId: peerId,
      peerVirtualIp: peerVirtualIp,
      controllerPeerId: controllerPeerId,
      controlledPeerId: controlledPeerId,
      controllerVirtualIp: controllerVirtualIp,
      controlledVirtualIp: controlledVirtualIp,
      mode: mode,
      listenPort: 21118,
      sessionToken: 'token-$sessionId',
      state: state,
      isIncoming: isIncoming,
      createdAt: DateTime(2026, 5, 7, 18, 0, 0),
      updatedAt: DateTime(2026, 5, 7, 18, 0, 0),
    );
  }

  setUp(() {
    manager.debugResetRemoteAssistTestState();
    manager.debugRefreshRemoteAssistRuntime = ({listenPort}) async {};
  });

  tearDown(() {
    manager.debugResetRemoteAssistTestState();
  });

  test('requestControl 接受方在防火墙软失败但 host 成功时仍发送 accept 和 ready', () async {
    final sentPayloads = <Map<String, dynamic>>[];
    manager.remoteAssistSession = buildSession(
      sessionId: 'request-control-soft-firewall',
      mode: RemoteAssistMode.requestControl,
      isIncoming: true,
      peerId: 'peer-b',
      peerVirtualIp: '10.0.0.2',
      controllerPeerId: 'peer-b',
      controlledPeerId: 'peer-a',
      controllerVirtualIp: '10.0.0.2',
      controlledVirtualIp: '10.0.0.1',
    );
    manager.debugEnsureRemoteAssistFirewallResult =
        (_) async => softFirewallFailure();
    manager.debugEnsureRemoteAssistHostReady = (_, __) async {};
    manager.debugSendEnvelopeToPeer = ({
      required networkKey,
      required peerId,
      required type,
      conversationId,
      channelId,
      required payload,
    }) async {
      sentPayloads.add({
        'type': type,
        'payload': Map<String, dynamic>.from(payload),
      });
    };

    await manager.acceptRemoteAssist();

    expect(
      sentPayloads.map((item) => item['type']),
      [ChatEnvelopeType.remoteAssistAccept, ChatEnvelopeType.remoteAssistReady],
    );
    for (final sent in sentPayloads) {
      expect(
        (sent['payload'] as Map<String, dynamic>)['sessionToken'],
        manager.remoteAssistSession?.sessionToken,
      );
    }
    expect(manager.remoteAssistSession?.state, RemoteAssistState.ready);
    expect(manager.statusMessage, contains('Windows 防火墙未确认放行'));
  });

  test('inviteControl 发起方收到 accept 后在防火墙软失败但 host 成功时仍发送 ready', () async {
    final sentPayloads = <Map<String, dynamic>>[];
    manager.remoteAssistSession = buildSession(
      sessionId: 'invite-control-soft-firewall',
      mode: RemoteAssistMode.inviteControl,
      isIncoming: false,
      peerId: 'peer-b',
      peerVirtualIp: '10.0.0.2',
      controllerPeerId: 'peer-b',
      controlledPeerId: 'peer-a',
      controllerVirtualIp: '10.0.0.2',
      controlledVirtualIp: '10.0.0.1',
    );
    manager.debugEnsureRemoteAssistFirewallResult =
        (_) async => softFirewallFailure();
    manager.debugEnsureRemoteAssistHostReady = (_, __) async {};
    manager.debugSendEnvelopeToPeer = ({
      required networkKey,
      required peerId,
      required type,
      conversationId,
      channelId,
      required payload,
    }) async {
      sentPayloads.add({
        'type': type,
        'payload': Map<String, dynamic>.from(payload),
      });
    };

    await manager.debugHandleRemoteAssistAcceptForTest(
      sessionId: 'invite-control-soft-firewall',
    );

    expect(
      sentPayloads.map((item) => item['type']),
      [ChatEnvelopeType.remoteAssistReady],
    );
    expect(
      (sentPayloads.single['payload'] as Map<String, dynamic>)['sessionToken'],
      manager.remoteAssistSession?.sessionToken,
    );
    expect(manager.remoteAssistSession?.state, RemoteAssistState.ready);
    expect(manager.statusMessage, contains('Windows 防火墙未确认放行'));
  });

  test('重复收到 remoteAssistAccept 时仍只处理一次', () async {
    final sentTypes = <ChatEnvelopeType>[];
    manager.remoteAssistSession = buildSession(
      sessionId: 'duplicate-accept',
      mode: RemoteAssistMode.inviteControl,
      isIncoming: false,
      peerId: 'peer-b',
      peerVirtualIp: '10.0.0.2',
      controllerPeerId: 'peer-b',
      controlledPeerId: 'peer-a',
      controllerVirtualIp: '10.0.0.2',
      controlledVirtualIp: '10.0.0.1',
    );
    manager.debugEnsureRemoteAssistFirewallResult =
        (_) async => softFirewallFailure();
    manager.debugEnsureRemoteAssistHostReady = (_, __) async {};
    manager.debugSendEnvelopeToPeer = ({
      required networkKey,
      required peerId,
      required type,
      conversationId,
      channelId,
      required payload,
    }) async {
      sentTypes.add(type);
    };

    await manager.debugHandleRemoteAssistAcceptForTest(
      sessionId: 'duplicate-accept',
    );
    await manager.debugHandleRemoteAssistAcceptForTest(
      sessionId: 'duplicate-accept',
    );

    expect(sentTypes, [ChatEnvelopeType.remoteAssistReady]);
    expect(manager.remoteAssistSession?.state, RemoteAssistState.ready);
  });

  test('收到 remoteAssistReady 后控制端会进入 launchController 分支', () async {
    String? launchedIp;
    String? launchedToken;
    manager.remoteAssistSession = buildSession(
      sessionId: 'ready-launch-controller',
      mode: RemoteAssistMode.requestControl,
      isIncoming: false,
      peerId: 'peer-b',
      peerVirtualIp: '10.0.0.2',
      controllerPeerId: 'peer-a',
      controlledPeerId: 'peer-b',
      controllerVirtualIp: '10.0.0.1',
      controlledVirtualIp: '10.0.0.2',
      state: RemoteAssistState.accepted,
    );
    manager.debugLaunchRemoteAssistController =
        (virtualIp, sessionToken) async {
      launchedIp = virtualIp;
      launchedToken = sessionToken;
    };

    await manager.debugHandleRemoteAssistReadyForTest(
      sessionId: 'ready-launch-controller',
    );

    expect(launchedIp, '10.0.0.2');
    expect(launchedToken, 'token-ready-launch-controller');
    expect(manager.remoteAssistSession?.state, RemoteAssistState.active);
    expect(manager.statusMessage, contains('远程协助会话已启动'));
  });

  test('取消远程协助时会清理本地内置 RustDesk 会话态', () async {
    var cleanupCalls = 0;
    manager.remoteAssistSession = buildSession(
      sessionId: 'cancel-cleanup',
      mode: RemoteAssistMode.requestControl,
      isIncoming: false,
      peerId: 'peer-b',
      peerVirtualIp: '10.0.0.2',
      controllerPeerId: 'peer-a',
      controlledPeerId: 'peer-b',
      controllerVirtualIp: '10.0.0.1',
      controlledVirtualIp: '10.0.0.2',
      state: RemoteAssistState.ready,
    );
    manager.debugCleanupRemoteAssistRuntime = ({listenPort}) async {
      cleanupCalls++;
      expect(listenPort, 21118);
    };
    manager.debugSendEnvelopeToPeer = ({
      required networkKey,
      required peerId,
      required type,
      conversationId,
      channelId,
      required payload,
    }) async {};

    await manager.cancelRemoteAssist();

    expect(cleanupCalls, 1);
    expect(manager.remoteAssistSession?.state, RemoteAssistState.ended);
  });

  test('远程协助启动失败时会清理本地内置 RustDesk 会话态', () async {
    var cleanupCalls = 0;
    manager.remoteAssistSession = buildSession(
      sessionId: 'request-control-failed-cleanup',
      mode: RemoteAssistMode.requestControl,
      isIncoming: true,
      peerId: 'peer-b',
      peerVirtualIp: '10.0.0.2',
      controllerPeerId: 'peer-b',
      controlledPeerId: 'peer-a',
      controllerVirtualIp: '10.0.0.2',
      controlledVirtualIp: '10.0.0.1',
    );
    manager.debugEnsureRemoteAssistFirewallResult =
        (_) async => softFirewallFailure();
    manager.debugEnsureRemoteAssistHostReady = (_, __) async {
      throw StateError('host boom');
    };
    manager.debugCleanupRemoteAssistRuntime = ({listenPort}) async {
      cleanupCalls++;
      expect(listenPort, 21118);
    };

    await manager.acceptRemoteAssist();

    expect(cleanupCalls, 1);
    expect(manager.remoteAssistSession?.state, RemoteAssistState.failed);
    expect(manager.statusMessage, contains('host boom'));
  });

  test('收到远程协助结束消息时会清理本地内置 RustDesk 会话态', () async {
    var cleanupCalls = 0;
    manager.remoteAssistSession = buildSession(
      sessionId: 'remote-end-cleanup',
      mode: RemoteAssistMode.requestControl,
      isIncoming: false,
      peerId: 'peer-b',
      peerVirtualIp: '10.0.0.2',
      controllerPeerId: 'peer-a',
      controlledPeerId: 'peer-b',
      controllerVirtualIp: '10.0.0.1',
      controlledVirtualIp: '10.0.0.2',
      state: RemoteAssistState.active,
    );
    manager.debugCleanupRemoteAssistRuntime = ({listenPort}) async {
      cleanupCalls++;
      expect(listenPort, 21118);
    };

    await manager.debugHandleRemoteAssistEndForTest();

    expect(cleanupCalls, 1);
    expect(manager.remoteAssistSession?.state, RemoteAssistState.ended);
    expect(manager.statusMessage, contains('远程协助会话已结束'));
  });
}
