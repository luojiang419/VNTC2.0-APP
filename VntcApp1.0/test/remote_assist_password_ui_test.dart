import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vnt_app/pages/remote_assist_page.dart';

void main() {
  test('远程协助密码按钮会区分设置与修改状态', () {
    expect(remoteAccessPasswordActionLabel(false), '设置访问密码');
    expect(remoteAccessPasswordActionLabel(true), '修改访问密码');
  });

  test('连接请求保留密码和记住选择', () {
    const request = RemotePeerConnectRequest(
      password: 'peer-password',
      rememberPassword: true,
    );

    expect(request.password, 'peer-password');
    expect(request.rememberPassword, isTrue);
  });

  test('Android 不再使用手动 IP 连接栏', () {
    final source = File('lib/pages/remote_assist_page.dart').readAsStringSync();

    expect(source, isNot(contains('_targetIpController')));
    expect(source, isNot(contains("labelText: '目标虚拟 IP'")));
    expect(source, isNot(contains('填入首个在线设备')));
    expect(source, contains('记住此设备密码'));
    expect(source, contains('删除已保存密码'));
  });
}
