import 'package:flutter_test/flutter_test.dart';
import 'package:vnt_app/remote_assist/remote_assist_constants.dart';
import 'package:vnt_app/remote_assist/remote_assist_models.dart';
import 'package:vnt_app/remote_assist/remote_assist_utils.dart';

void main() {
  test('cidrFromNetworkAndMask converts ipv4 netmask to cidr', () {
    expect(
        cidrFromNetworkAndMask('10.26.0.0', '255.255.255.0'), '10.26.0.0/24');
    expect(cidrFromNetworkAndMask('10.26.0.0', '255.255.0.0'), '10.26.0.0/16');
  });

  test('cidrFromNetworkAndMask rejects invalid masks', () {
    expect(cidrFromNetworkAndMask('10.26.0.0', '255.0.255.0'), isNull);
    expect(cidrFromNetworkAndMask('bad', '255.255.255.0'), isNull);
  });

  test('normalizeRemoteAssistDisplayName falls back when empty or ip', () {
    expect(
      normalizeRemoteAssistDisplayName('', fallbackIp: '10.0.0.2'),
      '未命名设备',
    );
    expect(
      normalizeRemoteAssistDisplayName('10.0.0.2', fallbackIp: '10.0.0.2'),
      '未命名设备',
    );
    expect(
      normalizeRemoteAssistDisplayName('Alice-PC', fallbackIp: '10.0.0.2'),
      'Alice-PC',
    );
  });

  test('presence announcement round trip preserves fields', () {
    const announcement = RemoteAssistPresenceAnnouncement(
      displayName: 'Alice-PC',
      virtualIp: '10.0.0.2',
      networkName: '默认网络',
      version: '1.0.0',
      platform: RemoteAssistPlatform.windows,
      supportedRoles: <String>[
        RemoteAssistConstants.capabilityController,
      ],
      capabilities: <String>[
        'remote_assist_windows',
        RemoteAssistConstants.capabilityController,
      ],
      sentAtEpochMs: 123,
    );

    final decoded = RemoteAssistPresenceAnnouncement.fromJson(
      announcement.toJson(),
    );

    expect(decoded.displayName, announcement.displayName);
    expect(decoded.virtualIp, announcement.virtualIp);
    expect(decoded.networkName, announcement.networkName);
    expect(decoded.version, announcement.version);
    expect(decoded.platform, announcement.platform);
    expect(decoded.supportedRoles, announcement.supportedRoles);
    expect(decoded.capabilities, announcement.capabilities);
    expect(decoded.sentAtEpochMs, announcement.sentAtEpochMs);
  });

  test(
      'presence announcement derives supported roles from legacy capability payload',
      () {
    final decoded = RemoteAssistPresenceAnnouncement.fromJson(
      const <String, dynamic>{
        'displayName': 'Android-1',
        'virtualIp': '10.0.0.8',
        'networkName': '默认网络',
        'version': '1.0.0',
        'platform': 'android',
        'capabilities': <String>[
          RemoteAssistConstants.capabilityAndroid,
          RemoteAssistConstants.capabilityController,
          RemoteAssistConstants.capabilityControlled,
        ],
        'sentAtEpochMs': 321,
      },
    );

    expect(decoded.platform, RemoteAssistPlatform.android);
    expect(
      decoded.supportedRoles,
      const <String>[
        RemoteAssistConstants.capabilityController,
        RemoteAssistConstants.capabilityControlled,
      ],
    );
  });

  test('macOS presence announcement round trip preserves platform token', () {
    const announcement = RemoteAssistPresenceAnnouncement(
      displayName: 'MacBook',
      virtualIp: '10.0.0.9',
      networkName: '默认网络',
      version: '2.0.0',
      platform: RemoteAssistPlatform.macos,
      supportedRoles: <String>[
        RemoteAssistConstants.capabilityController,
        RemoteAssistConstants.capabilityControlled,
      ],
      capabilities: <String>[
        RemoteAssistConstants.capabilityMacos,
        RemoteAssistConstants.capabilityController,
        RemoteAssistConstants.capabilityControlled,
      ],
      sentAtEpochMs: 456,
    );

    final decoded = RemoteAssistPresenceAnnouncement.fromJson(
      announcement.toJson(),
    );

    expect(RemoteAssistPlatform.fromToken('macos'), RemoteAssistPlatform.macos);
    expect(
        RemoteAssistPlatform.fromToken('darwin'), RemoteAssistPlatform.macos);
    expect(decoded.platform, RemoteAssistPlatform.macos);
    expect(decoded.supportedRoles, announcement.supportedRoles);
    expect(decoded.capabilities, announcement.capabilities);
  });
}
