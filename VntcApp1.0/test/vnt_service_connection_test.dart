import 'package:flutter_test/flutter_test.dart';
import 'package:vnt_app/network_config.dart';
import 'package:vnt_app/services/vnt_service_client.dart';
import 'package:vnt_app/vnt/vnt_manager.dart';

NetworkConfig config(String key) => NetworkConfig.fromJson({
      'itemKey': key,
      'name': '测试网络',
      'token': 'test',
    });
VntServiceStatus status(
        {String key = 'a',
        String state = 'connected',
        List<Map<String, dynamic>> peers = const []}) =>
    VntServiceStatus.fromJson({
      'connectionState': state,
      'configKey': key,
      'virtualIp': '10.0.0.2',
      'network': {
        'peers': peers,
        'currentDevice': {
          'virtualNetwork': '10.0.0.0',
          'virtualNetmask': '255.255.255.0',
          'connectServer': 'quic://server:29872'
        },
        'routes': [
          [
            '10.0.0.3',
            [
              {'protocol': 'P2P', 'addr': '127.0.0.1:1', 'metric': 1, 'rt': 23}
            ]
          ]
        ],
        'diagnostics': {'onlinePeerCount': peers.length},
        'traffic': [
          ['10.0.0.3', '9007199254740993', '1024']
        ],
      },
    });
const peer = {'virtualIp': '10.0.0.3', 'name': '其他用户', 'status': 'Online'};

void main() {
  test('服务已连接时提供与本地模式一致的用户和路由入口', () {
    final manager = VntManager();
    manager.applySystemServiceStatus(status(peers: [peer]), [config('a')]);
    expect(manager.hasConnection(), isTrue);
    expect(manager.size(), 1);
    final box = manager.getOne()!;
    expect(box.peerDeviceList().single.name, '其他用户');
    expect(box.route('10.0.0.3')!.rt, 23);
    expect(box.currentDevice()['virtualNetwork'], '10.0.0.0');
    expect(box.currentDevice()['connectServer'], 'quic://server:29872');
    expect(box.streamAll().single.$2, BigInt.parse('9007199254740993'));
  });
  test('节点上下线通知观察者且保持连接对象身份', () {
    final manager = VntManager();
    var changes = 0;
    manager.addConnectionListener(() => changes++);
    manager.applySystemServiceStatus(status(), [config('a')]);
    final original = manager.getOne();
    manager.applySystemServiceStatus(status(peers: [peer]), [config('a')]);
    expect(identical(manager.getOne(), original), isTrue);
    expect(original!.peerDeviceList().length, 1);
    manager.applySystemServiceStatus(status(), [config('a')]);
    expect(original.peerDeviceList(), isEmpty);
    expect(changes, 3);
  });
  test('断线和切换网络清理旧入口并失效旧引用', () {
    final manager = VntManager();
    manager.applySystemServiceStatus(status(peers: [peer]), [config('a')]);
    final old = manager.getOne()!;
    manager.applySystemServiceStatus(status(key: 'b'), [config('b')]);
    expect(manager.get('a'), isNull);
    expect(old.isClosed(), isTrue);
    expect(manager.get('b'), isNotNull);
    manager.applySystemServiceStatus(
        status(key: 'b', state: 'retrying'), [config('b')]);
    expect(manager.map, isEmpty);
    expect(manager.hasConnection(), isFalse);
  });
  test('旧服务缺省快照可读取且不创建第二套核心', () {
    final manager = VntManager();
    manager.applySystemServiceStatus(
        VntServiceStatus.fromJson({
          'connectionState': 'connected',
          'configKey': 'a',
          'virtualIp': '10.0.0.2',
        }),
        [config('a')]);
    expect(manager.getOne()!.peerDeviceList(), isEmpty);
    expect(manager.getOne()!.routeList(), isEmpty);
  });
}
