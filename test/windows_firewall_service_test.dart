import 'package:flutter_test/flutter_test.dart';
import 'package:vnt_app/windows/windows_firewall_service.dart';

void main() {
  final service = WindowsFirewallService.instance;

  tearDown(() {
    service.debugForceSupportedPlatform = null;
    service.debugRuleExists = null;
    service.debugEnsureRulesElevated = null;
    service.debugFirewallEnabled = null;
    service.debugRunProcess = null;
    service.debugTempDirectory = null;
    service.lastEnsureResult = null;
  });

  group('WindowsFirewallService', () {
    test('已有规则时不重复申请管理员放行', () async {
      var prompted = false;
      service.debugForceSupportedPlatform = true;
      service.debugFirewallEnabled = () async => true;
      service.debugRuleExists = (_) async => true;
      service.debugEnsureRulesElevated = (_) async {
        prompted = true;
      };

      final result = await service.ensureChatAndRemoteAssistRules(
        includeRemoteAssist: true,
      );

      expect(result.success, isTrue);
      expect(result.failureKind, WindowsFirewallEnsureFailureKind.none);
      expect(result.promptedForElevation, isFalse);
      expect(result.missingRules, isEmpty);
      expect(prompted, isFalse);
    });

    test('缺失规则时会生成完整放行计划并在补齐后成功', () async {
      final existingRules = <String>{};
      List<WindowsFirewallRuleSpec> elevatedRules = const [];
      service.debugForceSupportedPlatform = true;
      service.debugFirewallEnabled = () async => true;
      service.debugRuleExists =
          (rule) async => existingRules.contains(rule.signature);
      service.debugEnsureRulesElevated = (rules) async {
        elevatedRules = List<WindowsFirewallRuleSpec>.from(rules);
        for (final rule in rules) {
          existingRules.add(rule.signature);
        }
      };

      final result = await service.ensureChatAndRemoteAssistRules(
        includeRemoteAssist: true,
      );

      expect(result.success, isTrue);
      expect(result.promptedForElevation, isTrue);
      expect(
        elevatedRules.map((rule) => rule.signature).toList(),
        ['TCP/23100', 'TCP/23101', 'UDP/23102', 'TCP/21118'],
      );
      expect(result.failureKind, WindowsFirewallEnsureFailureKind.none);
      expect(result.missingRules, isEmpty);
    });

    test('用户取消授权时返回 elevationCancelled 且不崩溃', () async {
      service.debugForceSupportedPlatform = true;
      service.debugFirewallEnabled = () async => true;
      service.debugRuleExists = (_) async => false;
      service.debugEnsureRulesElevated = (_) async {
        throw StateError('The operation was canceled by the user.');
      };

      final result = await service.ensureChatAndRemoteAssistRules(
        includeRemoteAssist: false,
      );

      expect(result.success, isFalse);
      expect(result.promptedForElevation, isTrue);
      expect(
        result.failureKind,
        WindowsFirewallEnsureFailureKind.elevationCancelled,
      );
      expect(result.errorMessage, contains('canceled'));
      expect(
        result.missingRules.map((rule) => rule.signature).toList(),
        ['TCP/23100', 'TCP/23101', 'UDP/23102'],
      );
    });

    test('提权未弹窗时返回 elevationNotShown 且不阻断远程协助', () async {
      service.debugForceSupportedPlatform = true;
      service.debugFirewallEnabled = () async => true;
      service.debugRuleExists = (_) async => false;
      service.debugEnsureRulesElevated = (_) async {
        throw StateError('管理员授权被取消或防火墙规则添加失败');
      };

      final result = await service.ensureChatAndRemoteAssistRules(
        includeRemoteAssist: true,
      );

      expect(result.success, isFalse);
      expect(result.promptedForElevation, isTrue);
      expect(
        result.failureKind,
        WindowsFirewallEnsureFailureKind.elevationNotShown,
      );
      expect(result.blocksRemoteAssist, isFalse);
    });

    test('系统防火墙关闭时跳过规则检查且不申请管理员放行', () async {
      var prompted = false;
      service.debugForceSupportedPlatform = true;
      service.debugFirewallEnabled = () async => false;
      service.debugEnsureRulesElevated = (_) async {
        prompted = true;
      };

      final result = await service.ensureChatAndRemoteAssistRules(
        includeRemoteAssist: true,
      );

      expect(result.success, isTrue);
      expect(result.firewallEnabled, isFalse);
      expect(result.skippedRuleCheck, isTrue);
      expect(
        result.failureKind,
        WindowsFirewallEnsureFailureKind.firewallDisabled,
      );
      expect(result.promptedForElevation, isFalse);
      expect(result.missingRules, isEmpty);
      expect(prompted, isFalse);
    });
  });
}
