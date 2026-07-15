import 'dart:async';
import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';
import 'package:vnts_console/features/dashboard/controller/dashboard_controller.dart';
import 'package:vnts_console/features/dashboard/data/dashboard_repository.dart';
import 'package:vnts_console/features/dashboard/domain/dashboard_snapshot.dart';
import 'package:vnts_console/features/dashboard/domain/traffic_sample.dart';

import 'dashboard_test_data.dart';

void main() {
  test('snapshot 严格解析真实可空字段并拒绝负计数', () {
    final snapshot = dashboardSnapshot();
    expect(snapshot.host.cpuPercent, 12.5);
    expect(snapshot.process.threads, isNull);
    expect(snapshot.topology.nodesOnline, 4);

    final invalid = dashboardJson();
    final traffic = Map<String, Object?>.from(
      invalid['traffic']! as Map<String, Object?>,
    );
    traffic['tx_bytes_total'] = -1;
    invalid['traffic'] = traffic;
    expect(() => DashboardSnapshot.fromJson(invalid), throwsFormatException);
  });

  test('固定环形缓冲区保持容量且返回最近窗口', () {
    final buffer = FixedRingBuffer<int>(3);
    for (var value = 1; value <= 5; value++) {
      buffer.add(value);
    }
    expect(buffer.values, [3, 4, 5]);
    expect(buffer.last(2), [4, 5]);
  });

  test('控制器按累计计数和实际采样间隔计算速率', () async {
    final repository = _QueueRepository([
      dashboardSnapshot(sampledAtMs: 1000, txBytes: 1000, rxBytes: 2000),
      dashboardSnapshot(sampledAtMs: 3000, txBytes: 5000, rxBytes: 8000),
    ]);
    final controller = DashboardController(
      repository: repository,
      pollInterval: const Duration(hours: 1),
    );
    addTearDown(controller.dispose);

    controller.setVisible(true);
    await _waitUntil(() => controller.state == DashboardLoadState.ready);
    expect(controller.txBytesPerSecond, isNull);
    await controller.refresh();

    expect(controller.txBytesPerSecond, 2000);
    expect(controller.rxBytesPerSecond, 3000);
    expect(controller.traffic15Minutes, hasLength(1));
  });

  test('不可见时取消轮询且不再请求', () async {
    final repository = _RepeatingRepository(dashboardSnapshot());
    final controller = DashboardController(
      repository: repository,
      pollInterval: const Duration(milliseconds: 10),
    );
    addTearDown(controller.dispose);
    controller.setVisible(true);
    await _waitUntil(() => repository.calls > 0);

    controller.setVisible(false);
    final callsAfterStop = repository.calls;
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(controller.isPolling, isFalse);
    expect(repository.calls, callsAfterStop);
  });
}

class _QueueRepository implements DashboardRepositoryContract {
  _QueueRepository(Iterable<DashboardSnapshot> snapshots)
    : _snapshots = Queue.of(snapshots);

  final Queue<DashboardSnapshot> _snapshots;

  @override
  Future<DashboardSnapshot> fetchSnapshot() async => _snapshots.removeFirst();
}

class _RepeatingRepository implements DashboardRepositoryContract {
  _RepeatingRepository(this.snapshot);

  final DashboardSnapshot snapshot;
  int calls = 0;

  @override
  Future<DashboardSnapshot> fetchSnapshot() async {
    calls++;
    return snapshot;
  }
}

Future<void> _waitUntil(bool Function() predicate) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  throw TimeoutException('condition not reached');
}
