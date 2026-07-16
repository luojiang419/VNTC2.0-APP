import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final workflow = File('../.github/workflows/build.yml').readAsStringSync();

  test('正式发布串行执行并使用最小权限', () {
    expect(workflow, contains('cancel-in-progress: false'));
    expect(workflow, isNot(contains('cancel-in-progress: true')));
    expect(workflow, contains('permissions:\n  contents: read'));
    expect(
      workflow,
      contains('deploy:\n    name: 发布 GitHub Release'),
    );
    expect(workflow, contains('    permissions:\n      contents: write'));
  });

  test('客户端测试通过后才允许构建和发布', () {
    expect(workflow, contains('test-client:'));
    expect(workflow, contains('flutter pub get --enforce-lockfile'));
    expect(workflow, contains('flutter analyze --no-pub'));
    expect(workflow, contains('flutter test --no-pub'));
    expect(workflow, contains('verify_android_16kb_alignment.py --self-test'));
    expect(workflow, contains('      - test-client'));
  });

  test('Release 先作为草稿验收再转为正式版本', () {
    expect(workflow, contains('创建草稿 Release 并上传资产'));
    expect(workflow, contains('draft: true'));
    expect(workflow, contains('远端复核草稿 Release 资产'));
    expect(workflow, contains('将已验收草稿转为正式 Release'));
    expect(workflow, contains('验收 Latest Release、标签与校验文件'));
    expect(workflow, contains('清理当前运行创建的失败草稿'));
    expect(workflow, contains('already_released="true"'));
  });

  test('第三方发布 Actions 固定到不可变提交', () {
    final thirdParty = RegExp(
      r'uses: (?:subosito|android-actions|maxim-lobanov|lukka|softprops)/[^@\s]+@([^\s#]+)',
    ).allMatches(workflow);
    expect(thirdParty, isNotEmpty);
    for (final match in thirdParty) {
      expect(match.group(1), matches(RegExp(r'^[0-9a-f]{40}$')));
    }
  });
}
